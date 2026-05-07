# k3s Production Readiness Checklist

Verify every item below before treating the cluster as production. Work top-to-bottom — later sections depend on earlier ones being healthy.

---

## 1. Cluster Health

- [ ] All nodes are `Ready`:
  ```bash
  kubectl get nodes -o wide
  ```
- [ ] All system pods are `Running` or `Completed`, none `CrashLoopBackOff`:
  ```bash
  kubectl get pods -A
  ```
- [ ] k3s service is enabled so it survives reboots:
  ```bash
  systemctl is-enabled k3s
  ```
- [ ] k3s version is pinned and matches `.env`:
  ```bash
  k3s --version
  ```

---

## 2. Networking

- [ ] CoreDNS is running and resolving cluster-internal names:
  ```bash
  kubectl run dns-test --image=busybox:1.28 --rm -it --restart=Never \
    -- nslookup kubernetes.default
  ```
- [ ] Pod-to-pod communication works across namespaces:
  ```bash
  # deploy two pods and curl between them
  kubectl run a --image=nginx --expose --port=80
  kubectl run b --image=busybox:1.28 --rm -it --restart=Never \
    -- wget -qO- http://a.default.svc.cluster.local
  ```
- [ ] Flannel VXLAN interface is present on the node:
  ```bash
  ip link show flannel.1
  ```
- [ ] Node CIDR is assigned correctly:
  ```bash
  kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}'
  ```

---

## 3. Storage

- [ ] Default StorageClass is set:
  ```bash
  kubectl get storageclass
  ```
- [ ] A PVC can be provisioned and binds:
  ```bash
  kubectl apply -f - <<EOF
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: test-pvc
  spec:
    accessModes: [ReadWriteOnce]
    resources:
      requests:
        storage: 100Mi
  EOF
  kubectl get pvc test-pvc   # should reach Bound
  kubectl delete pvc test-pvc
  ```
- [ ] If using Longhorn — all Longhorn pods healthy:
  ```bash
  kubectl get pods -n longhorn-system
  ```
- [ ] If using Longhorn — Longhorn UI accessible and shows node as schedulable

---

## 4. Ingress

- [ ] ingress-nginx pods are running:
  ```bash
  kubectl get pods -n ingress-nginx
  ```
- [ ] ingress-nginx service has an external IP or NodePort:
  ```bash
  kubectl get svc -n ingress-nginx
  ```
- [ ] A test Ingress responds on port 80:
  ```bash
  curl -H "Host: test.example.com" http://<NODE_IP>
  ```
- [ ] Port 80 and 443 are open through the node firewall

---

## 5. TLS

- [ ] cert-manager pods are running:
  ```bash
  kubectl get pods -n cert-manager
  ```
- [ ] cert-manager can issue a self-signed certificate (smoke test):
  ```bash
  kubectl apply -f - <<EOF
  apiVersion: cert-manager.io/v1
  kind: ClusterIssuer
  metadata:
    name: selfsigned
  spec:
    selfSigned: {}
  ---
  apiVersion: cert-manager.io/v1
  kind: Certificate
  metadata:
    name: test-cert
    namespace: default
  spec:
    secretName: test-cert-tls
    issuerRef:
      name: selfsigned
      kind: ClusterIssuer
    dnsNames: [test.example.com]
  EOF
  kubectl get certificate test-cert   # should reach Ready=True
  kubectl delete certificate test-cert
  kubectl delete clusterissuer selfsigned
  ```
- [ ] API server TLS cert covers the node IP (remote kubectl works without `--insecure-skip-tls-verify`):
  ```bash
  openssl s_client -connect <NODE_IP>:6443 </dev/null 2>/dev/null \
    | openssl x509 -noout -ext subjectAltName
  ```

---

## 6. Remote kubectl Access

- [ ] Kubeconfig copied to workstation and server IP substituted:
  ```bash
  scp root@<NODE_IP>:/etc/rancher/k3s/k3s.yaml ~/.kube/k3s.yaml
  sed -i 's/127.0.0.1/<NODE_IP>/g' ~/.kube/k3s.yaml
  export KUBECONFIG=~/.kube/k3s.yaml
  ```
- [ ] `kubectl get nodes` works from the workstation
- [ ] Kubeconfig file has restrictive permissions:
  ```bash
  chmod 600 ~/.kube/k3s.yaml
  ```

---

## 7. Security

- [ ] Secrets are encrypted at rest (`SECRETS_ENCRYPTION=true` was set before install):
  ```bash
  # value should show as encrypted bytes, not plaintext
  sudo grep -r "data:" /var/lib/rancher/k3s/server/db/etcd/member | head -5
  ```
- [ ] RBAC is enabled (on by default in k3s — verify):
  ```bash
  kubectl auth can-i create pods --as=system:anonymous   # should return "no"
  ```
- [ ] No workloads running as root unnecessarily:
  ```bash
  kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.spec.securityContext}{"\n"}{end}'
  ```
- [ ] Node firewall only exposes required ports (see checklist 1.1)
- [ ] RHEL only — k3s-selinux policy installed and SELinux is Enforcing:
  ```bash
  getenforce
  rpm -q k3s-selinux
  ```
- [ ] Kubeconfig on the server is not world-readable:
  ```bash
  ls -la /etc/rancher/k3s/k3s.yaml   # should be 600 root:root
  ```

---

## 8. etcd Backup

- [ ] Snapshot schedule is configured (check `/var/lib/rancher/k3s/server/db/snapshots`):
  ```bash
  ls -lh /var/lib/rancher/k3s/server/db/snapshots/
  ```
- [ ] Trigger a manual snapshot and confirm it appears:
  ```bash
  k3s etcd-snapshot save --name pre-production
  ls /var/lib/rancher/k3s/server/db/snapshots/
  ```
- [ ] If S3 is configured — confirm snapshot uploaded to bucket
- [ ] Restoration procedure is documented and tested (see `docs/5_k3s_state_store.md`)

---

## 9. Observability

- [ ] metrics-server is returning node and pod metrics:
  ```bash
  kubectl top nodes
  kubectl top pods -A
  ```
- [ ] Logs are accessible:
  ```bash
  journalctl -u k3s -n 50
  kubectl logs -n kube-system -l app=flannel --tail=20
  ```
- [ ] Alerting or monitoring agent deployed (Prometheus, Grafana, etc.)

---

## 10. Node Resilience

- [ ] Reboot the node and confirm k3s restarts automatically and cluster returns to healthy:
  ```bash
  sudo reboot
  # after reboot:
  systemctl status k3s
  kubectl get nodes
  kubectl get pods -A
  ```
- [ ] Eviction thresholds are set appropriately for available RAM (check `.env` values)

---

## Summary Table

| Area            | Command to verify                        |
| --------------- | ---------------------------------------- |
| Nodes           | `kubectl get nodes -o wide`              |
| Pods            | `kubectl get pods -A`                    |
| DNS             | `nslookup kubernetes.default` from a pod |
| Storage         | Create and bind a PVC                    |
| Ingress         | `curl -H "Host: ..." http://<NODE_IP>`   |
| TLS             | `openssl s_client` against :6443         |
| Remote kubectl  | `kubectl get nodes` from workstation     |
| RBAC            | `kubectl auth can-i` as anonymous        |
| etcd snapshot   | `k3s etcd-snapshot save`                 |
| Metrics         | `kubectl top nodes`                      |
| Reboot recovery | Reboot + check k3s auto-restart          |
