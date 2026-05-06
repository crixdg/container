# Migrate Flannel to Cilium

Flannel is embedded in the k3s binary and cannot be hot-swapped on a running cluster. Every node must have k3s restarted with Flannel disabled before Cilium takes over. This causes a **brief pod network outage per node** — plan for a maintenance window.

---

## Before you start

- [ ] Cluster is healthy: `kubectl get nodes` — all nodes `Ready`
- [ ] All workloads are running: `kubectl get pods -A` — no `Pending` or `CrashLoopBackOff`
- [ ] etcd snapshot taken: `k3s etcd-snapshot save --name pre-cilium-migration`
- [ ] You have SSH access to all nodes
- [ ] Linux kernel 5.4+ on all nodes (required by Cilium): `uname -r`
- [ ] Helm is installed on your workstation

> **Downtime scope:** pod-to-pod networking on each node is interrupted for ~2 minutes while k3s restarts. Nodes are migrated one at a time — other nodes stay up.

---

## How it works

```
Before                          After
──────────────────────          ──────────────────────
k3s (Flannel built-in)          k3s (Flannel disabled)
    │                               │
    ▼                               ▼
Flannel DaemonSet               Cilium DaemonSet
VXLAN overlay                   eBPF overlay
No NetworkPolicy                Full NetworkPolicy (L3–L7)
```

The migration has three phases:

```
Phase 1 — Disable Flannel on all nodes (one at a time)
Phase 2 — Install Cilium
Phase 3 — Verify and clean up
```

---

## Phase 1 — Disable Flannel on all nodes

Repeat the steps below for **each node**, starting with agent nodes and finishing with server nodes. Never migrate all nodes at once — keep the cluster reachable.

### 1a — Drain the node

```bash
# Run from your workstation
kubectl drain <node-name> \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=120s
```

### 1b — SSH into the node and stop k3s

```bash
# On server nodes
systemctl stop k3s

# On agent nodes
systemctl stop k3s-agent
```

### 1c — Update the k3s config to disable Flannel

```bash
# Edit /etc/rancher/k3s/config.yaml on the node
# Add or update the following lines:

flannel-backend: none
disable-network-policy: true
```

For server nodes, also ensure `disable` includes `local-storage` is not accidentally re-enabled. Your config should look like:

```yaml
# /etc/rancher/k3s/config.yaml (server node)
flannel-backend: none
disable-network-policy: true
disable:
  - traefik
  - servicelb
```

### 1d — Clean up Flannel network interfaces

Flannel leaves virtual interfaces and iptables rules behind. Remove them before restarting k3s:

```bash
# Remove Flannel interface
ip link delete flannel.1 2>/dev/null || true
ip link delete cni0 2>/dev/null || true

# Flush Flannel iptables rules
iptables -F
iptables -t nat -F
iptables -t mangle -F
iptables -X

# Remove CNI config
rm -f /etc/cni/net.d/10-flannel.conflist
rm -f /var/lib/rancher/k3s/agent/etc/cni/net.d/10-flannel.conflist
```

### 1e — Restart k3s

```bash
# On server nodes
systemctl start k3s

# On agent nodes
systemctl start k3s-agent
```

### 1f — Uncordon the node

```bash
kubectl uncordon <node-name>
```

> **What happens to running applications during Phase 1:**
>
> When you drain a node (`kubectl drain`), Kubernetes evicts all pods from that node and reschedules them onto other nodes before you touch anything. So at the moment k3s restarts:
>
> | Pod location                    | What happens                                                                    |
> | ------------------------------- | ------------------------------------------------------------------------------- |
> | Pods on the node being migrated | Evicted and rescheduled to other nodes by `kubectl drain`                       |
> | Pods on other nodes             | Unaffected — still running normally                                             |
> | DaemonSet pods                  | Not evicted (`--ignore-daemonsets`) — they restart with k3s and wait for Cilium |
>
> **The network gap:** after k3s restarts on the migrated node, it has no CNI. Any pod rescheduled back onto this node will stay `Pending` until Cilium is installed in Phase 2. Kubernetes will not schedule new pods here during this window.
>
> **For your application to survive drain**, it must have more than one replica running on different nodes. A single-replica Deployment will go down for the duration of the node migration.
>
> ```bash
> # Check replica count before draining
> kubectl get deployments -A
>
> # Scale up to 2+ replicas if needed
> kubectl scale deployment <name> -n <namespace> --replicas=2
> ```

> **What happens if you only have 1 replica during Phase 1:**
>
> ```
> Timeline
> ────────────────────────────────────────────────────────────
> kubectl drain <node>
>   → Pod evicted from node                 ← pod is DELETED
>   → Kubernetes schedules it on another node
>   → Pod starts on other node              ← pod is back up
>   → k3s restarts, Flannel removed
>   → Node has no CNI
>   → Any new pod scheduled here → Pending
>
> At this point your single replica is running on another node.
> Application is UP but with a gap of ~30–60s during reschedule.
> ────────────────────────────────────────────────────────────
> ```
>
> The gap happens because:
>
> 1. Kubernetes waits for the pod to be fully terminated before starting a new one
> 2. The new pod must be pulled, started, and pass health checks on the other node
>
> | Replica count                  | What the user sees                        |
> | ------------------------------ | ----------------------------------------- |
> | 1 replica                      | ~30–60s downtime while pod reschedules    |
> | 2+ replicas on different nodes | No downtime — one replica keeps serving   |
> | 2 replicas on the SAME node    | Same as 1 replica — both evicted together |
>
> > **Important:** 2 replicas only helps if they are on **different nodes**. Use a `podAntiAffinity` rule to guarantee this:
> >
> > ```yaml
> > spec:
> >   affinity:
> >     podAntiAffinity:
> >       requiredDuringSchedulingIgnoredDuringExecution:
> >         - labelSelector:
> >             matchLabels:
> >               app: <your-app>
> >           topologyKey: kubernetes.io/hostname
> > ```
> >
> > This forces Kubernetes to never schedule two replicas of the same app on the same node.

> At this point the node is running without any CNI — pods will be in `Pending` state until Cilium is installed in Phase 2. This is expected.

### 1g — Repeat for all remaining nodes

Work through agent nodes first, then server nodes. Verify each node rejoins before moving to the next:

```bash
kubectl get nodes   # node should return to Ready (NotReady is also ok — CNI is missing)
```

---

## Phase 2 — Install Cilium

**What happens to applications between Phase 1 and Phase 2:**

Once Flannel is disabled on the last node, the cluster has no CNI on any node. This is the most critical window in the migration.

```
All nodes — no CNI
────────────────────────────────────────────────────────────────────
Node 1          Node 2          Node 3
──────────      ──────────      ──────────
k3s running     k3s running     k3s running
Flannel: gone   Flannel: gone   Flannel: gone
Cilium: not yet Cilium: not yet Cilium: not yet

Existing running pods:
  → Still running — their network interfaces were created by
    Flannel and are still active inside the pod's namespace.
    Traffic between pods on the SAME node still works.
    Traffic between pods on DIFFERENT nodes is BROKEN.

New pods or rescheduled pods:
  → Stuck in Pending — no CNI to assign them an IP.

Services:
  → ClusterIP routing still works via kube-proxy iptables rules,
    but only if the destination pod is still running.
```

> **Key point:** pods that were already running before Phase 1 keep their Flannel-assigned IPs and interfaces. They do not crash immediately. But cross-node traffic fails because Flannel's VXLAN tunnels are gone. Any pod-to-pod call that crosses a node boundary will time out.

| Situation                       | During Phase 2 gap                                                  |
| ------------------------------- | ------------------------------------------------------------------- |
| Same-node pod-to-pod traffic    | Works                                                               |
| Cross-node pod-to-pod traffic   | Broken                                                              |
| New or rescheduled pods         | Stuck `Pending`                                                     |
| ClusterIP Services (same node)  | Works                                                               |
| ClusterIP Services (cross node) | Broken                                                              |
| External ingress traffic        | Depends — broken if backend pod is on a different node than ingress |

> **Minimize this window** — run Phase 2 immediately after Phase 1 completes. The gap should be under 5 minutes. Do not take a break between phases.

Run from your workstation once **all nodes** have Flannel disabled.

### 2a — Add the Helm repo

```bash
helm repo add cilium https://helm.cilium.io
helm repo update cilium
```

### 2b — Install Cilium

```bash
helm install cilium cilium/cilium \
  --version 1.17.0 \
  -f kubernetes/essential/cilium/values.yaml \
  -n kube-system \
  --wait --timeout 5m
```

> Cilium is installed into `kube-system` rather than a separate namespace because it needs access to the host network and kernel — the same namespace as kube-proxy and CoreDNS.

### 2c — Wait for Cilium pods to be Ready

```bash
kubectl -n kube-system rollout status daemonset/cilium
kubectl get pods -n kube-system -l k8s-app=cilium
# All pods should show Running
```

---

## Phase 3 — Verify

### Check all nodes have a Cilium agent

```bash
kubectl get pods -n kube-system -l k8s-app=cilium -o wide
# One pod per node, all Running
```

### Check pod-to-pod connectivity

```bash
# Run a temporary pod and curl another pod's IP directly
kubectl run test --image=alpine --rm -it --restart=Never -- \
  wget -qO- http://<pod-ip>:<port>
```

### Check NetworkPolicy is enforced

```bash
# Cilium CLI (optional — install from https://github.com/cilium/cilium-cli)
cilium connectivity test
```

### Check cluster DNS

```bash
kubectl run test --image=alpine --rm -it --restart=Never -- \
  nslookup kubernetes.default.svc.cluster.local
```

### Restart all workload pods

Pods that were running during the migration may still have stale Flannel network interfaces. Rolling restart forces them to get a fresh Cilium-managed interface:

```bash
# Restart all deployments
kubectl get deployments -A \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name \
  --no-headers | while read ns name; do
    kubectl rollout restart deployment "$name" -n "$ns"
  done

# Restart all statefulsets
kubectl get statefulsets -A \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name \
  --no-headers | while read ns name; do
    kubectl rollout restart statefulset "$name" -n "$ns"
  done
```

---

## Rollback

If Cilium fails to come up and you need to revert to Flannel:

```bash
# 1. Uninstall Cilium
helm uninstall cilium -n kube-system

# 2. On each node — remove flannel-backend: none from config.yaml
#    and restart k3s
systemctl restart k3s        # server
systemctl restart k3s-agent  # agent

# 3. Flannel will recreate its interface and CNI config automatically
```

---

## Realistic recommendation for this k3s setup

Two options depending on whether downtime is acceptable:

|            | Maintenance window | Blue-green (zero downtime)        |
| ---------- | ------------------ | --------------------------------- |
| Downtime   | ~5 minutes         | None                              |
| Complexity | Low                | High                              |
| Extra cost | None               | Double infrastructure temporarily |
| Risk       | Rollback is fast   | Rollback means switching DNS back |
| Best for   | Off-peak clusters  | SLA-critical production           |

---

### Option A — Maintenance window (~5 min downtime)

**The practical approach for small production clusters:**

### Step 0 — Prepare (day before)

- [ ] Identify all single-replica Deployments and scale them to 2+
- [ ] Confirm replicas are spread across different nodes
- [ ] Add `podAntiAffinity` to critical workloads (see Phase 1 note)
- [ ] Take an etcd snapshot: `k3s etcd-snapshot save --name pre-cilium`
- [ ] Verify rollback procedure is understood before starting

```bash
# Find all single-replica Deployments
kubectl get deployments -A \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,REPLICAS:.spec.replicas \
  --no-headers | awk '$3 == "1" {print $1, $2}'

# Scale all of them to 2 replicas
kubectl get deployments -A \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,REPLICAS:.spec.replicas \
  --no-headers | awk '$3 == "1" {print $1, $2}' | while read ns name; do
    kubectl scale deployment "$name" -n "$ns" --replicas=2
  done
```

### Step 1 — Schedule a maintenance window

Pick an off-peak window of **30 minutes**. 5 minutes is the expected duration — the extra time is buffer for unexpected issues.

Notify users:

```
Maintenance window: <date> <time> — <time+30min>
Impact: application unavailability up to 5 minutes
Reason: Kubernetes CNI upgrade (Flannel → Cilium)
```

### Step 2 — Run the migration

```bash
# Phase 1 — one node at a time, agents first
kubectl drain <agent-01> --ignore-daemonsets --delete-emptydir-data
# ... disable Flannel, restart k3s, uncordon (see Phase 1 steps)

kubectl drain <server-01> --ignore-daemonsets --delete-emptydir-data
# ... repeat for all servers

# Phase 2 — install Cilium immediately, do not pause
helm install cilium cilium/cilium \
  --version 1.17.0 \
  -f kubernetes/essential/cilium/values.yaml \
  -n kube-system --wait --timeout 5m
```

> Do not pause between Phase 1 and Phase 2. The window where all nodes have no CNI should be kept under 5 minutes.

### Step 3 — Verify before closing the window

```bash
# All Cilium pods running
kubectl get pods -n kube-system -l k8s-app=cilium

# All nodes Ready
kubectl get nodes

# All application pods Running
kubectl get pods -A | grep -v Running | grep -v Completed
```

### Step 4 — Rolling restart workloads

```bash
kubectl get deployments -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name \
  --no-headers | while read ns name; do
    kubectl rollout restart deployment "$name" -n "$ns"
  done
```

### If anything goes wrong — roll back immediately

```bash
helm uninstall cilium -n kube-system
# Then re-enable Flannel on each node and restart k3s
```

Do not attempt to fix Cilium issues during the maintenance window — roll back first, investigate later.

---

### Option B — Blue-green cluster (zero downtime)

Build a second k3s cluster with Cilium running in parallel, migrate traffic at the load balancer level, then decommission the old cluster.

```
Old cluster (Flannel)          New cluster (Cilium)
─────────────────────          ─────────────────────
Production traffic      Step 1: provision new cluster
       │                Step 2: deploy all workloads
       │                Step 3: test and verify
       │                Step 4: switch load balancer
       └──────────────────────────────► New cluster now serves traffic
                        Step 5: decommission old cluster
```

#### Step 1 — Provision new k3s cluster with Cilium

```bash
# On new nodes — set in config.env
FIRST_SERVER_IP=<new-server-ip>
DISABLE_LOCAL_STORAGE=false

# In ansible config — disable Flannel before install
flannel-backend: none
disable-network-policy: true

# Run full provisioning
ansible-playbook -i ansible/inventory/hosts.ini ansible/playbook/site.yml

# Install Cilium immediately after
helm install cilium cilium/cilium \
  --version 1.17.0 \
  -f kubernetes/essential/cilium/values.yaml \
  -n kube-system --wait
```

#### Step 2 — Deploy all workloads to the new cluster

```bash
# Point kubectl to the new cluster
export KUBECONFIG=~/.kube/k3s-new.yaml

# Re-apply all your manifests
kubectl apply -f manifests/

# Restore persistent data
# For each PVC — copy data from old cluster to new cluster PVC
# Follow the same procedure as docs/migrate-to-longhorn.md
```

#### Step 3 — Verify new cluster is healthy

```bash
# All pods running
kubectl get pods -A

# Test application endpoints directly against new cluster IP
curl http://<new-ingress-ip>/healthz

# Run smoke tests against new cluster before switching traffic
```

#### Step 4 — Switch traffic to new cluster

```bash
# Update your external load balancer or DNS to point to the new ingress IP
# For DNS — lower TTL to 60s a day before to speed up propagation

# Example: update DNS A record
# old-cluster.example.com  →  192.168.1.100  (old)
# old-cluster.example.com  →  192.168.1.200  (new)
```

> Monitor application metrics and error rates for 15–30 minutes after the switch before decommissioning the old cluster.

#### Step 5 — Decommission old cluster

```bash
# Only after confirming new cluster is stable
ansible-playbook -i ansible/inventory/hosts-old.ini ansible/playbook/clean.yml
```

#### Rollback

If issues appear after the DNS switch — point DNS back to the old cluster IP. The old cluster is still running and unchanged.

```
DNS switch back:  <domain>  →  <old-cluster-ip>
Takes effect in:  60s (if TTL was lowered in Step 4)
```

---

## Troubleshooting

| Symptom                               | Check                                                                                  |
| ------------------------------------- | -------------------------------------------------------------------------------------- |
| Cilium pods stuck in `Init`           | `kubectl describe pod -n kube-system <cilium-pod>` — usually a kernel version issue    |
| Pods `Pending` after Cilium installed | `kubectl get events -A` — CNI config not picked up; delete and recreate the pod        |
| Cross-node traffic fails              | Confirm Flannel interfaces are removed on all nodes: `ip link show flannel.1`          |
| DNS broken                            | Restart CoreDNS: `kubectl rollout restart deployment/coredns -n kube-system`           |
| NetworkPolicy not enforced            | Confirm `--disable-network-policy` is set in k3s config and Cilium is in `kube-system` |
