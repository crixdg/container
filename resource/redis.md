# Redis — Production Resource Sizing

## Core principles (big-tech consensus)

| Principle                                 | Why                                                                                                                                                                                                        |
| ----------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **No CPU limit** (or very generous)       | Kubernetes CFS throttling adds p99 latency spikes even at low average utilization. Discord, Cloudflare, and GitHub all dropped CPU limits on Redis. Set a request but no limit, or set limit ≥ 4× request. |
| **Memory request = limit**                | Forces Kubernetes `Guaranteed` QoS class. Redis is an in-memory store — any burstable behavior causes OOM kills under node pressure.                                                                       |
| **maxmemory = 75–80% of container limit** | Leaves headroom for the Redis process, COW during BGSAVE/BGREWRITEAOF, and Lua scripts. Without this gap the kernel OOM killer fires before Redis can evict.                                               |
| **Huge pages: disabled on host**          | `transparent_hugepage=never` on nodes. THP causes memory bloat during fork; production clusters at Cloudflare measured 2× RSS during BGSAVE with THP enabled.                                              |

---

## Sizing tiers

### Standalone (dev / low-traffic internal)

```yaml
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    memory: 256Mi # no CPU limit
```

`maxmemory 192mb` in redis.conf (75% of 256Mi).

---

### Replication — small (cache, session, sub-10 GB dataset)

```yaml
# Redis primary / replica
resources:
  requests:
    cpu: 500m
    memory: 2Gi
  limits:
    memory: 2Gi

# Sentinel
resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    memory: 128Mi
```

`maxmemory 1536mb` (~75% of 2Gi).

---

### Replication — medium (primary datastore, 10–30 GB dataset)

```yaml
# Redis primary / replica
resources:
  requests:
    cpu: 1000m
    memory: 8Gi
  limits:
    memory: 8Gi

# Sentinel
resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    memory: 128Mi
```

`maxmemory 6144mb` (75% of 8Gi).

---

### Replication — large (high-throughput cache, 30–60 GB dataset)

```yaml
# Redis primary / replica
resources:
  requests:
    cpu: 2000m
    memory: 16Gi
  limits:
    memory: 16Gi

# Sentinel
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    memory: 256Mi
```

`maxmemory 12288mb` (75% of 16Gi).

---

### Cluster — per shard (Twitter/Discord-scale, sharded dataset)

Each shard is a primary + replica pair. Right-size shards to keep datasets ≤ 25 GB per shard (smaller dataset = faster BGSAVE fork, lower replication lag).

```yaml
# Cluster node (primary or replica)
resources:
  requests:
    cpu: 2000m
    memory: 32Gi
  limits:
    memory: 32Gi
```

`maxmemory 24576mb` (75% of 32Gi).

Minimum 3 primaries × 3 replicas for cluster quorum. Scale shards horizontally before scaling memory vertically — fork time grows linearly with RSS.

---

## Metrics exporter (redis-exporter sidecar)

Same for all tiers:

```yaml
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 100m
    memory: 128Mi
```

CPU limit is fine on the exporter — it is not latency-sensitive.

---

## Operator

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi
```

---

## Key rationale for no CPU limit on Redis

Redis processes commands on a single thread. Under Kubernetes CFS (Completely Fair Scheduler), a pod hitting its CPU limit is throttled in 100 ms windows. A throttle window that lands during a `KEYS` scan or a Lua script execution stalls the entire command queue — clients see latency spikes at p99/p999 that look like network issues but are scheduler artifacts.

Recommended approach:

- Set `requests` to reflect actual steady-state usage (use VPA in recommendation mode for 2 weeks to calibrate).
- Omit `limits.cpu` entirely, or set it to 4–8× the request as a safety ceiling.
- Alert on CPU usage > 80% of the request as a capacity signal to scale.

## maxmemory policy by use case

| Use case                      | policy                   |
| ----------------------------- | ------------------------ |
| Cache (TTL-based)             | `allkeys-lru`            |
| Session store                 | `volatile-lru`           |
| Pub/sub only (no persistence) | `noeviction`             |
| Leaderboards / sorted sets    | `allkeys-lfu` (Redis 4+) |
