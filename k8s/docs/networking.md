# Networking

<details>
<summary><b>Q: What problem does kube-proxy solve?</b></summary>

Without kube-proxy, a `Service` ClusterIP is just a virtual IP in etcd — nothing routes traffic to actual pods. kube-proxy makes that VIP functional.

**Core problem:** Pods have ephemeral IPs that change on restart. A `Service` provides a stable VIP, but something must translate VIP → real pod IP at the network level on every node. That's kube-proxy.

**What it does:**
1. Watches API server for `Service` and `Endpoints` changes
2. Programs the node's network stack so traffic to `ClusterIP:port` is forwarded to a healthy pod
3. Load balances across all pods behind a Service

<details>
<summary>Three implementation modes</summary>

| Mode | Mechanism | Tradeoff |
|------|-----------|----------|
| `iptables` (default) | NAT rules in kernel | Simple, but O(n) rule matching — degrades at thousands of Services |
| `ipvs` | In-kernel L4 LB via hash table | O(1) lookup, more LB algorithms, requires ipvs kernel modules |
| `nftables` (beta, k8s 1.31+) | Replaces iptables with nftables | Cleaner rules, better scale than iptables |

</details>

<details>
<summary>kube-proxy vs Cilium eBPF replacement</summary>

With Cilium `kubeProxyReplacement: true`, kube-proxy is replaced entirely — Cilium handles Service routing in eBPF at the socket/XDP layer, bypassing iptables/IPVS. Faster and lower overhead.

</details>

</details>

---

<details>
<summary><b>Q: What problems does Cilium solve?</b></summary>

kube-proxy + traditional CNI work at L3/L4 using iptables — they can't see inside packets and don't scale well. Cilium uses **eBPF** to run sandboxed kernel programs at near-native speed with full packet visibility.

<details>
<summary>1. iptables doesn't scale</summary>

iptables rules are a linear chain — every packet walks every rule. At 5k+ Services, latency and CPU overhead grow. Cilium replaces this with eBPF maps (O(1) hash lookups) at the socket layer — packets are redirected before hitting the network stack.

</details>

<details>
<summary>2. No L7 visibility in standard NetworkPolicy</summary>

Standard `NetworkPolicy` allows/denies only by IP and port. Cilium extends this with `CiliumNetworkPolicy` — L7-aware rules for HTTP, gRPC, Kafka, DNS (e.g. allow GET /api, deny POST /admin).

</details>

<details>
<summary>3. IP-based security doesn't work with ephemeral pods</summary>

IPs change on every pod restart. Cilium assigns a **security identity** to every pod based on its labels, stored in an eBPF map. Policy enforcement is identity-based, not IP-based — stable across restarts.

</details>

<details>
<summary>4. No network observability</summary>

iptables is a black box. Cilium ships **Hubble** — a built-in observability layer recording every flow at L3–L7, queryable via CLI or UI, powered by the same eBPF hooks.

</details>

<details>
<summary>5. Sidecar service mesh overhead</summary>

Traditional service meshes (Istio) inject a sidecar proxy per pod — doubles network hops, adds memory overhead. Cilium's sidecar-free service mesh (mTLS, traffic management) runs in eBPF + Envoy at the node level.

</details>

**Summary:** Cilium replaces iptables + kube-proxy + basic CNI + NetworkPolicy + service mesh observability with a unified eBPF data plane — faster, identity-aware, and L7-capable.

</details>

---

<details>
<summary><b>Q: Should the Cilium Operator be deployed on control plane or worker nodes?</b></summary>

**Control plane nodes** — Cilium's default and recommended placement.

The Operator is a cluster management process (handles IPAM, CiliumNetworkPolicy, node discovery) — not in the data path. It belongs alongside `kube-controller-manager`, not on workers. If the operator goes down, the data plane (Cilium agents on workers) keeps running — existing pod networking stays up.

<details>
<summary>Helm values to pin operator to control plane</summary>

```yaml
operator:
  nodeSelector:
    node-role.kubernetes.io/control-plane: ""
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      effect: NoSchedule
```

Control plane nodes have a `NoSchedule` taint by default — the operator must explicitly tolerate it.

</details>

<details>
<summary>HA setup — multiple control plane nodes</summary>

```yaml
operator:
  replicas: 2
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: kubernetes.io/hostname
```

With 3 control plane nodes, `replicas: 2` + `podAntiAffinity` spreads operator replicas across nodes — no single point of failure.

</details>

</details>

---

<details>
<summary><b>Q: What is the Cilium Agent and what does it do?</b></summary>

The per-node daemon that enforces everything — the actual data plane worker. Runs as a **DaemonSet** (one pod per node, including control plane nodes).

<details>
<summary>1. Programs eBPF into the kernel</summary>

On startup and whenever policy/endpoints change, the agent compiles and loads eBPF programs into the kernel — attached to network interfaces, sockets, and TC hooks. This is what actually routes and filters traffic.

</details>

<details>
<summary>2. Manages pod networking (CNI)</summary>

When kubelet creates a pod, it calls the Cilium CNI plugin → local agent. The agent:
- Allocates an IP from the IPAM pool (coordinated with the Operator)
- Creates a veth pair between the pod and the node
- Attaches eBPF programs to the pod's interface

</details>

<details>
<summary>3. Enforces NetworkPolicy</summary>

Watches `NetworkPolicy` and `CiliumNetworkPolicy`. Translates them into eBPF map entries. Enforcement is in-kernel — packets are allowed/dropped before reaching the pod.

</details>

<details>
<summary>4. Handles Service load balancing (kube-proxy replacement)</summary>

When `kubeProxyReplacement: true`, the agent programs eBPF maps for every `Service` ClusterIP/NodePort/LoadBalancer at the socket layer — faster than iptables, applied earlier in the stack.

</details>

<details>
<summary>5. Feeds Hubble observability</summary>

Every eBPF hook emits flow events. The agent's built-in Hubble server collects these per-node. Hubble Relay aggregates across all agents cluster-wide.

</details>

<details>
<summary>Agent vs Operator</summary>

| | Cilium Agent | Cilium Operator |
|--|--|--|
| Runs on | Every node (DaemonSet) | Control plane only (Deployment) |
| Role | Data plane — does the actual work | Control plane — manages cluster-wide state |
| If it restarts | That node loses enforcement briefly | Data plane keeps running unaffected |
| Talks to | Local kernel (eBPF), local kubelet | Kubernetes API server, etcd |

</details>

</details>

---
