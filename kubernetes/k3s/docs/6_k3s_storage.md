# k3s Storage

Storage in Kubernetes is how pods persist data beyond their own lifetime. A pod's filesystem is ephemeral — when the pod restarts, everything written to it is gone. Persistent storage decouples data from the pod so it survives restarts, rescheduling, and node failures.

**The three objects that wire storage to a pod:**

```
StorageClass          PersistentVolume (PV)        PersistentVolumeClaim (PVC)
─────────────         ─────────────────────        ───────────────────────────
defines HOW           the actual storage            pod's request for storage
storage is            provisioned and               (size, access mode,
provisioned           available to the cluster      storage class)
     │                        │                              │
     └────────────────────────┼──────────────────────────────┘
                              │
                              ▼
                         Pod (mounts the PVC as a directory)
```

> **Dynamic provisioning** — when a PVC is created, the StorageClass automatically provisions a matching PV and binds them together. No manual PV creation needed. Both local-path and Longhorn support dynamic provisioning.

---

## How a pod gets persistent storage

```
1. Developer creates a PVC:
   storageClassName: longhorn
   storage: 5Gi

2. Longhorn (StorageClass controller) sees the PVC
   → provisions a 5 Gi block volume on a node
   → creates a PV bound to the PVC

3. Pod spec references the PVC:
   volumes:
     - name: data
       persistentVolumeClaim:
         claimName: my-pvc

4. kubelet mounts the volume into the container at the specified mountPath
```

---

## Options

### local-path _(default in k3s)_

Built into k3s. Provisions volumes as directories on the node's local filesystem — no replication, no snapshots, data lives on one node only.

|                      |                                                              |
| -------------------- | ------------------------------------------------------------ |
| Namespace            | `kube-system`                                               |
| StorageClass name    | `local-path`                                                |
| Data location        | `/var/lib/rancher/k3s/storage/<pvc-name>/` on the node      |
| Replication          | None — data lives on one node                               |
| Snapshots            | None                                                        |
| Access mode          | `ReadWriteOnce` only                                        |
| Survives node loss   | No — data is lost if the node is destroyed                  |

**Use this for:** dev clusters, stateless workloads that use external databases, or any workload where losing data is acceptable.

> **What happens to local-path data when a pod reschedules to a different node?**
> The new pod starts on the new node but cannot reach the volume — it lives on the old node. Kubernetes will keep trying to schedule the pod back onto the original node. If that node is permanently gone, the pod stays `Pending` and the data is lost.
> This is the core limitation that Longhorn solves.

---

### Longhorn _(production)_

Distributed block storage. Each volume is replicated across multiple nodes. If a node fails, the volume is still available from another replica.

|                      |                                                              |
| -------------------- | ------------------------------------------------------------ |
| Namespace            | `storage-controller`                                        |
| StorageClass name    | `longhorn`                                                  |
| Data location        | `/var/lib/docker/longhorn/` on each node (configurable)     |
| Replication          | Configurable — default 1 replica in this repo               |
| Snapshots            | Yes — manual and scheduled                                  |
| Backup               | Yes — to S3 or NFS                                          |
| Access mode          | `ReadWriteOnce`, `ReadWriteMany` (via share manager)        |
| Survives node loss   | Yes — if replica count > 1 and replicas are on different nodes |
| UI                   | Web UI at `longhorn.example.com` (ingress configured)       |

**Use this for:** any stateful workload in production — databases, message queues, object stores.

**Install:**

```bash
bash kubernetes/k3s/helm/longhorn/install.sh
```

**Switch Longhorn to cluster default** (run after verifying Longhorn is healthy):

```bash
bash kubernetes/k3s/helm/set-default-storageclass.sh
```

> This repo sets `defaultClass: false` in Longhorn's helm values on purpose — local-path remains the default until you explicitly run `set-default-storageclass.sh`. This prevents Longhorn from silently claiming PVCs before you have confirmed it is working.

---

### Rook-Ceph _(optional, high storage demand)_

Full software-defined storage cluster. Rook is the Kubernetes operator; Ceph is the distributed storage system underneath. Provides block, filesystem, and object storage from a pool of raw disks.

|                      |                                                              |
| -------------------- | ------------------------------------------------------------ |
| Location in repo     | `kubernetes/temp/rook-ceph/`                                |
| Overhead             | High — Ceph requires dedicated nodes and significant RAM     |
| Replication          | 3-way by default                                            |
| Access modes         | Block (`RWO`), filesystem (`RWX`), object (S3-compatible)   |
| Min nodes            | 3 nodes with dedicated raw disks                            |
| Maturity             | Production-grade but operationally complex                  |

**When to choose:** you have 3+ nodes with dedicated raw disks and need `ReadWriteMany` volumes or S3-compatible object storage without an external service.

> Rook-Ceph is under `kubernetes/temp/` — treat it as optional. For most k3s setups, Longhorn covers all requirements at a fraction of the operational cost.

---

## Comparison

|                    | local-path         | Longhorn                  | Rook-Ceph                    |
| ------------------ | ------------------ | ------------------------- | ---------------------------- |
| Built into k3s     | Yes                | No (Helm install)         | No (Helm install)            |
| Replication        | None               | Yes (configurable)        | Yes (3-way default)          |
| Survives node loss | No                 | Yes (replicas > 1)        | Yes                          |
| Snapshots          | No                 | Yes                       | Yes                          |
| S3 object storage  | No                 | No                        | Yes                          |
| ReadWriteMany      | No                 | Via share manager         | Yes (CephFS)                 |
| RAM per node       | Negligible         | ~300 MB                   | ~1–2 GB                      |
| Operational cost   | None               | Low                       | High                         |
| Best for           | Dev / ephemeral    | Production stateful apps  | Large-scale or multi-protocol |

---

## Replica count

The `defaultReplicaCount` in `helm-charts/longhorn/helm-values.yaml` is set to `1`. This means volumes have no redundancy by default — same as local-path in terms of node failure tolerance, but with the operational benefits of Longhorn (snapshots, backup, UI).

Change this based on your cluster size:

| Node count with storage | Recommended replicas | Tolerates |
|------------------------|---------------------|-----------|
| 1 | 1 | Cannot tolerate any node loss |
| 2 | 2 | 1 node loss |
| 3+ | 3 | 1 node loss (Longhorn default recommendation) |

```bash
# Check current default replica count
kubectl get setting -n storage-controller default-replica-count -o jsonpath='{.value}'

# Change for new volumes (does not affect existing volumes)
kubectl patch setting default-replica-count \
  -n storage-controller \
  --type=merge \
  -p '{"value":"3"}'
```

> **Replica count must not exceed the number of nodes that have storage disks.** If you set replicas to 3 but only have 2 storage nodes, Longhorn cannot place all replicas and the volume stays degraded.

---

## Access modes

| Mode | Meaning | Supported by |
|------|---------|-------------|
| `ReadWriteOnce` (RWO) | One node can mount read-write | local-path, Longhorn, Rook-Ceph |
| `ReadOnlyMany` (ROX) | Multiple nodes can mount read-only | Longhorn, Rook-Ceph |
| `ReadWriteMany` (RWX) | Multiple nodes can mount read-write | Longhorn (share manager), Rook-Ceph CephFS |

> Most stateful applications (PostgreSQL, Kafka, Elasticsearch) use `ReadWriteOnce` — only one pod writes to the volume at a time. `ReadWriteMany` is needed when multiple pods on different nodes must write to the same volume simultaneously (e.g. a shared config directory or NFS-style workload).

---

## Useful commands

```bash
# List all PVCs and their storage class
kubectl get pvc -A -o wide

# List all PVs
kubectl get pv

# List storage classes
kubectl get storageclass

# Check Longhorn volume health
kubectl get volumes.longhorn.io -n storage-controller

# Check Longhorn pods
kubectl get pods -n storage-controller

# Take a manual Longhorn snapshot of a volume
kubectl annotate volume <volume-name> -n storage-controller \
  longhorn.io/volume-recurring-jobs-override='[{"name":"snap","task":"snapshot","retain":2,"cron":"0 * * * *"}]'

# Describe a stuck PVC (useful when pod is Pending)
kubectl describe pvc <pvc-name> -n <namespace>

# Check which node a PV is bound to (local-path)
kubectl get pv <pv-name> -o jsonpath='{.spec.nodeAffinity}'
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Pod stuck `Pending` — `no storage class found` | No default StorageClass set | Run `set-default-storageclass.sh` or specify `storageClassName` in the PVC |
| Pod stuck `Pending` — `waiting for volume to be created` | Longhorn cannot place replicas | Check replica count vs available storage nodes: `kubectl get nodes -n storage-controller` |
| PVC stuck `Pending` after Longhorn install | Longhorn pods not fully ready | `kubectl get pods -n storage-controller` — wait for all Running |
| Volume degraded after node drain | Replica on drained node is unavailable | Longhorn will rebuild replica on another node automatically — check progress in UI |
| local-path PVC data missing after pod reschedule | Pod rescheduled to different node | local-path data is node-local — migrate to Longhorn, see `docs/migrate-to-longhorn.md` |
| Longhorn UI returns 401 | Basic-auth secret not created | Re-run `helm/longhorn/install.sh` — it creates the secret interactively |
| `storageclass.kubernetes.io/is-default-class` on both classes | Both local-path and longhorn marked default | Run `set-default-storageclass.sh` to fix, or patch manually |
