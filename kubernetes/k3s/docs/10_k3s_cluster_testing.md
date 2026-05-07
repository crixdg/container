# k3s Cluster Testing

Tests to run after production readiness is confirmed. Each section is independent — run them in any order, but always on a non-production cluster first.

---

## 1. Node Resilience

### 1.1 Graceful reboot

Verify k3s and all workloads recover automatically after a planned reboot.

```bash
sudo reboot

# after reboot — expect all pods Running within ~60s
kubectl get nodes
kubectl get pods -A
```

**Pass:** all pods return to `Running` without manual intervention.

### 1.2 Hard reset (simulated power loss)

```bash
# on the node — force immediate reboot, no graceful shutdown
sudo echo b > /proc/sysrq-trigger

# after reboot
kubectl get pods -A
```

**Pass:** no pods stuck in `Terminating` after 2 minutes; cluster self-heals.

### 1.3 k3s process kill

```bash
sudo systemctl stop k3s
sleep 30
sudo systemctl start k3s

kubectl get nodes    # node may briefly show NotReady
kubectl get pods -A
```

**Pass:** node returns `Ready` within 60s; running pods survive without restart.

---

## 2. Pod Failure & Self-Healing

### 2.1 Pod delete

```bash
# deploy a test workload with replicas
kubectl create deployment test-app --image=nginx --replicas=3

# delete a pod — Deployment should recreate it
kubectl delete pod -l app=test-app --field-selector=status.phase=Running | head -1
kubectl get pods -l app=test-app -w
```

**Pass:** replacement pod reaches `Running` within 30s.

### 2.2 OOMKill simulation

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: oom-test
spec:
  containers:
  - name: stress
    image: polinux/stress
    resources:
      limits:
        memory: 50Mi
    command: ["stress"]
    args: ["--vm", "1", "--vm-bytes", "100M"]
EOF

kubectl get pod oom-test -w   # expect OOMKilled, then CrashLoopBackOff
kubectl delete pod oom-test
```

**Pass:** pod is killed by OOM, not the node; other pods unaffected.

### 2.3 Liveness probe failure

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: liveness-test
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "sleep 10 && exit 1"]
    livenessProbe:
      exec:
        command: ["cat", "/tmp/healthy"]
      initialDelaySeconds: 5
      periodSeconds: 5
EOF

kubectl get pod liveness-test -w   # expect Restart after probe failure
kubectl delete pod liveness-test
```

**Pass:** pod restarts automatically on probe failure.

---

## 3. Network Failure

### 3.1 DNS failure simulation

```bash
# scale CoreDNS to 0
kubectl scale deployment coredns -n kube-system --replicas=0

# new DNS lookups should fail
kubectl run dns-fail --image=busybox:1.28 --rm -it --restart=Never \
  -- nslookup kubernetes.default

# restore
kubectl scale deployment coredns -n kube-system --replicas=1
kubectl get pods -n kube-system -l k8s-app=kube-dns -w
```

**Pass:** DNS fails gracefully while CoreDNS is down; resolves again within 30s of restore.

### 3.2 Network partition simulation (iptables drop)

```bash
# block pod-to-pod traffic temporarily
sudo iptables -I FORWARD -j DROP

sleep 10

# restore
sudo iptables -D FORWARD -j DROP

# verify pod-to-pod communication recovers
kubectl run net-test --image=busybox:1.28 --rm -it --restart=Never \
  -- wget -qO- http://test-app.default.svc.cluster.local
```

**Pass:** connections resume within seconds of restoring the rule.

---

## 4. Storage Failure

### 4.1 PVC survives pod restart

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: persist-test
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 100Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: persist-pod
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "echo hello > /data/test.txt && sleep 3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: persist-test
EOF

# write data, delete pod, recreate, verify data survives
kubectl exec persist-pod -- cat /data/test.txt
kubectl delete pod persist-pod
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: persist-pod
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: persist-test
EOF
kubectl exec persist-pod -- cat /data/test.txt   # should print "hello"

# cleanup
kubectl delete pod persist-pod
kubectl delete pvc persist-test
```

**Pass:** data persists across pod restarts.

### 4.2 Disk pressure simulation

```bash
# fill disk to trigger eviction
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: disk-hog
spec:
  containers:
  - name: fill
    image: busybox
    command: ["sh", "-c", "dd if=/dev/zero of=/data/fill bs=1M count=10000; sleep 3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    emptyDir: {}
EOF

# watch node conditions for DiskPressure
kubectl describe node | grep -A5 Conditions

# cleanup
kubectl delete pod disk-hog
```

**Pass:** node shows `DiskPressure` condition; kubelet evicts the pod; node recovers after cleanup.

---

## 5. Resource Exhaustion

### 5.1 CPU stress

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: cpu-stress
spec:
  containers:
  - name: stress
    image: polinux/stress
    resources:
      requests:
        cpu: 100m
      limits:
        cpu: 500m
    command: ["stress"]
    args: ["--cpu", "4"]
EOF

# other pods should remain responsive
kubectl top nodes
kubectl top pods -A

kubectl delete pod cpu-stress
```

**Pass:** CPU stress is contained within limits; other workloads unaffected.

### 5.2 Memory pressure

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: mem-stress
spec:
  containers:
  - name: stress
    image: polinux/stress
    resources:
      requests:
        memory: 100Mi
      limits:
        memory: 200Mi
    command: ["stress"]
    args: ["--vm", "1", "--vm-bytes", "150M", "--vm-keep"]
EOF

kubectl top pods
kubectl delete pod mem-stress
```

**Pass:** memory usage is contained; no other pods evicted.

---

## 6. Ingress & TLS

### 6.1 ingress-nginx pod restart

```bash
kubectl rollout restart deployment ingress-nginx-controller -n ingress-nginx
kubectl rollout status deployment ingress-nginx-controller -n ingress-nginx

# verify traffic resumes
curl -H "Host: test.example.com" http://<NODE_IP>
```

**Pass:** ingress recovers within 30s; no persistent 502/503 after rollout completes.

### 6.2 Certificate renewal simulation

```bash
# shorten cert duration to force near-expiry
kubectl get certificate -A
kubectl describe certificate <name> -n <namespace>

# cert-manager should auto-renew at 2/3 of lifetime
# check the renewal event
kubectl get events -n <namespace> | grep cert
```

**Pass:** cert-manager renews the certificate before expiry without manual intervention.

---

## 7. Chaos Testing with Chaos Mesh (optional)

Install Chaos Mesh for structured fault injection:

```bash
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm install chaos-mesh chaos-mesh/chaos-mesh \
  -n chaos-mesh --create-namespace \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/k3s/containerd/containerd.sock
```

### 7.1 Pod chaos — random pod kill

```bash
kubectl apply -f - <<EOF
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: pod-kill-test
  namespace: default
spec:
  action: pod-kill
  mode: one
  selector:
    namespaces: [default]
    labelSelectors:
      app: test-app
  scheduler:
    cron: "@every 1m"
EOF

kubectl get pods -l app=test-app -w

# cleanup
kubectl delete podchaos pod-kill-test
```

### 7.2 Network chaos — latency injection

```bash
kubectl apply -f - <<EOF
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: network-delay-test
  namespace: default
spec:
  action: delay
  mode: all
  selector:
    namespaces: [default]
  delay:
    latency: "200ms"
    jitter: "50ms"
  duration: "2m"
EOF

# measure response times during injection
kubectl run latency-check --image=busybox:1.28 --rm -it --restart=Never \
  -- sh -c "time wget -qO- http://test-app.default.svc.cluster.local"

kubectl delete networkchaos network-delay-test
```

### 7.3 Stress chaos — node CPU/memory pressure

```bash
kubectl apply -f - <<EOF
apiVersion: chaos-mesh.org/v1alpha1
kind: StressChaos
metadata:
  name: stress-test
  namespace: default
spec:
  mode: one
  selector:
    namespaces: [default]
  stressors:
    cpu:
      workers: 2
    memory:
      workers: 1
      size: "256MB"
  duration: "2m"
EOF

kubectl top nodes
kubectl delete stresschaos stress-test
```

---

## 8. Upgrade Testing

### 8.1 k3s version upgrade

```bash
# check current version
k3s --version

# upgrade to a new pinned version
export INSTALL_K3S_VERSION=v1.35.5+k3s1
curl -sfL https://get.k3s.io | sh -

k3s --version
kubectl get nodes
kubectl get pods -A
```

**Pass:** node returns `Ready`; all pods recover; no data loss.

---

## Summary

| Test                 | Tool                | Expected outcome                            |
| -------------------- | ------------------- | ------------------------------------------- |
| Reboot / hard reset  | systemctl, sysrq    | Cluster self-heals, no manual steps         |
| Pod delete / OOMKill | kubectl             | Deployment recreates pod automatically      |
| DNS outage           | kubectl scale       | Fails gracefully, recovers on restore       |
| Network partition    | iptables            | Connections resume after rule removed       |
| PVC persistence      | kubectl             | Data survives pod restart                   |
| Disk pressure        | dd                  | Node evicts pod, recovers after cleanup     |
| CPU / memory limits  | stress              | Contained within limits, no spillover       |
| Ingress restart      | kubectl rollout     | Traffic resumes within 30s                  |
| Cert renewal         | cert-manager events | Auto-renewed before expiry                  |
| Chaos Mesh           | CRDs                | Controlled fault injection and recovery     |
| Version upgrade      | k3s installer       | No data loss, cluster healthy after upgrade |
