# k3s Load Testing & Chaos Under Traffic

Chaos tests on an idle cluster tell you little. Real confidence comes from injecting failures while business traffic is flowing and measuring whether the system stays within acceptable thresholds.

The pattern is always:

```
deploy app → generate steady load → verify baseline → inject fault → observe impact → verify recovery
```

---

## 1. Deploy a Realistic Sample Application

A three-tier app: frontend (nginx) → API (simple HTTP service) → database (PostgreSQL). Replace with your actual workload when available.

```bash
kubectl apply -f - <<EOF
# --- Namespace ------------------------------------------------------------------
apiVersion: v1
kind: Namespace
metadata:
  name: demo
---
# --- PostgreSQL -----------------------------------------------------------------
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:15
        env:
        - name: POSTGRES_PASSWORD
          value: "testpass"
        - name: POSTGRES_DB
          value: "demo"
        ports:
        - containerPort: 5432
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: demo
spec:
  selector:
    app: postgres
  ports:
  - port: 5432
---
# --- API (httpbin simulates a real API) ----------------------------------------
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
      - name: api
        image: kennethreitz/httpbin
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 100m
            memory: 64Mi
          limits:
            cpu: 500m
            memory: 128Mi
        livenessProbe:
          httpGet:
            path: /status/200
            port: 80
          initialDelaySeconds: 10
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /status/200
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: demo
spec:
  selector:
    app: api
  ports:
  - port: 80
---
# --- Ingress -------------------------------------------------------------------
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo
  namespace: demo
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
  - host: demo.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: api
            port:
              number: 80
EOF

kubectl get pods -n demo -w   # wait for all Running
```

---

## 2. Establish a Baseline with k6

Install k6 on your workstation:
```bash
# Debian/Ubuntu
sudo apt-get install -y k6

# RHEL/Rocky
sudo dnf install -y k6
```

### 2.1 Write a business-like load script

```javascript
// load-test.js
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

const errorRate = new Rate('errors');

export const options = {
  stages: [
    { duration: '30s', target: 10 },   // ramp up to 10 users
    { duration: '2m',  target: 10 },   // hold steady load
    { duration: '30s', target: 50 },   // spike to 50 users
    { duration: '1m',  target: 50 },   // hold spike
    { duration: '30s', target: 10 },   // ramp back down
  ],
  thresholds: {
    http_req_duration: ['p(95)<500'],   // 95% of requests under 500ms
    errors:            ['rate<0.01'],   // less than 1% errors
  },
};

const BASE = 'http://<NODE_IP>';
const HOST = 'demo.example.com';

export default function () {
  const params = { headers: { Host: HOST } };

  // simulate typical API calls
  const responses = http.batch([
    ['GET', `${BASE}/get`,        null, params],
    ['GET', `${BASE}/status/200`, null, params],
    ['POST', `${BASE}/post`,
      JSON.stringify({ user: `user_${__VU}`, action: 'purchase' }),
      { headers: { Host: HOST, 'Content-Type': 'application/json' } }
    ],
  ]);

  responses.forEach(res => {
    errorRate.add(res.status >= 400);
    check(res, { 'status is 2xx': r => r.status >= 200 && r.status < 300 });
  });

  sleep(1);
}
```

### 2.2 Run baseline and record thresholds

```bash
k6 run load-test.js
```

Record the baseline numbers before any fault injection:

| Metric | Baseline value |
| ------ | -------------- |
| p95 latency | ___ ms |
| error rate | ___ % |
| requests/sec | ___ |

These become your **steady-state definition** — the numbers the system must return to after a fault.

---

## 3. Chaos Under Load

Run k6 in the background while injecting faults. Observe whether the thresholds hold.

```bash
# terminal 1 — keep load running
k6 run --duration 10m load-test.js

# terminal 2 — inject faults (examples below)
```

### 3.1 Kill an API pod while traffic flows

```bash
# watch error rate in k6 output while doing this
kubectl delete pod -n demo -l app=api --field-selector=status.phase=Running \
  | head -1
```

**Acceptable:** brief spike in errors (< 5s), then recovery to baseline.  
**Fail:** sustained errors > 1% or p95 latency > 500ms after pod restarts.

### 3.2 Roll out a new version under load

```bash
kubectl set image deployment/api api=kennethreitz/httpbin:latest -n demo
kubectl rollout status deployment/api -n demo
```

**Acceptable:** zero errors during rollout (readiness probe gates traffic).  
**Fail:** any requests hit the new pod before it passes readiness.

### 3.3 Exhaust one pod's CPU under load

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: cpu-noise
  namespace: demo
spec:
  containers:
  - name: stress
    image: polinux/stress
    resources:
      limits:
        cpu: "1"
    command: ["stress"]
    args: ["--cpu", "4"]
EOF

# observe p95 latency in k6 — should stay under threshold
sleep 60
kubectl delete pod cpu-noise -n demo
```

### 3.4 DNS outage under load

```bash
kubectl scale deployment coredns -n kube-system --replicas=0

# k6 will show DNS errors for existing connections (cached) vs new ones
sleep 20

kubectl scale deployment coredns -n kube-system --replicas=1
```

**Acceptable:** errors only on new DNS lookups during outage; recovery within 30s.

### 3.5 Ingress restart under load

```bash
kubectl rollout restart deployment ingress-nginx-controller -n ingress-nginx
```

**Acceptable:** < 5s of 502s during restart if only one replica; zero with 2+ replicas.

---

## 4. Chaos Mesh Under Load (structured)

With Chaos Mesh installed (see `docs/10_k3s_cluster_testing.md`), run experiments while k6 is active:

```bash
# run load in background
k6 run --duration 10m load-test.js &

# inject 100ms latency on all demo pods
kubectl apply -f - <<EOF
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: latency-under-load
  namespace: demo
spec:
  action: delay
  mode: all
  selector:
    namespaces: [demo]
  delay:
    latency: "100ms"
  duration: "2m"
EOF

# watch k6 output — p95 should stay under 500ms (100ms budget absorbed)
wait
kubectl delete networkchaos latency-under-load -n demo
```

---

## 5. Observing Results

### During the test

```bash
# resource usage
kubectl top pods -n demo
kubectl top nodes

# error events
kubectl get events -n demo --sort-by='.lastTimestamp' | tail -20

# ingress request log
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=50 -f
```

### After the test — k6 summary

k6 prints a summary at the end. Key fields to check:

```
http_req_duration............: p(95)=___ms   ← must be < 500ms
http_req_failed..............: ___% of requests  ← must be < 1%
iterations...................: ___
```

If thresholds are breached, k6 exits with code 99 — useful in CI:

```bash
k6 run load-test.js
echo "exit code: $?"   # 0 = pass, 99 = threshold breached
```

---

## 6. Acceptance Criteria

Define these before running tests. Adjust numbers to match your SLA.

| Scenario | Max error rate | Max p95 latency | Recovery time |
| -------- | -------------- | --------------- | ------------- |
| Pod kill | < 1% | < 500ms | < 30s |
| Rolling deploy | 0% | < 500ms | — |
| CPU noise | < 1% | < 500ms | immediate |
| DNS outage | < 5% (cached) | < 1000ms | < 30s |
| Ingress restart | < 1% | < 500ms | < 10s |
| Network latency +100ms | < 1% | < 600ms | immediate |

---

## 7. Cleanup

```bash
kubectl delete namespace demo
k6 run --vus 0 load-test.js 2>/dev/null || true   # stop any background run
```
