# k3s State Store

The state store holds every object in the cluster — nodes, pods, secrets, configmaps, service endpoints, RBAC rules. Every read and write from the API server goes through it. If the state store is unavailable, the cluster stops accepting changes: new pods cannot be scheduled, secrets cannot be read, and controllers cannot reconcile.

**Where the state store sits in the k3s system:**

```
kubectl / controller / kubelet
    │
    ▼
API server
    │
    ▼
State store (SQLite or etcd)   ← single source of truth for all cluster state
```

> The state store does not run workloads or make scheduling decisions. It only stores data. Everything else in the control plane (scheduler, controller-manager) reads from it and writes back to it via the API server.

---

## Options

### SQLite _(default, single server only)_

Embedded in the k3s process. No separate installation, no configuration, no external dependency. The database file lives at `/var/lib/rancher/k3s/server/db/state.db`.

|                   |                                                        |
| ----------------- | ------------------------------------------------------ |
| Location          | `/var/lib/rancher/k3s/server/db/state.db`              |
| Process           | Embedded in `k3s server` — no separate daemon          |
| HA support        | No — only one server node can write at a time          |
| Backup            | Copy the file while k3s is stopped, or use SQLite dump |
| Max cluster size  | Suitable for single-node and small dev clusters        |

**Use this when:** you have one server node and do not need the cluster to survive a server failure.

> SQLite holds an exclusive write lock on the database file — only one process can write at a time. This is why k3s cannot use SQLite in a multi-server (HA) setup: two API servers writing simultaneously would corrupt the database.

---

### Embedded etcd _(HA, 3+ server nodes)_

etcd is a distributed key-value store built for Kubernetes. When you add a second server with `--cluster-init` already set, k3s automatically switches from SQLite to embedded etcd. No manual migration is needed.

|                   |                                                              |
| ----------------- | ------------------------------------------------------------ |
| Location          | `/var/lib/rancher/k3s/server/db/etcd/`                      |
| Process           | Embedded in `k3s server` — no separate etcd binary needed   |
| HA support        | Yes — quorum-based, survives minority node failures          |
| Backup            | `k3s etcd-snapshot save`                                     |
| Min server nodes  | 3 (quorum requires majority — 2 of 3 must be reachable)      |

**Use this when:** you need the cluster to survive a server node failure.

> **Why 3 servers and not 2?**
> etcd requires a quorum — a majority of members must agree before any write is committed.
>
> | Server count | Quorum needed | Can lose |
> |---|---|---|
> | 1 | 1 | 0 nodes |
> | 2 | 2 | 0 nodes — losing one halts writes |
> | 3 | 2 | 1 node |
> | 5 | 3 | 2 nodes |
>
> 2 servers is never recommended — it gives no fault tolerance and adds operational complexity. Go directly from 1 to 3.

---

### External database _(PostgreSQL or MySQL)_

k3s can use an external relational database instead of SQLite or etcd. The API server connects via a `--datastore-endpoint` connection string.

|                   |                                                              |
| ----------------- | ------------------------------------------------------------ |
| Supported DBs     | PostgreSQL, MySQL, MariaDB                                   |
| Config            | `--datastore-endpoint` flag or `K3S_DATASTORE_ENDPOINT` env |
| HA support        | Yes — multiple k3s server nodes share one external DB        |
| Backup            | Standard DB backup tools (pg_dump, mysqldump)                |
| Operational cost  | You manage the database availability separately              |

```bash
# Example: use an external PostgreSQL instance
curl -sfL https://get.k3s.io | sh -s - \
  --datastore-endpoint="postgres://user:password@192.168.1.10:5432/k3s"
```

**When to choose:** you already operate a highly available PostgreSQL or MySQL cluster and want to manage Kubernetes state alongside your existing database infrastructure. Less common than embedded etcd.

---

## Comparison

|                  | SQLite             | Embedded etcd        | External DB              |
| ---------------- | ------------------ | -------------------- | ------------------------ |
| Extra install    | None               | None                 | Separate DB required     |
| HA support       | No                 | Yes                  | Yes                      |
| Min server nodes | 1                  | 3                    | 1+                       |
| Backup method    | File copy          | `etcd-snapshot save` | pg_dump / mysqldump      |
| Operational cost | None               | Low                  | High                     |
| Best for         | Dev / single node  | Production HA        | Existing DB infrastructure |

---

## Top choice in production

| Setup | State store |
|-------|------------|
| Single node or dev cluster | SQLite (default) |
| Multi-node production cluster | Embedded etcd (3 servers) |
| Existing managed DB infrastructure | External PostgreSQL |

> For this k3s setup, **embedded etcd with 3 server nodes is the correct choice for production**. It requires no extra infrastructure beyond the servers you already need for control-plane redundancy.

---

## Initialising embedded etcd

On the **first server** only:

```bash
curl -sfL https://get.k3s.io | sh -s - \
  --cluster-init \
  --token <shared-secret>
```

On each **additional server** (2nd and 3rd):

```bash
curl -sfL https://get.k3s.io | sh -s - \
  --server https://<first-server-ip>:6443 \
  --token <shared-secret>
```

> `--cluster-init` tells k3s to start a new etcd cluster. Only use it on the first server — subsequent servers use `--server` to join the existing cluster. Running `--cluster-init` on a second server creates a second isolated cluster, not a joined one.

Verify all servers have joined and etcd is healthy:

```bash
# All server nodes should appear as Ready
kubectl get nodes

# Check etcd member list from any server node
k3s etcd-snapshot ls
ETCDCTL_API=3 etcdctl \
  --endpoints https://127.0.0.1:2379 \
  --cacert /var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
  --cert /var/lib/rancher/k3s/server/tls/etcd/client.crt \
  --key /var/lib/rancher/k3s/server/tls/etcd/client.key \
  member list
```

---

## Backups

### Embedded etcd snapshot

k3s has built-in snapshot support. Snapshots are taken to `/var/lib/rancher/k3s/server/db/snapshots/` by default.

```bash
# Manual snapshot
k3s etcd-snapshot save --name pre-upgrade

# List snapshots
k3s etcd-snapshot ls

# Scheduled snapshots (already enabled by default — runs every 12 hours, keeps 5)
# Configure via k3s flags:
#   --etcd-snapshot-schedule-cron  "0 */12 * * *"
#   --etcd-snapshot-retention      5
#   --etcd-snapshot-dir            /var/lib/rancher/k3s/server/db/snapshots
```

> Snapshots are saved locally on the server node that runs the command. Copy them off-node to survive a total server failure:
>
> ```bash
> scp <server>:/var/lib/rancher/k3s/server/db/snapshots/pre-upgrade.db /backup/
> ```

### SQLite backup

```bash
# Stop k3s first — SQLite holds a write lock while running
systemctl stop k3s
cp /var/lib/rancher/k3s/server/db/state.db /backup/state.db
systemctl start k3s
```

---

## Restore from snapshot

Restore replaces all current cluster state with the snapshot contents. **This is destructive — all changes since the snapshot was taken are lost.**

```bash
# Stop k3s on all server nodes first
systemctl stop k3s

# Run restore on one server node only
k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/pre-upgrade.db

# After restore completes, start k3s on the restored node
systemctl start k3s

# Then start k3s on remaining server nodes — they will resync from the restored leader
systemctl start k3s   # on each remaining server
```

> `--cluster-reset` resets the etcd cluster to a single member using the snapshot data. The other servers must be stopped before the reset and started after — they rejoin as followers and replicate the restored state.

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| API server refuses writes, returns `etcdserver: request timed out` | Quorum lost — check how many server nodes are reachable: `kubectl get nodes` |
| `k3s server` fails to start with `failed to find free address` | etcd port 2379/2380 already in use — check `ss -tlnp \| grep 2379` |
| Snapshot save fails | Disk full on server node — check `df -h /var/lib/rancher` |
| etcd member count is wrong after adding a server | New server joined with `--cluster-init` instead of `--server` — it created a separate cluster |
| SQLite `database is locked` error in logs | Another process has the state.db file open — check for stale k3s processes |
