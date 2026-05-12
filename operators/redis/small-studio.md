# Redis — Small Studio Setup

Two-phase path: start lean on a single node, scale to 3-node replication with sentinel
running on the same nodes. No dedicated sentinel nodes needed.

---

## Phase 1 — Single Node

Apply the standalone CR:

```bash
./install.sh
# or manually:
kubectl apply -f redis.yml -n redis
```

Verify:

```bash
kubectl get redis -n redis
kubectl exec -it redis-0 -n redis -- redis-cli ping
# → PONG
```

Connect from inside the cluster:

```
redis://redis.redis.svc.cluster.local:6379
```

---

## Phase 2 — 3 Nodes (Replication + Sentinel Co-located)

Each of the 3 Kubernetes nodes runs one Redis data pod and one Sentinel pod.
The `podAntiAffinity` rules in both CRs enforce this — the operator will refuse to
schedule two replication pods or two sentinel pods on the same node.

```
Node A:  redis-replication-0 (master)   redis-sentinel-0
Node B:  redis-replication-1 (replica)  redis-sentinel-1
Node C:  redis-replication-2 (replica)  redis-sentinel-2
```

Sentinel quorum is 2 — any two of the three sentinels agreeing is enough to trigger
failover. If Node A dies, Nodes B and C elect a new master without needing Node A.

### Migration from Phase 1

The migration uses Redis's built-in replication as the data transport. The new master
streams every write from the old standalone in real time, so the maintenance window is
only as long as it takes to flip a connection string — not the duration of the copy.

```
redis-0 (standalone, still serving writes)
    │
    │  REPLICAOF — live continuous sync
    ▼
redis-replication-0 (new master, catching up in background)
```

**1. Deploy the Phase 2 cluster** (starts empty, standalone still serves traffic):

```bash
REDIS_MODE=replication ./install.sh
# or manually:
kubectl apply -f redis-replication.yml -n redis
kubectl apply -f redis-sentinel.yml -n redis
```

Watch rollout:

```bash
kubectl get pods -n redis -o wide  # verify 1 pod per node
```

**2. Point the new master at the old standalone:**

```bash
kubectl exec -it redis-replication-0 -n redis -- \
  redis-cli REPLICAOF redis.redis.svc.cluster.local 6379
```

**3. Wait for the initial full sync to complete:**

```bash
# Repeat until master_sync_in_progress:0 and offset stops growing
kubectl exec -it redis-replication-0 -n redis -- \
  redis-cli info replication | grep -E "master_sync_in_progress|master_repl_offset"
```

After the initial bulk sync, the replica streams new writes continuously — it stays
current automatically. There is no rush to cut over at this point.

**4. Maintenance window — run the cutover script** (1–3 seconds):

```bash
./migrate-cutover.sh
```

The script uses `CLIENT PAUSE WRITE` + `WAIT` to atomically drain the replication
backlog before promoting — no app-level maintenance mode needed. It prints the
elapsed pause time and verifies key counts on both sides before exiting.

After the script completes, update your app's connection string to Sentinel
(see Client connection section below), then delete the standalone CR.

**5. Delete the standalone CR:**

```bash
kubectl delete redis redis -n redis
```

The other replication pods (redis-replication-1, redis-replication-2) sync automatically
from the new master once it is promoted.

### Client connection after Phase 2

Update your app's Redis connection to use Sentinel mode:

```
# Before (Phase 1 — direct)
redis://redis.redis.svc.cluster.local:6379

# After (Phase 2 — sentinel)
sentinel://redis-sentinel.redis.svc.cluster.local:26379/mymaster
```

Most Redis clients support Sentinel natively. Examples:

```python
# redis-py
from redis.sentinel import Sentinel
sentinel = Sentinel([("redis-sentinel.redis.svc.cluster.local", 26379)], socket_timeout=0.5)
master = sentinel.master_for("mymaster", socket_timeout=0.5)
```

```javascript
// ioredis
const redis = new Redis({
  sentinels: [{ host: "redis-sentinel.redis.svc.cluster.local", port: 26379 }],
  name: "mymaster",
});
```

The Sentinel service name is `redis-sentinel` (matches the CR `metadata.name`).

---

## Verifying HA After Phase 2

Confirm each node has exactly one replication pod and one sentinel pod:

```bash
kubectl get pods -n redis -o wide
```

Test failover manually:

```bash
# Kill the master pod
kubectl delete pod redis-replication-0 -n redis

# Watch sentinel elect a new master (takes ~5s based on downAfterMilliseconds: 5000)
kubectl exec -it redis-sentinel-0 -n redis -- \
  redis-cli -p 26379 sentinel get-master-addr-by-name mymaster
```

Check replication status:

```bash
# On any pod
kubectl exec -it redis-replication-0 -n redis -- redis-cli info replication
```

---

## Scaling Read Replicas (Phase 2 — within replication)

If reads are the bottleneck, add replicas to the existing replication set.
Write throughput is unaffected — all writes still go to the single master.

```yaml
# redis-replication.yml
spec:
  clusterSize: 5 # 1 master + 4 replicas
```

```bash
kubectl apply -f redis-replication.yml -n redis
```

Sentinel count stays at 3 regardless of replica count.

---

## Phase 3 — Redis Cluster (write throughput bottleneck)

Switch to Redis Cluster when the **master's CPU or network is saturated by writes**.
Replication scales reads but not writes — every write still hits one master.

### Signals that indicate write throughput is the bottleneck

```bash
# CPU on master pod consistently above 80%
kubectl top pod -n redis

# High instantaneous write ops on master, replicas nearly idle
kubectl exec -it redis-replication-0 -n redis -- \
  redis-cli info stats | grep instantaneous_ops_per_sec

# Write latency climbing, read latency flat
kubectl exec -it redis-replication-0 -n redis -- \
  redis-cli --latency-history -i 5
```

If write ops are high and master CPU is the ceiling — not memory, not network — Redis
Cluster is the right move. If it is memory or network, scale the node first.

### What Redis Cluster does differently

Replication copies every key to every node. Cluster **shards** data: 16384 hash slots
are divided across masters, each master owns its slice.

```
Phase 2 (replication):          Phase 3 (cluster):

  master ──── replica-1          master-0  (slots 0–5460)
         └─── replica-2          master-1  (slots 5461–10922)
                                 master-2  (slots 10923–16383)
  all writes → 1 master          writes distributed across 3 masters
```

With 3 masters, each master handles ~⅓ of writes. Adding a 4th master rebalances
slots automatically — no downtime.

### Constraints introduced by Cluster mode

These do not apply in Phase 2 but matter before migrating:

- **Multi-key commands** (`MSET`, `MGET`, `DEL key1 key2`) only work if all keys hash
  to the same slot. Use hash tags `{user}:profile` and `{user}:session` to force keys
  into the same slot.
- **Transactions** (`MULTI`/`EXEC`) are limited to keys on the same slot.
- **Lua scripts** must only touch keys that hash to the same slot.
- Clients must use cluster-aware mode (see connection changes below).

Audit your key access patterns before migrating — if you have cross-key transactions
on arbitrary keys, those need to be redesigned first.

### Deploy the cluster

`redis-cluster.yml` is already in this directory. Apply it alongside (or instead of)
the replication set — the operator manages them independently:

```bash
kubectl apply -f redis-cluster.yml -n redis
kubectl get rediscluster -n redis -w
```

The operator creates `redis-cluster-leader-{0,1,2}` and `redis-cluster-follower-{0,1,2}`
StatefulSets. Pod anti-affinity spreads leaders and followers across the 3 nodes.

### Migration from Phase 2 (replication) to Phase 3 (cluster)

There is no live replication path between a standalone master and a Redis Cluster —
`REPLICAOF` does not work in cluster mode. Migration uses `redis-cli --cluster import`.

**1. Deploy the cluster** (empty, replication still serves traffic):

```bash
kubectl apply -f redis-cluster.yml -n redis
kubectl get pods -n redis -o wide  # wait until all 6 cluster pods are Running
```

**2. Import data from the current master into the cluster:**

```bash
# Run from a pod that can reach both the old master and the new cluster
kubectl run redis-migrate --rm -it --image=redis:7 --restart=Never -n redis -- \
  redis-cli --cluster import redis-cluster-leader-0.redis-cluster-leader-headless.redis.svc.cluster.local:6379 \
  --cluster-from redis-replication-0.redis-replication-headless.redis.svc.cluster.local:6379 \
  --cluster-copy   # keep keys on old master; remove this flag to move (delete after copy)
```

`--cluster import` copies keys slot by slot. It is non-atomic — writes arriving on the
old master during import may not be captured. Run during a low-write window or
after putting the app in write-pause (same `CLIENT PAUSE WRITE` technique as the
Phase 1→2 cutover).

**3. Verify key counts:**

```bash
# Old master
kubectl exec -it redis-replication-0 -n redis -- redis-cli DBSIZE

# New cluster (sum across all masters)
for pod in redis-cluster-leader-0 redis-cluster-leader-1 redis-cluster-leader-2; do
  echo -n "$pod: "
  kubectl exec -n redis $pod -- redis-cli DBSIZE
done
```

**4. Update the app connection string** (see below), then delete the replication set:

```bash
kubectl delete redisreplication redis-replication -n redis
kubectl delete redissentinel redis-sentinel -n redis
```

### Client connection in Cluster mode

```python
# redis-py — cluster mode
from redis.cluster import RedisCluster
rc = RedisCluster(
    startup_nodes=[
        {"host": "redis-cluster-leader-0.redis-cluster-leader-headless.redis.svc.cluster.local", "port": 6379},
        {"host": "redis-cluster-leader-1.redis-cluster-leader-headless.redis.svc.cluster.local", "port": 6379},
        {"host": "redis-cluster-leader-2.redis-cluster-leader-headless.redis.svc.cluster.local", "port": 6379},
    ],
    decode_responses=True,
)
```

```javascript
// ioredis — cluster mode
const cluster = new Redis.Cluster([
  {
    host: "redis-cluster-leader-0.redis-cluster-leader-headless.redis.svc.cluster.local",
    port: 6379,
  },
  {
    host: "redis-cluster-leader-1.redis-cluster-leader-headless.redis.svc.cluster.local",
    port: 6379,
  },
  {
    host: "redis-cluster-leader-2.redis-cluster-leader-headless.redis.svc.cluster.local",
    port: 6379,
  },
]);
```

Only one seed node is needed at runtime — the client discovers the full topology via
`CLUSTER SLOTS`. The list above gives three seeds so startup survives a single node
being down.

### Adding a 4th master shard (horizontal write scale)

```yaml
# redis-cluster.yml
spec:
  clusterSize: 4 # operator rebalances slots automatically
```

```bash
kubectl apply -f redis-cluster.yml -n redis
```

Slot rebalancing is live — reads and writes continue during the migration. The operator
moves slots one by one and updates the cluster routing table.
