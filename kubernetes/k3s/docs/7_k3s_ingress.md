# k3s Ingress

An Ingress is a Kubernetes object that routes external HTTP/HTTPS traffic into Services inside the cluster. Without Ingress, the only ways to reach a pod from outside are NodePort (raw port on a node) or a cloud load balancer — neither is practical for hosting multiple services on a small cluster.

**Where Ingress sits in the k3s system:**

```
External request
    │
    ▼
Node port 80 / 443 (hostNetwork)
    │
    ▼
ingress-nginx pod (on the ingress node)
    │
    ├── Host: grafana.example.com  →  Service: grafana.monitoring:3000
    ├── Host: kibana.example.com   →  Service: kibana.logging:5601
    └── Host: kafka-ui.example.com →  Service: akhq.streaming:8080
```

> Ingress-nginx is not built into k3s. k3s ships Traefik as its default ingress controller — this repo **disables Traefik** and uses ingress-nginx instead, which is more widely used, better documented, and has a larger ecosystem of annotations.

---

## Key components

| Component                    | Role                                                                         |
| ---------------------------- | ---------------------------------------------------------------------------- |
| **IngressClass**             | Identifies which controller handles an Ingress object — `nginx` in this repo |
| **Ingress object**           | Rules that map hostnames and paths to backend Services                       |
| **ingress-nginx controller** | The NGINX pod that reads Ingress objects and proxies traffic                 |
| **cert-manager**             | Automatically provisions and renews TLS certificates                         |
| **ClusterIssuer**            | cert-manager config that tells it how to obtain certificates (Let's Encrypt) |

---

## How it works

```
1. You create an Ingress object:
   host: grafana.example.com → Service grafana:3000

2. ingress-nginx controller watches the API server
   → detects the new Ingress
   → writes an NGINX server block for grafana.example.com

3. Request arrives at the node on port 443
   → NGINX terminates TLS (cert from cert-manager)
   → proxies to grafana Service on port 3000
   → Service forwards to the grafana pod
```

---

## Install

Install cert-manager and ingress-nginx together:

```bash
bash kubernetes/k3s/helm/install-essentials.sh
```

Or install individually in order (cert-manager must come first):

```bash
bash kubernetes/k3s/helm/cert-manager/install.sh
bash kubernetes/k3s/helm/ingress-nginx/install.sh
```

### Label an ingress node

ingress-nginx only schedules on nodes labelled `ingress=true`. The install script labels the first node automatically. To add or change:

```bash
# Add label
kubectl label node <node-name> ingress=true

# Remove label (ingress-nginx will no longer run there)
kubectl label node <node-name> ingress-
```

> **Why a dedicated ingress node?** ingress-nginx uses `hostNetwork: true` — it binds directly to the node's port 80/443. Any node with the `ingress=true` label becomes the external entry point. Traffic hitting any other node will not reach the ingress. See `1_k3s_components.md` for the full ingress node explanation.

---

## ingress-nginx configuration

Values file: `kubernetes/k3s/helm/ingress-nginx/helm-values.yaml`

Key settings and why they are set:

| Setting                              | Value           | Reason                                                                                                   |
| ------------------------------------ | --------------- | -------------------------------------------------------------------------------------------------------- |
| `hostNetwork: true`                  | true            | Binds directly to node ports 80/443 — no cloud LB or MetalLB needed                                      |
| `kind: DaemonSet`                    | DaemonSet       | Runs on every labelled node — add more ingress nodes by adding the label                                 |
| `nodeSelector: ingress: "true"`      | ingress=true    | Pins to designated ingress nodes only                                                                    |
| `ssl-protocols`                      | TLSv1.2 TLSv1.3 | Drops TLS 1.0/1.1 — required for PCI-DSS and general security hygiene                                    |
| `hsts: true`                         | true            | Tells browsers to always use HTTPS for this domain                                                       |
| `ingressClassResource.default: true` | true            | Makes `nginx` the default IngressClass — Ingress objects without a class annotation use it automatically |

---

## Writing an Ingress object

### Basic HTTP Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: monitoring
spec:
  ingressClassName: nginx
  rules:
    - host: grafana.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: grafana
                port:
                  number: 3000
```

### HTTPS with TLS certificate (cert-manager)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: monitoring
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - grafana.example.com
      secretName: grafana-tls # cert-manager creates this Secret
  rules:
    - host: grafana.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: grafana
                port:
                  number: 3000
```

> When the annotation `cert-manager.io/cluster-issuer: letsencrypt-prod` is present, cert-manager detects the Ingress object and automatically:
>
> 1. Creates a `Certificate` object for `grafana.example.com`
> 2. Completes an ACME HTTP-01 challenge via Let's Encrypt
> 3. Stores the resulting certificate in the Secret named `grafana-tls`
> 4. Renews it automatically before it expires (Let's Encrypt certs expire every 90 days)

### Path-based routing (multiple services on one hostname)

```yaml
spec:
  ingressClassName: nginx
  rules:
    - host: monitoring.example.com
      http:
        paths:
          - path: /grafana
            pathType: Prefix
            backend:
              service:
                name: grafana
                port:
                  number: 3000
          - path: /prometheus
            pathType: Prefix
            backend:
              service:
                name: prometheus
                port:
                  number: 9090
```

---

## TLS certificates

### Option A — Let's Encrypt (public domain, automatic)

Requires your domain to resolve to the ingress node's public IP on port 80.

**Step 1 — Create the ClusterIssuer:**

```bash
# Edit the email address first
kubectl apply -f kubernetes/k3s/helm/cert-manager/letsencrypt-http01.yaml
```

**Step 2 — Add the annotation to your Ingress:**

```yaml
annotations:
  cert-manager.io/cluster-issuer: letsencrypt-prod
```

**Step 3 — Verify the certificate was issued:**

```bash
kubectl get certificate -n <namespace>
# READY should be True

kubectl describe certificate <name> -n <namespace>
# Events should show "Certificate issued successfully"
```

> Use `letsencrypt-staging` instead of `letsencrypt-prod` when testing. The staging issuer does not count against Let's Encrypt rate limits but issues untrusted certificates — browsers will show a warning.

### Option B — nip.io (no domain, IP-based, dev/test)

`nip.io` is a public wildcard DNS service that resolves `<anything>.<ip>.nip.io` to `<ip>`. No DNS configuration needed — works with any IP.

```yaml
# Ingress host using nip.io (no real domain needed)
host: grafana.192.168.1.100.nip.io
```

The helm values in this repo use this pattern for quick setup:

```yaml
# From helm-charts/grafana/helm-values.yaml
hostname: grafana.167.254.190.2.nip.io
```

> nip.io is for development and internal clusters only. It does not support TLS via Let's Encrypt because the domain is not under your control. Use self-signed certificates or skip TLS for nip.io ingresses.

### Option C — Self-signed certificate (internal cluster, no internet)

```bash
# Generate a self-signed cert and store it as a Secret
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt \
  -subj "/CN=grafana.internal/O=internal"

kubectl create secret tls grafana-tls \
  --cert=tls.crt --key=tls.key \
  -n monitoring
```

Reference the secret in the Ingress `tls` block without a cert-manager annotation — cert-manager will not manage it.

---

## Useful annotations

| Annotation                                              | Effect                                         |
| ------------------------------------------------------- | ---------------------------------------------- |
| `nginx.ingress.kubernetes.io/rewrite-target: /`         | Strip path prefix before forwarding to backend |
| `nginx.ingress.kubernetes.io/ssl-redirect: "true"`      | Redirect HTTP to HTTPS automatically           |
| `nginx.ingress.kubernetes.io/proxy-body-size: "50m"`    | Increase max upload size (default 1m)          |
| `nginx.ingress.kubernetes.io/proxy-read-timeout: "600"` | Increase timeout for long-running requests     |
| `nginx.ingress.kubernetes.io/auth-type: basic`          | Enable HTTP basic auth                         |
| `nginx.ingress.kubernetes.io/auth-secret: <secret>`     | Secret containing the htpasswd credentials     |
| `nginx.ingress.kubernetes.io/backend-protocol: "GRPC"`  | Route gRPC traffic to backend                  |

---

## Useful commands

```bash
# Check ingress-nginx pods are running and which node they are on
kubectl get pods -n ingress-nginx -o wide

# List all Ingress objects across the cluster
kubectl get ingress -A

# Describe an Ingress (shows rules and backend endpoints)
kubectl describe ingress <name> -n <namespace>

# Check TLS certificate status
kubectl get certificate -A
kubectl describe certificate <name> -n <namespace>

# View ingress-nginx access logs
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=100

# Check which node is labelled as ingress
kubectl get nodes -l ingress=true

# Test routing from outside (replace with your ingress node IP)
curl -H "Host: grafana.example.com" http://<ingress-node-ip>/
curl -k https://grafana.example.com/    # -k skips cert verification for self-signed
```

---

## Troubleshooting

| Symptom                                          | Likely cause                             | Fix                                                                                          |
| ------------------------------------------------ | ---------------------------------------- | -------------------------------------------------------------------------------------------- |
| `curl` returns connection refused on port 80/443 | No node labelled `ingress=true`          | `kubectl label node <name> ingress=true`                                                     |
| Ingress returns 404                              | Path or host does not match any rule     | `kubectl describe ingress <name>` — check rules                                              |
| Ingress returns 502 Bad Gateway                  | Backend Service or pod not running       | `kubectl get endpoints <service> -n <namespace>` — should show pod IPs                       |
| Certificate stuck in `False` / not ready         | ACME challenge failed                    | `kubectl describe certificaterequest -n <namespace>` — check Events for Let's Encrypt errors |
| Let's Encrypt challenge fails                    | Port 80 not reachable from internet      | Verify the ingress node's public IP is reachable: `curl http://<public-ip>`                  |
| TLS cert warning in browser                      | Using staging issuer or self-signed cert | Switch annotation to `letsencrypt-prod` and delete the old certificate Secret                |
| Ingress exists but no traffic reaches backend    | `ingressClassName` not set or wrong      | Add `ingressClassName: nginx` to the Ingress spec                                            |
| Large file upload fails                          | Default body size limit (1m) exceeded    | Add annotation `nginx.ingress.kubernetes.io/proxy-body-size: "100m"`                         |
