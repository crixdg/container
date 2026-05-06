# k3s — Production Setup Guide

Lightweight Kubernetes for small production hosts. This setup targets resource-constrained servers (1-4 vCPU, 2-8 GB RAM) while providing production-grade features: HA control plane, encrypted secrets, persistent storage via Longhorn, TLS via cert-manager, and full observability through the existing Prometheus/Grafana stack in this repo.

---

## What is installed

| Component | Replaces | Why |
|-----------|----------|-----|
| k3s (embedded etcd) | kubeadm + external etcd | Single binary, low overhead |
| ingress-nginx | Traefik (k3s default) | Consistent with this repo's other deployments |
| Longhorn | local-path (optional upgrade) | Replicated block storage, snapshots, backup |
| cert-manager | Manual TLS | Automatic Let's Encrypt certificate renewal |

**Default storage:** local-path provisioner is kept enabled out of the box. Longhorn can be installed alongside it and promoted to the default when you are ready — see `docs/migrate-to-longhorn.md`.

Built-in k3s components that are **always disabled**: `traefik`, `servicelb`.
`local-storage` is disabled only when `DISABLE_LOCAL_STORAGE=true` is set in `.env`.

---

## Prerequisites

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| OS | Ubuntu 22.04 / Debian 12 / RHEL 9 | Ubuntu 22.04 LTS |
| CPU | 1 vCPU | 2 vCPU |
| RAM | 1 GB | 2 GB |
| Disk | 20 GB | 40 GB |
| Network | Static IP | Static IP |
| Open-iSCSI | Required by Longhorn | Installed by preflight playbook |

Root or `sudo` access is required on all nodes.

For HA, use **3 server nodes** (odd number for etcd quorum). A single node is supported for non-HA production.

---

## File Layout

```
kubernetes/k3s/
├── README.md                          ← this file
├── config.env                         ← template; copy to .env and fill in values
├── registries.yaml                    ← private registry mirror config
│
├── ansible/
│   ├── inventory/
│   │   └── hosts.ini                  ← node IPs and roles
│   └── playbook/
│       ├── site.yml                   ← full provisioning (runs all steps below)
│       ├── preflight.yml              ← OS prep: swap, sysctl, dependencies
│       ├── firewall.yml               ← open required ports
│       ├── install-servers.yml        ← install k3s server nodes (HA-aware)
│       ├── install-agents.yml         ← join worker nodes
│       └── clean.yml                  ← teardown
│
└── helm/
    ├── install-essentials.sh          ← install all three components in order
    ├── cert-manager/
    │   ├── install.sh
    │   └── letsencrypt-http01.yaml    ← ClusterIssuer for Let's Encrypt
    ├── ingress-nginx/
    │   ├── install.sh
    │   └── helm-values.yaml
    └── longhorn/
        ├── install.sh
        └── helm-values.yaml
```

---

## Step 1 — Configure

```bash
cd kubernetes/k3s

# Copy and edit the config file
cp config.env .env
vi .env
```

Key values to set in `.env`:

| Variable | Description |
|----------|-------------|
| `FIRST_SERVER_IP` | IP of your first (or only) server node |
| `K3S_VERSION` | Pin a specific release, e.g. `v1.31.4+k3s1` |
| `EXTRA_SANS` | Extra IPs/hostnames in the API TLS cert (e.g. your domain) |
| `ETCD_S3_*` | S3 settings if you want off-node etcd backup (optional) |

Edit the inventory:

```bash
vi ansible/inventory/hosts.ini
# Set your server and agent IPs
```

---

## Step 2 — Provision OS (Ansible)

```bash
# Full provisioning (OS prep + firewall + k3s install)
ansible-playbook -i ansible/inventory/hosts.ini ansible/playbook/site.yml

# Or run individual steps
ansible-playbook -i ansible/inventory/hosts.ini ansible/playbook/preflight.yml
ansible-playbook -i ansible/inventory/hosts.ini ansible/playbook/firewall.yml
ansible-playbook -i ansible/inventory/hosts.ini ansible/playbook/install-servers.yml
ansible-playbook -i ansible/inventory/hosts.ini ansible/playbook/install-agents.yml
```

After the playbook completes, the first server prints the kubeconfig location and node token.

---

## Step 3 — Configure kubectl (remote workstation)

```bash
# Copy kubeconfig from the first server
scp root@<FIRST_SERVER_IP>:/etc/rancher/k3s/k3s.yaml ~/.kube/k3s.yaml

# Point it to the public IP
sed -i "s/127.0.0.1/<FIRST_SERVER_IP>/g" ~/.kube/k3s.yaml

export KUBECONFIG=~/.kube/k3s.yaml
kubectl get nodes
```

---

## Step 4 — Install Helm essentials

Run from a machine with `kubectl` and `helm` access to the cluster:

```bash
# Add required Helm repos first
helm repo add longhorn      https://charts.longhorn.io
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add jetstack      https://charts.jetstack.io
helm repo update

# Install cert-manager, ingress-nginx, and Longhorn in one shot
bash kubernetes/k3s/helm/install-essentials.sh
```

Or install individually if you need to customise the order:

```bash
bash kubernetes/k3s/helm/cert-manager/install.sh
bash kubernetes/k3s/helm/ingress-nginx/install.sh
bash kubernetes/k3s/helm/longhorn/install.sh
```

---

## Step 5 — TLS certificates (cert-manager)

For public domains (HTTP-01 challenge):

```bash
# Edit the email address first
vi kubernetes/k3s/helm/cert-manager/letsencrypt-http01.yaml

kubectl apply -f kubernetes/k3s/helm/cert-manager/letsencrypt-http01.yaml
```

Annotate any Ingress to get a certificate automatically:

```yaml
annotations:
  cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  tls:
    - hosts:
        - myapp.example.com
      secretName: myapp-tls
```

---

## Step 6 — Observability

The existing Helm values in `helm-charts/` work on k3s without changes. The storage class is `longhorn`.

```bash
# Add repos
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana              https://grafana.github.io/helm-charts
helm repo update

# Deploy (same values as the kubeadm cluster)
helm install prometheus prometheus-community/prometheus \
  -f helm-charts/prometheus/helm-values.yaml \
  -n monitor --create-namespace

helm install grafana grafana/grafana \
  -f helm-charts/grafana/helm-values.yaml \
  -n monitor
```

---

## Private Registry Mirror (optional)

```bash
# Edit registries.yaml with your Nexus or Harbor URL
vi kubernetes/k3s/registries.yaml

# Copy to all nodes before install (or after — restart k3s to pick it up)
ansible k3s_cluster -i ansible/inventory/hosts.ini -m copy \
  -a "src=kubernetes/k3s/registries.yaml dest=/etc/rancher/k3s/registries.yaml mode=0600"

ansible k3s_cluster -i ansible/inventory/hosts.ini -m service \
  -a "name=k3s state=restarted" --limit k3s_servers
ansible k3s_agents  -i ansible/inventory/hosts.ini -m service \
  -a "name=k3s-agent state=restarted"
```

---

## Production Hardening Reference

The following is applied automatically by the install playbooks and config:

| Hardening | Mechanism |
|-----------|-----------|
| Secrets encrypted at rest | `secrets-encryption: true` in k3s config |
| API audit log | Written to `DATA_DIR/server/logs/audit.log`, 7-day retention |
| etcd snapshots | Every 6 hours, 5 retained (configure S3 in `.env` for off-node) |
| Memory eviction thresholds | kubelet evicts pods before OOM kills the node |
| TLS 1.2+ only | Enforced in ingress-nginx config |
| HSTS headers | Enabled in ingress-nginx config |
| Longhorn UI auth | Basic auth secret required (created during `longhorn/install.sh`) |
| Traefik/servicelb disabled | Always disabled; use ingress-nginx instead |
| local-path | Kept enabled by default; set `DISABLE_LOCAL_STORAGE=true` to remove |

---

## Teardown

```bash
ansible-playbook -i ansible/inventory/hosts.ini ansible/playbook/clean.yml
```

---

## Firewall Ports Reference

| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 6443 | TCP | Any → server | Kubernetes API |
| 2379-2380 | TCP | Server → server | etcd client/peer |
| 8472 | UDP | Any → any | Flannel VXLAN overlay |
| 51820 | UDP | Any → any | WireGuard (if enabled) |
| 10250 | TCP | Agent → server | Kubelet metrics |
| 80 / 443 | TCP | External → ingress node | HTTP/HTTPS ingress |

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Node stuck in `NotReady` | `journalctl -u k3s -f` on the node |
| etcd quorum lost | Need 2 of 3 servers up; check `k3s etcd-snapshot ls` |
| Longhorn volumes stuck | `kubectl -n storage-controller get pods`; check iSCSI: `systemctl status iscsid` |
| cert-manager not issuing | `kubectl describe certificaterequest -A`; verify port 80 is reachable |
| API unreachable from remote | Verify your IP is in `EXTRA_SANS`; re-run `install-servers.yml` |
| High memory on small host | Lower `EVICTION_HARD_MEMORY` in `.env` and re-run `install-servers.yml` |

---

## Differences vs. kubeadm (this repo's full cluster)

| Feature | k3s (this dir) | kubeadm (`ansible/kubernetes-setup/`) |
|---------|----------------|---------------------------------------|
| Setup | Ansible + single binary | Ansible + multi-component |
| Minimum RAM | 1 GB | 2 GB per node |
| Default CNI | Flannel (built-in) | Cilium (separate install) |
| Ingress | ingress-nginx (Helm) | ingress-nginx (Helm) — same |
| Storage | Longhorn (Helm) | Longhorn (Helm) — same |
| HA control plane | Embedded etcd | External etcd or stacked |
| Best for | Small / edge production | Large multi-node production |
