# k3s CNI (Container Network Interface)

CNI is the plugin layer that gives every Pod its own IP address and connects Pods across nodes. Without CNI, Pods would have no network — they could not talk to each other, reach Services, or be reached from outside the cluster.

> **Does a single-node cluster need CNI?**
> Yes — even with one node, CNI is required. Every Pod still needs its own IP so that Pods can reach each other and reach Services via ClusterIP. Without CNI, Pods stay in `Pending` state and never start.
> The difference on a single node is that no overlay tunnel is needed — all pod-to-pod traffic stays on the same host and goes through a virtual bridge interface. Flannel still runs, but the VXLAN tunnel is unused.

**Where CNI sits in the k3s system:**

```
Pod A (node 1)                    Pod B (node 2)
    │                                  │
    ▼                                  ▼
CNI plugin (Flannel)  ←────────→  CNI plugin (Flannel)
    │                                  │
    ▼                                  ▼
Node 1 network interface          Node 2 network interface
    │                                  │
    └──────────── LAN ─────────────────┘
```

> CNI runs as a DaemonSet — one pod on every node. When a new Pod is created, kubelet calls the CNI plugin to assign an IP and set up the network interface inside the Pod's namespace.

> **CNI vs kube-proxy — what each one does:**
>
> | | CNI (Flannel) | kube-proxy |
> |-|---------------|------------|
> | Assigns Pod IP | Yes | No |
> | Connects Pods across nodes | Yes | No |
> | Handles ClusterIP (Service) routing | No | Yes |
> | Handles NodePort / LoadBalancer routing | No | Yes |
>
> CNI owns **Pod-to-Pod** networking — it gives each Pod an IP and builds the tunnels between nodes.
> kube-proxy owns **Pod-to-Service** networking — it watches for Services and writes iptables rules so that traffic to a ClusterIP gets forwarded to the correct Pod IP.
> They work in layers: CNI delivers the packet to the right node, kube-proxy delivers it to the right Pod on that node.

**Visualization — Pod A calls a Service backed by Pod B on another node:**

```
NODE 1                                    NODE 2
─────────────────────────────────         ─────────────────────────────────
Pod A                                     Pod B
IP: 10.42.0.10                            IP: 10.42.1.20
    │                                              ▲
    │  1. Pod A sends to                           │
    │     ClusterIP 10.43.0.5                      │
    ▼                                              │
kube-proxy (iptables)                             │
    │  2. Rewrites destination:                    │
    │     10.43.0.5 → 10.42.1.20                  │
    ▼                                              │
CNI - Flannel (VXLAN)                    CNI - Flannel (VXLAN)
    │  3. Sees destination is on          │  5. Unwraps VXLAN packet
    │     Node 2 — wraps packet           │     Delivers to Pod B
    │     in VXLAN tunnel                 │     via virtual bridge
    ▼                                     │
Physical NIC (Node 1)                    Physical NIC (Node 2)
    │  4. Encrypted tunnel                │
    └─────── (WireGuard if enabled) ──────┘
                   LAN
```

> **Step by step:**
> 1. Pod A sends a packet to `ClusterIP 10.43.0.5` (the Service IP)
> 2. kube-proxy's iptables rule intercepts it and rewrites the destination to the real Pod IP `10.42.1.20`
> 3. Flannel sees the destination is on a different node and wraps the packet in a VXLAN tunnel
> 4. The wrapped packet travels over the LAN (encrypted if WireGuard is enabled)
> 5. Flannel on Node 2 unwraps it and delivers it to Pod B via a virtual bridge interface
>
> kube-proxy acts first (rewrites the IP), then CNI takes over (moves the packet across nodes).

> **Why does kube-proxy on Node 1 know to map `10.43.0.5` → `10.42.1.20`?**
>
> kube-proxy does not figure this out by itself — it watches the API server for **EndpointSlice** objects.
>
> When you create a Service, Kubernetes automatically creates an EndpointSlice that lists the real Pod IPs backing that Service, regardless of which node those pods are on:
> ```
> Service:        my-service  →  ClusterIP 10.43.0.5
> EndpointSlice:  my-service  →  [10.42.1.20]          ← Pod B's real IP
> ```
> kube-proxy on **every node** watches the API server and receives this EndpointSlice. It then writes an iptables rule locally on each node:
> ```
> packet to 10.43.0.5  →  rewrite destination to 10.42.1.20
> ```
> kube-proxy does not know or care which node `10.42.1.20` lives on — that is Flannel's job. It only knows "this Service maps to this Pod IP" because the API server told it so.
>
> This is why the same rule exists on Node 1, Node 2, and every other node — any pod in the cluster can reach the Service, and the local kube-proxy handles the rewrite before Flannel routes it to the correct node.

> **How does Flannel know `10.42.1.20` belongs to Node 2?**
>
> When k3s starts, it assigns each node a unique slice of the Pod CIDR:
> ```
> Node 1  →  10.42.0.0/24   (pods get IPs from .0.1 to .0.254)
> Node 2  →  10.42.1.0/24   (pods get IPs from .1.1 to .1.254)
> Node 3  →  10.42.2.0/24   (pods get IPs from .2.1 to .2.254)
> ```
> Flannel stores this mapping in etcd and programs a kernel routing table on every node:
> ```
> 10.42.0.0/24  →  local (this node)
> 10.42.1.0/24  →  tunnel to 192.168.1.101  (Node 2's real LAN IP)
> 10.42.2.0/24  →  tunnel to 192.168.1.102  (Node 3's real LAN IP)
> ```
> When the packet destination is `10.42.1.20`, the kernel matches the `10.42.1.0/24` route, hands it to Flannel's VXLAN interface, which wraps it in a UDP packet addressed to `192.168.1.101` (Node 2's real IP) and sends it over the LAN.
> Node 2's Flannel receives the UDP packet, unwraps it, and the inner packet with destination `10.42.1.20` is delivered locally to Pod B.
>
> The Pod IP alone is enough — the subnet tells Flannel exactly which physical node to tunnel to.

---

## Key concepts

**Pod CIDR** — the IP range allocated to pods across the whole cluster. Each node gets a slice of this range for its own pods. Default in k3s: `10.42.0.0/16`.

**Service CIDR** — a separate IP range for ClusterIP Services (virtual IPs that never exist on a real interface). Default in k3s: `10.43.0.0/16`.

**Overlay network** — a virtual network tunnelled over the physical LAN. Pods on different nodes communicate as if they are on the same flat network, even if the nodes are on different subnets. Flannel uses VXLAN for this.

**Network Policy** — rules that control which Pods can talk to which. Not all CNI plugins enforce them — Flannel does not; Cilium and Calico do.

---

## Options

### Flannel _(default in k3s)_

Simple, stable, low overhead. Uses VXLAN to create an overlay network between nodes.

|                |                                                     |
| -------------- | --------------------------------------------------- |
| Overhead       | Very low (~10 MB RAM)                               |
| Network Policy | No                                                  |
| Encryption     | No (use WireGuard backend for in-flight encryption) |
| Config         | Built into k3s — no separate install                |

**Use this for most small production clusters.** If you do not need Network Policy enforcement, Flannel is the right choice.

> To enable WireGuard encryption between nodes (encrypts pod-to-pod traffic in transit):
>
> ```bash
> # Add to k3s config.yaml
> flannel-backend: wireguard-native
> ```

> **What is WireGuard?**
> WireGuard is a modern VPN protocol built into the Linux kernel. When used as a Flannel backend, it wraps all pod-to-pod traffic in an encrypted tunnel between nodes — so even if someone intercepts packets on the LAN, they cannot read the contents.
>
> Without WireGuard, Flannel's VXLAN traffic is unencrypted. Anyone on the same network segment can sniff pod-to-pod traffic.
>
> | | Without WireGuard | With WireGuard |
> |-|-------------------|----------------|
> | Pod-to-pod traffic | Plaintext over LAN | Encrypted between nodes |
> | CPU overhead | None | Small (~5% on modern CPUs) |
> | Key management | None needed | Automatic (k3s handles it) |
> | Kernel requirement | Any | Linux 5.6+ (Ubuntu 20.04+) |
>
> On a single node WireGuard has no effect — there are no cross-node tunnels to encrypt.

---

### Cilium

eBPF-based CNI. Replaces iptables with kernel-level programs for much higher throughput and lower latency. Full Network Policy support including L7 (HTTP-aware) rules.

|                |                                                |
| -------------- | ---------------------------------------------- |
| Overhead       | Medium (~100 MB RAM per node)                  |
| Network Policy | Yes — including L7 (HTTP path, method)         |
| Encryption     | Yes (WireGuard or IPsec)                       |
| Observability  | Built-in Hubble UI for live traffic visibility |
| Config         | Separate Helm install; disable Flannel first   |

**When to choose:** you need Network Policy, L7 traffic control, or want visibility into pod-to-pod traffic. Used in this repo's full kubeadm cluster (`kubernetes/essential/cilium/`).

```bash
# Install k3s without Flannel, then install Cilium
curl -sfL https://get.k3s.io | sh -s - \
  --flannel-backend=none \
  --disable-network-policy

helm repo add cilium https://helm.cilium.io
helm install cilium cilium/cilium \
  -f kubernetes/essential/cilium/values.yaml \
  -n cni-plugin --create-namespace
```

---

### Calico

Policy-rich CNI used widely in enterprise Kubernetes. Supports BGP routing (no overlay needed if nodes are on the same L2 network) and fine-grained Network Policy.

|                |                                                                 |
| -------------- | --------------------------------------------------------------- |
| Overhead       | Medium (~150 MB RAM per node)                                   |
| Network Policy | Yes — Kubernetes standard + Calico-specific GlobalNetworkPolicy |
| Encryption     | Yes (WireGuard)                                                 |
| BGP routing    | Yes — eliminates VXLAN overhead on bare metal                   |
| Config         | Separate install; disable Flannel first                         |

**When to choose:** you are on bare metal, nodes are on the same L2 segment, and you want to eliminate overlay overhead with BGP. Also the top choice when fine-grained egress policy per namespace is required.

---

## Comparison

|                  | Flannel                    | Cilium                 | Calico                             |
| ---------------- | -------------------------- | ---------------------- | ---------------------------------- |
| Bundled with k3s | Yes                        | No                     | No                                 |
| RAM per node     | ~10 MB                     | ~100 MB                | ~150 MB                            |
| Network Policy   | No                         | Yes (L3–L7)            | Yes (L3–L4)                        |
| Encryption       | WireGuard backend          | WireGuard / IPsec      | WireGuard                          |
| Overlay          | VXLAN                      | VXLAN / eBPF           | VXLAN / BGP                        |
| Best for         | Small clusters, simplicity | Policy + observability | Bare metal, BGP, enterprise policy |

---

## Top choice in production

| Cluster type                    | Recommended CNI   |
| ------------------------------- | ----------------- |
| Small / single node             | Flannel (default) |
| Multi-node, need Network Policy | Cilium            |
| Bare metal, BGP routing         | Calico            |

> For this k3s setup on small hosts, **Flannel is the correct choice**. The RAM saved over Cilium or Calico is meaningful on a 2 GB node, and most small production clusters do not need Network Policy enforcement at the CNI layer.
