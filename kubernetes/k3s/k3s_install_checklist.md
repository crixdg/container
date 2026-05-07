# k3s Installation Checklist

Step-by-step checklist for setting up a k3s single-node cluster, with an optional path to scale into a HA multi-server cluster. Work through Phase 1 first; complete Phase 2 only when you need high availability.

---

## Phase 1 — Single-Node Cluster

### 1.1 Prerequisites

- [ ] Target node is running a systemd-based Linux distro (RHEL, Ubuntu, Debian, …)
- [ ] You have root or passwordless-sudo access on the node
- [ ] Minimum specs met: 1 vCPU, 512 MB RAM (2 vCPU / 2 GB recommended)
- [ ] Required ports are open on the node firewall:

  | Port        | Protocol | Purpose                     |
  | ----------- | -------- | --------------------------- |
  | 6443        | TCP      | Kubernetes API server       |
  | 10250       | TCP      | kubelet metrics             |
  | 8472        | UDP      | Flannel VXLAN (default CNI) |
  | 51820/51821 | UDP      | WireGuard (if enabled)      |
  | 2379/2380   | TCP      | etcd peer/client (HA only)  |

- [ ] `curl` available on the node (used by the k3s install script)
- [ ] Decide on k3s version — pin it (e.g. `v1.35.4+k3s1`) to avoid surprises on reinstall

### 1.2 Configuration

- [ ] Copy the config template:
  ```bash
  cp kubernetes/k3s/.env.server.example kubernetes/k3s/.env
  ```
- [ ] Edit `.env` and set at minimum:

  | Variable          | Value to set                              |
  | ----------------- | ----------------------------------------- |
  | `NODE_IP`         | IP of this node (used by install-server.sh) |
  | `FIRST_SERVER_IP` | Same as `NODE_IP` for single-node; HA join endpoint for multi-node |
  | `K3S_VERSION`     | Pinned release, e.g. `v1.35.4+k3s1`       |
  | `CLUSTER_CIDR`    | Pod network CIDR (default `10.42.0.0/16`) |
  | `SERVICE_CIDR`    | Service CIDR (default `10.43.0.0/16`)     |
  | `EXTRA_SANS`      | Extra IPs/hostnames for the API TLS cert  |

- [ ] _(Optional)_ If using a private registry, place `registries.yaml` on the node **before** installing:
  ```bash
  cp kubernetes/k3s/registries.yaml /etc/rancher/k3s/registries.yaml
  # edit credentials/mirrors in the file
  ```

### 1.3 Install k3s Server

- [ ] Run the server install script:
  ```bash
  sudo bash kubernetes/k3s/install-server.sh
  ```
- [ ] Confirm k3s service is running:
  ```bash
  systemctl status k3s
  ```
- [ ] Note the node token (printed by the script, or read it manually):
  ```bash
  sudo cat /var/lib/rancher/k3s/server/node-token
  ```

### 1.4 Configure kubectl

On the server node:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

From a remote workstation:

```bash
scp root@<server-ip>:/etc/rancher/k3s/k3s.yaml ~/.kube/k3s.yaml
sed -i 's/127.0.0.1/<server-ip>/g' ~/.kube/k3s.yaml
export KUBECONFIG=~/.kube/k3s.yaml
```

- [ ] `kubectl get nodes` shows the node in `Ready` state
- [ ] `kubectl get pods -A` shows all system pods running

### 1.5 Install Essential Cluster Components

- [ ] Run the essentials installer:

  ```bash
  bash kubernetes/k3s/helm/install-essentials.sh
  ```

  Installs in dependency order:
  1. **cert-manager** — TLS certificate management
  2. **ingress-nginx** — Ingress controller (replaces k3s default Traefik)
  3. **Longhorn** — Distributed block storage (needed for HA later)

- [ ] Verify all components are healthy:
  ```bash
  kubectl get pods -n cert-manager
  kubectl get pods -n ingress-nginx
  kubectl get pods -n longhorn-system
  ```

### 1.6 Smoke Test

- [ ] Deploy a test workload and expose it via Ingress
- [ ] Confirm Longhorn can provision a PVC:
  ```bash
  kubectl apply -f - <<EOF
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: test-pvc
  spec:
    storageClassName: longhorn
    accessModes: [ReadWriteOnce]
    resources:
      requests:
        storage: 1Gi
  EOF
  kubectl get pvc test-pvc   # should reach Bound state
  kubectl delete pvc test-pvc
  ```
- [ ] TLS certificate issuance works (if using cert-manager ClusterIssuer)

**Phase 1 complete. The single-node cluster is production-ready for non-critical workloads.**

---

## Phase 2 — Scale to HA Cluster (Optional)

> **When to proceed:** you need control-plane redundancy, zero-downtime API upgrades, or you are promoting the cluster to a critical environment.
>
> HA requires **3 server nodes** (odd number for etcd quorum). You also need an external or virtual IP in front of the API servers (load balancer or keepalived VIP) so worker nodes and `kubectl` always reach a healthy server.

### 2.1 Assess Current State

- [ ] Check what datastore the single-node cluster is using:

  ```bash
  # If you see --cluster-init or --datastore-endpoint in the process, note it
  ps aux | grep k3s
  cat /etc/systemd/system/k3s.service
  ```

  - **Embedded SQLite** (default single-node) → must migrate to embedded etcd (see §2.3)
  - **Embedded etcd** (bootstrapped with `--cluster-init`) → can add server nodes directly (skip §2.3)

- [ ] Decide on API server load balancing:
  - **keepalived VIP** — virtual IP floats between server nodes (no extra hardware)
  - **External LB** (HAProxy, AWS NLB, etc.) — recommended for production
  - **DNS round-robin** — simple but no health checking

- [ ] Prepare 2 additional server nodes (same OS, same firewall rules as §1.1)
- [ ] Choose the VIP or LB address; note it as `CLUSTER_VIP` — this will be added to `EXTRA_SANS`

### 2.2 Backup Before Migration

- [ ] Stop workloads that write to the datastore (or schedule a maintenance window)
- [ ] Snapshot etcd / SQLite:

  ```bash
  # For embedded etcd (if already running etcd):
  k3s etcd-snapshot save --name pre-ha-migration

  # For SQLite:
  cp /var/lib/rancher/k3s/server/db/state.db ~/state.db.bak
  ```

- [ ] Back up kubeconfig and node-token:
  ```bash
  cp /etc/rancher/k3s/k3s.yaml ~/k3s.yaml.bak
  cp /var/lib/rancher/k3s/server/node-token ~/node-token.bak
  ```

### 2.3 Migrate SQLite → Embedded etcd (skip if already on etcd)

> This is an in-place migration. The cluster will be **briefly unavailable** while k3s restarts.

- [ ] On the existing server node, stop k3s:
  ```bash
  systemctl stop k3s
  ```
- [ ] Edit the k3s service to add `--cluster-init`:
  ```bash
  # /etc/systemd/system/k3s.service.env  or  /etc/rancher/k3s/config.yaml
  # Add the flag:  cluster-init: true
  ```
  Or reinstall with the flag:
  ```bash
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=<version> \
    sh -s - server \
      --cluster-init \
      --tls-san <CLUSTER_VIP> \
      --tls-san <server-ip>
  ```
- [ ] Start k3s and confirm it comes up as an etcd cluster:
  ```bash
  systemctl daemon-reload && systemctl start k3s
  k3s etcd-snapshot ls    # should succeed — proves etcd is active
  kubectl get nodes       # node should return to Ready
  ```

### 2.4 Set Up API Server Load Balancer / VIP

- [ ] Configure keepalived, HAProxy, or your cloud LB to forward port 6443 to all server nodes
- [ ] Verify the VIP/LB address resolves and port 6443 is reachable from worker nodes and your workstation
- [ ] Update kubeconfig on workstations to point at the VIP:
  ```bash
  sed -i 's/<old-server-ip>/<CLUSTER_VIP>/g' ~/.kube/k3s.yaml
  kubectl get nodes   # confirm still works through VIP
  ```

### 2.5 Join Additional Server Nodes

Repeat for each additional server node (you need at least 2 more for a 3-node control plane):

- [ ] Copy `registries.yaml` to the new node (if using a private registry)
- [ ] Join the new server:
  ```bash
  # On the new server node
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=<version> \
    K3S_TOKEN=<token-from-§1.3> \
    sh -s - server \
      --server https://<FIRST_SERVER_IP>:6443 \
      --tls-san <CLUSTER_VIP> \
      --tls-san <this-node-ip>
  ```
- [ ] From your workstation, confirm the new node joins:
  ```bash
  kubectl get nodes   # new node should appear and reach Ready
  ```
- [ ] Check etcd member count:

  ```bash
  k3s etcd-snapshot ls    # run on any server node
  # Or:
  ETCDCTL_API=3 etcdctl member list \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
    --cert=/var/lib/rancher/k3s/server/tls/etcd/server-client.crt \
    --key=/var/lib/rancher/k3s/server/tls/etcd/server-client.key
  ```

- [ ] After all server nodes are joined, confirm 3 members in etcd quorum

### 2.6 Join Agent (Worker) Nodes

For each worker node:

- [ ] Open agent firewall ports (8472 UDP Flannel, 10250 TCP kubelet)
- [ ] Copy `registries.yaml` if needed
- [ ] Join the node:
  ```bash
  K3S_URL=https://<CLUSTER_VIP>:6443 \
  K3S_TOKEN=<token> \
  sudo bash kubernetes/k3s/install-agent.sh
  ```
- [ ] Confirm node reaches `Ready`:
  ```bash
  kubectl get nodes
  ```

### 2.7 Post-HA Validation

- [ ] Kill one server node and confirm `kubectl get nodes` still works through the VIP
- [ ] Restart the killed server and confirm it rejoins the cluster
- [ ] Run the Longhorn UI health check (all replicas should show healthy)
- [ ] Verify etcd snapshotting is scheduled (k3s auto-snapshots every 12h by default):
  ```bash
  k3s etcd-snapshot ls
  ```
- [ ] Update `ansible/inventory/hosts.ini` to reflect the new topology so future Ansible runs are accurate

### 2.8 Optional Storage Migration (local-path → Longhorn)

If you added Longhorn in §1.5 and workloads still use `local-path`, migrate PVCs to Longhorn storage now so data is replicated across nodes.

- [ ] See `docs/6.1_k3s_local_path_to_longhorn.md` for the standard migration
- [ ] See `docs/6.2_k3s_local_path_to_longhorn_no_downtime.md` for zero-downtime approach
- [ ] After migration, verify PVCs are bound to Longhorn:
  ```bash
  kubectl get pvc -A
  ```

### 2.9 Optional CNI Migration (Flannel → Cilium)

k3s ships with Flannel by default. If you need network policies, encryption, or better observability, migrate to Cilium.

- [ ] See `docs/3.1_k3s_flannel_to_cillium.md` for the general migration guide
- [ ] See `docs/3.2_k3s_flannel_to_cilium_maintenance.md` for maintenance-window approach
- [ ] See `docs/3.3_k3s_flannel_to_cilium_blue_green.md` for zero-downtime blue/green approach

**Phase 2 complete. The cluster now runs with a 3-node HA control plane.**

---

## Quick Reference — Key Files

| File                         | Purpose                                         |
| ---------------------------- | ----------------------------------------------- |
| `.env.server.example`        | Server config template                          |
| `.env.agent.example`         | Agent config template                           |
| `registries.yaml`            | Private registry mirrors — deploy before k3s    |
| `install-server.sh`          | Bootstrap a k3s server node                     |
| `install-agent.sh`           | Join a k3s agent (worker) node                  |
| `uninstall.sh`               | Remove k3s from a node                          |
| `helm/install-essentials.sh` | Install cert-manager + ingress-nginx + Longhorn |
| `ansible/playbook/site.yml`  | Full Ansible provisioning (all nodes at once)   |
| `ansible/playbook/clean.yml` | Tear down the cluster via Ansible               |

## Rollback / Disaster Recovery

| Scenario                 | Action                                                                                                                         |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------ |
| Bad k3s upgrade          | `INSTALL_K3S_VERSION=<prev-version> curl -sfL https://get.k3s.io \| sh`                                                        |
| Corrupted etcd           | `k3s server --cluster-reset --cluster-reset-restore-path=<snapshot>` on one node; then restart all other server nodes normally |
| Full cluster loss        | Restore snapshot to one node with `--cluster-reset`, then rejoin remaining servers/agents                                      |
| Accidental node deletion | Remove node from etcd with `kubectl delete node <name>`, then re-run `install-agent.sh` or `install-server.sh`                 |
