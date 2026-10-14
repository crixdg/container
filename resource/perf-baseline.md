# Performance Baseline (Reference)

Baseline numbers from the single-node k3s perf lab, recorded for comparison with future runs.
Treat them as reference points for this exact hardware and config, not as targets.

## Run 2026-10-14

### Environment

| Item        | Value                                                               |
| ----------- | ------------------------------------------------------------------- |
| Host        | Intel i5-10400 (6C/12T, 1 NUMA node), 19Gi RAM, single NVMe         |
| OS / kernel | Rocky Linux 10.1, 6.12.0-124.55.1.el10_1                            |
| k3s         | v1.36.0+k3s1, static CPU manager, `full-pcpus-only`, reserved `0,6` |
| Node tuning | THP never, firewalld off, sysctl per `k3s/TUNING.md`                |
| Storage     | local-path on `/home/k3s-storage` (XFS on LVM, NVMe)                |
| Postgres    | CloudNativePG 0.29.1, PostgreSQL 18, 1 instance                     |
| Redis       | redis-operator 0.27.0, Redis 8.6.1 standalone                       |

### Service config under test

| Service  | CPU (pinned) | Memory | Key settings                                                                                                               |
| -------- | ------------ | ------ | -------------------------------------------------------------------------------------------------------------------------- |
| Postgres | 2 (`2,8`)    | 5Gi    | `shared_buffers=1280MB`, `effective_cache_size=3584MB`, `max_wal_size=4GB`, `wal_compression=lz4`, `synchronous_commit=on` |
| Redis    | 2 (`3,9`)    | 2Gi    | `maxmemory=1536mb`, `noeviction`, `io-threads=2`, persistence off                                                          |

### Method

- Load generators run in separate BestEffort pods (`postgres/pgbench`, `redis/redis-bench`) on the
  shared CPU pool `0,4,5,6,10,11`, so they never share cores with the system under test.
- Traffic goes through the in-cluster ClusterIP services (`postgres-rw`, `redis`).
- CPU and disk figures come from Prometheus (`container_cpu_usage_seconds_total`,
  `node_disk_*`) over the test window.

Client pods:

```bash
kubectl run pgbench -n postgres --image=ghcr.io/cloudnative-pg/postgresql:18 \
  --restart=Never --env PGPASSWORD=<password> --command -- sleep 7200
kubectl run redis-bench -n redis --image=redis:8.6.1 \
  --restart=Never --command -- sleep 7200
```

The `quay.io/opstree/redis` image does not ship `redis-benchmark`; use the official `redis` image.

### Postgres (pgbench)

Dataset: scale 100 (10M rows in `pgbench_accounts`, about 1.5GB, larger than `shared_buffers`).

```bash
pgbench -h postgres-rw -U pg-admin -i -s 100 -q postgres             # init: 15.7 s
pgbench -h postgres-rw -U pg-admin -c 16 -j 4 -T 60 -P 15 postgres   # read-write
pgbench -h postgres-rw -U pg-admin -S -c 32 -j 4 -T 60 -P 15 postgres # read-only
```

| Test               | Clients | TPS        | Avg latency | Stddev  | Failed |
| ------------------ | ------- | ---------- | ----------- | ------- | ------ |
| Read-write (TPC-B) | 16      | **3,205**  | 4.99 ms     | 2.77 ms | 0      |
| Read-only (`-S`)   | 32      | **22,443** | 1.43 ms     | 0.67 ms | 0      |

Observations:

- Read-write is disk bound, not CPU bound: Postgres used about 1.5 of 2 cores while NVMe writes
  peaked at 206 MB/s with the device 72% busy (WAL + fsync).
- Read-only is CPU bound: Postgres used about 1.8 of 2 cores. More pinned cores is the lever.
- Buffer cache hit ratio 94.8%; the dataset exceeds `shared_buffers` and the OS page cache covers the rest.
- No CPU throttling observed.

### Redis (redis-benchmark)

```bash
redis-benchmark -h redis -c 50 -n 500000 --threads 4 -d 256 -r 100000 \
  -t set,get,incr,lpush,lpop,hset,mset --csv
redis-benchmark -h redis -c 50 -n 2000000 --threads 4 -d 256 -r 100000 \
  -P 16 -t set,get --csv
```

| Command        | Pipeline | RPS         | p50      | p95      | p99      | Max       |
| -------------- | -------- | ----------- | -------- | -------- | -------- | --------- |
| SET            | 1        | 133,298     | 0.359 ms | 0.495 ms | 0.527 ms | 1.511 ms  |
| GET            | 1        | 133,333     | 0.343 ms | 0.455 ms | 0.487 ms | 10.447 ms |
| INCR           | 1        | 142,816     | 0.343 ms | 0.455 ms | 0.487 ms | 1.487 ms  |
| LPUSH          | 1        | 124,969     | 0.383 ms | 0.503 ms | 0.535 ms | 1.839 ms  |
| LPOP           | 1        | 133,333     | 0.351 ms | 0.471 ms | 0.487 ms | 1.039 ms  |
| HSET           | 1        | 133,298     | 0.359 ms | 0.479 ms | 0.503 ms | 1.359 ms  |
| MSET (10 keys) | 1        | 79,987      | 0.599 ms | 0.815 ms | 0.855 ms | 20.639 ms |
| SET            | 16       | **727,008** | 1.031 ms | 1.415 ms | 1.511 ms | 2.151 ms  |
| GET            | 16       | **727,008** | 0.999 ms | 1.295 ms | 1.375 ms | 2.135 ms  |

Observations:

- Without pipelining, RPS is flat at about 133k across commands: the run is bound by
  pod-to-pod round-trip latency, not by Redis.
- Pipeline 16 gives about 5.5x throughput (727k RPS) at about 1 ms p50.
- The pipelined run lasted about 6 s, shorter than the 15 s scrape interval, so its Grafana CPU
  figures are not reliable. Use a longer run (`-n 20000000`) when the dashboard view matters.
- No CPU throttling observed.

### Next runs to compare

- Postgres with 4 pinned CPUs (read-only should scale; read-write should stay disk bound).
- Postgres with a separate WAL volume (`walStorage`) for the read-write case.
- Redis with load generated from outside the node (NodePort `30379`) to include real network.
- Kafka producer/consumer perf test with the same layout.
