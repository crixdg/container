# Scheduling

<details>
<summary><b>Q: What is podAntiAffinity and what are the ways to configure it?</b></summary>

Tells the scheduler to avoid placing a pod on a node that already runs pods matching a given label selector. Used to spread replicas across nodes/zones for HA.

<details>
<summary>Two modes</summary>

| Mode | Behavior |
|------|----------|
| `requiredDuringSchedulingIgnoredDuringExecution` | Hard — pod stays Pending if no valid node |
| `preferredDuringSchedulingIgnoredDuringExecution` | Soft — scheduler tries but proceeds anyway |

</details>

<details>
<summary>1. Hard anti-affinity — never co-locate on same node</summary>

```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: my-app
        topologyKey: kubernetes.io/hostname
```

</details>

<details>
<summary>2. Soft anti-affinity — prefer spreading, allow co-location if needed</summary>

```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app: my-app
          topologyKey: kubernetes.io/hostname
```

</details>

<details>
<summary>3. Zone-level spread — spread across availability zones</summary>

```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app: my-app
          topologyKey: topology.kubernetes.io/zone
```

</details>

<details>
<summary>topologyKey values</summary>

| topologyKey | Spreads across |
|-------------|---------------|
| `kubernetes.io/hostname` | individual nodes |
| `topology.kubernetes.io/zone` | availability zones |
| `topology.kubernetes.io/region` | regions |

</details>

<details>
<summary>podAntiAffinity vs topologySpreadConstraints</summary>

`topologySpreadConstraints` is a newer, more expressive alternative — preferred for fine-grained spread control (e.g. max skew).

</details>

</details>

---

<details>
<summary><b>Q: Which Kubernetes workload types support podAntiAffinity?</b></summary>

Set on the **Pod spec** — any object with `spec.template.spec` can use it:

| Object | Applies? | Notes |
|--------|----------|-------|
| `Pod` | yes | directly in `spec.affinity` |
| `Deployment` | yes | `spec.template.spec.affinity` |
| `StatefulSet` | yes | same |
| `DaemonSet` | yes | limited effect — already one pod per node |
| `ReplicaSet` | yes | same |
| `Job` / `CronJob` | yes | same |

Not applicable to: `Service`, `ConfigMap`, `PersistentVolume`, `Ingress`.

> For DaemonSets (e.g. Cilium agent), anti-affinity has minimal effect. It matters on the **Cilium operator** (Deployment) for HA.

</details>

---

<details>
<summary><b>Q: Is it safe to untaint all 3 control plane nodes?</b></summary>

**Yes — it's a common and accepted pattern**, especially for small clusters where control plane nodes double as workers.

```bash
# Remove the taint (trailing `-` = remove)
kubectl taint nodes <node> node-role.kubernetes.io/control-plane:NoSchedule-
```

<details>
<summary>When it's fine</summary>

- 3-node cluster where control plane = all nodes (no separate workers)
- Resource-constrained on-prem or homelab
- Dev/staging clusters
- Cilium Agent already tolerates the taint (DaemonSet) — untainting doesn't affect it

</details>

<details>
<summary>When to be careful</summary>

- **etcd is co-located** — etcd is sensitive to I/O and memory pressure; competing workloads can cause leader election timeouts
- **No resource limits on workloads** — noisy-neighbor pods can starve `kube-apiserver`/`etcd`/`kube-scheduler`

</details>

<details>
<summary>Safe pattern</summary>

Untaint all 3, but enforce resource requests on all workloads and reserve headroom for system components:

```bash
# kubelet flags to reserve resources for system + k8s components
--system-reserved=cpu=200m,memory=256Mi
--kube-reserved=cpu=200m,memory=256Mi
```

Give control plane components `system-cluster-critical` PriorityClass so they're never evicted first.

</details>

**Bottom line:** Standard k3s/kubeadm small-cluster pattern. Just ensure all workloads have resource requests set so etcd is protected under load.

</details>

---
