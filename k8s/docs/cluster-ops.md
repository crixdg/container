# Cluster Operations

<details>
<summary><b>Q: What is the recommended production setup with only 3 hosts?</b></summary>

**All 3 as control plane nodes, untainted (stacked etcd).** The only option that gives HA with 3 hosts — a single control plane node is not production-grade (one failure takes down the cluster API).

With 3 control plane nodes: etcd has quorum, can survive 1 node loss.

<details>
<summary>Architecture</summary>

```
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│   node-1        │  │   node-2        │  │   node-3        │
│  kube-apiserver │  │  kube-apiserver │  │  kube-apiserver │
│  etcd           │  │  etcd           │  │  etcd           │
│  scheduler      │  │  scheduler      │  │  scheduler      │
│  controller-mgr │  │  controller-mgr │  │  controller-mgr │
│  ─────────────  │  │  ─────────────  │  │  ─────────────  │
│  kubelet        │  │  kubelet        │  │  kubelet        │
│  Cilium agent   │  │  Cilium agent   │  │  Cilium agent   │
│  workloads      │  │  workloads      │  │  workloads      │
└─────────────────┘  └─────────────────┘  └─────────────────┘
         etcd quorum: can lose 1 node and stay operational
```

</details>

<details>
<summary>etcd — most critical piece</summary>

etcd needs fast local SSDs (not NAS/NFS). Disk latency directly causes API server slowness and leader election timeouts.

- Dedicated disk for etcd data (`/var/lib/etcd`), separate from OS disk if possible
- Monitor `etcd_disk_wal_fsync_duration_seconds` — p99 must stay under 10ms

</details>

<details>
<summary>Cilium setup</summary>

```yaml
operator:
  replicas: 2
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: kubernetes.io/hostname
  nodeSelector:
    node-role.kubernetes.io/control-plane: ""
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      effect: NoSchedule

kubeProxyReplacement: true
```

</details>

<details>
<summary>Resource protection for system components</summary>

Set kubelet reserved resources on every node — etcd/apiserver always need headroom:

```yaml
# /etc/kubernetes/kubelet-config.yaml
systemReserved:
  cpu: 500m
  memory: 512Mi
kubeReserved:
  cpu: 500m
  memory: 512Mi
evictionHard:
  memory.available: 500Mi
```

All workloads must have `resources.requests` set — unset requests allow overcommit and starve etcd.

</details>

<details>
<summary>Workload HA — spread critical pods</summary>

Anti-affinity to spread replicas across nodes:

```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: kubernetes.io/hostname
```

PodDisruptionBudget to protect replicas during rolling updates:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: my-app
```

</details>

<details>
<summary>API server load balancer (required for HA)</summary>

3 API servers need a single stable endpoint. Options:

| Option | Notes |
|--------|-------|
| **kube-vip** | VIP via static pod on control plane nodes — recommended for on-prem, no extra infra |
| HAProxy + keepalived | Classic on-prem VIP via VRRP |
| External LB | Hardware LB or cloud LB if available |

</details>

<details>
<summary>Failure tolerance</summary>

| Scenario | Result |
|----------|--------|
| 1 node reboots | etcd quorum holds (2/3), API stays up, workloads reschedule |
| 2 nodes down | etcd loses quorum — cluster read-only, no scheduling |
| etcd disk fills | Cluster goes read-only — monitor disk proactively |

</details>

</details>

---
