# k3s Components

## Node Roles

A Kubernetes cluster is made up of **server** (control-plane) and **agent** (worker) nodes.
In k3s, a server node runs both control-plane and workloads by default.

### Required to function

| Role                   | Minimum count                                   | Responsibility                                         |
| ---------------------- | ----------------------------------------------- | ------------------------------------------------------ |
| Server (control-plane) | 1                                               | API server, scheduler, controller-manager, state store |
| Worker (agent)         | 0 — server handles workloads if no agents exist | Run application pods                                   |

A single server node with no agents is a valid, working cluster.

**Inside the control-plane** — all bundled into the single `k3s server` process: — all bundled into the single `k3s server` process:

| Component          | Role                                                                                                    |
| ------------------ | ------------------------------------------------------------------------------------------------------- |
| API server         | The only entry point for all cluster operations — kubectl, controllers, and nodes all talk to it        |
| Scheduler          | Watches for unscheduled pods and decides which node to place them on based on resources and constraints |
| Controller manager | Runs control loops that reconcile desired state vs actual state (node health, replication, endpoints)   |
| State store        | SQLite on a single node; embedded etcd on 3+ servers — stores every object in the cluster               |
| kubelet            | Runs on every server node to manage its own containers (k3s servers also run workloads by default)      |
| kube-proxy         | Maintains network rules on each node so pods can reach services                                         |

**Inside a worker node** — runs on every agent:

| Component  | Role                                                                  |
| ---------- | --------------------------------------------------------------------- |
| kubelet    | Talks to the API server, starts/stops containers, reports node health |
| kube-proxy | Maintains iptables rules so pods can reach services by ClusterIP      |
| containerd | Container runtime — pulls images and runs containers                  |

> Both server and worker nodes run kube-proxy because every node can host pods, and every pod needs to reach services by ClusterIP regardless of which node it is on.
> kube-proxy watches the API server for Service changes and updates iptables rules locally on each node so that traffic to a ClusterIP gets forwarded to the correct pod — even if that pod lives on a different node.
> Without kube-proxy on a node, pods on that node cannot resolve or connect to any Service in the cluster.

### Required for production

| Role                   | Count | Why                                                                 |
| ---------------------- | ----- | ------------------------------------------------------------------- |
| Server (control-plane) | 3     | etcd quorum — cluster survives one server failure                   |
| Worker (agent)         | 1+    | Separate workloads from control-plane; prevents resource contention |
| Ingress node           | 1+    | Node labelled `ingress=true`; ingress-nginx binds ports 80/443 here |

> **etcd** is the key-value store that holds all cluster state (nodes, pods, secrets, config).
>
> - **Quorum** means the majority of server nodes must be reachable for the cluster to accept writes.
> - With 3 servers, quorum = 2 — the cluster stays operational if one server goes down.
> - With 2 servers, quorum = 2 — losing one server halts the entire cluster, so 2 is never recommended.

> **Ingress node** is a node designated to receive all external HTTP/HTTPS traffic.
> ingress-nginx binds directly to the host's port 80/443 (hostNetwork), so only nodes with the `ingress=true` label will accept incoming requests.
> Without a dedicated ingress node, external traffic has no fixed entry point into the cluster.

**Inside an ingress node** — a worker (or server) with the `ingress=true` label that also runs:

| Component         | Role                                                                                                             |
| ----------------- | ---------------------------------------------------------------------------------------------------------------- |
| kubelet           | Same as any worker — manages containers on this node                                                             |
| kube-proxy        | Same as any worker — local service routing rules                                                                 |
| containerd        | Same as any worker — runs the ingress-nginx pod                                                                  |
| ingress-nginx pod | Binds to host ports 80/443 via hostNetwork; terminates TLS; routes requests to backend services by Ingress rules |

> The ingress node is not a special node type — it is an ordinary worker that happens to run the ingress-nginx pod.
> The `ingress=true` label is only used by the ingress-nginx DaemonSet's `nodeSelector` to pin itself to this node.
> Remove the label and the pod will not schedule there; add it to another node and ingress-nginx will also run there.

### Optional

| Role                     | When to add                                                               |
| ------------------------ | ------------------------------------------------------------------------- |
| Dedicated storage node   | Node labelled for Longhorn storage only; isolates disk I/O from workloads |
| Additional ingress nodes | When a single ingress node becomes a bottleneck                           |
| GPU / specialised agent  | Node with taints for ML or compute workloads                              |

**Inside a dedicated storage node** — a worker pinned for Longhorn only:

| Component            | Role                                                                                 |
| -------------------- | ------------------------------------------------------------------------------------ |
| kubelet              | Same as any worker — manages containers on this node                                 |
| kube-proxy           | Same as any worker — local service routing rules                                     |
| containerd           | Same as any worker — runs Longhorn pods                                              |
| Longhorn manager pod | Runs on every node; coordinates volume scheduling and replication across the cluster |
| Longhorn engine pod  | Created per volume; handles actual read/write to the disk on this node               |
| Longhorn replica pod | Holds one replica of a volume; syncs data with replicas on other nodes               |

> A dedicated storage node is tainted so no application pods schedule on it — only Longhorn pods tolerate the taint.
> This prevents application workloads from competing with disk I/O, which is the main cause of storage performance issues on small clusters.
> To set up a dedicated storage node:
>
> ```bash
> kubectl taint node <name> node-role=storage:NoSchedule
> kubectl label node <name> node.longhorn.io/create-default-disk=true
> ```

> A single ingress node becomes a bottleneck when all external traffic passes through one host.
> Since ingress-nginx binds to the node's physical NIC, the ceiling is that node's network bandwidth and CPU.
>
> - A traffic spike saturates the NIC — other requests queue or drop.
> - TLS termination (decrypting HTTPS) is CPU-heavy; a busy ingress node starves co-located workloads.
> - If that node goes down, all external access is lost until the pod reschedules.
>   Adding a second ingress node and placing a DNS round-robin or L4 load balancer in front splits the load and removes the single point of failure.

---

## Built-in (ships with k3s)

| Component              | Role                           | Action                                            |
| ---------------------- | ------------------------------ | ------------------------------------------------- |
| containerd             | Container runtime              | Keep                                              |
| Flannel                | Pod networking (CNI)           | Keep                                              |
| CoreDNS                | Cluster DNS                    | Keep                                              |
| SQLite                 | State store (single-node only) | Keep — auto-replaced by etcd in HA                |
| local-path provisioner | Single-node storage            | Keep — disable when switching to Longhorn         |
| Traefik                | Ingress                        | **Disable** — replaced by ingress-nginx           |
| ServiceLB              | Load balancer                  | **Disable** — not needed with hostNetwork ingress |
| embedded etcd          | HA state store (3+ servers)    | Enable when scaling                               |
