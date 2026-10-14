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
| Kafka       | Strimzi 1.3.0, Kafka 4.3.1 KRaft, single combined node              |

### Service config under test

| Service  | CPU (pinned) | Memory | Key settings                                                                                                               |
| -------- | ------------ | ------ | -------------------------------------------------------------------------------------------------------------------------- |
| Postgres | 2 (`2,8`)    | 5Gi    | `shared_buffers=1280MB`, `effective_cache_size=3584MB`, `max_wal_size=4GB`, `wal_compression=lz4`, `synchronous_commit=on` |
| Redis    | 2 (`3,9`)    | 2Gi    | `maxmemory=1536mb`, `noeviction`, `io-threads=2`, persistence off                                                          |
| Kafka    | 2 (`1,7`)    | 4Gi    | heap 2g, `num.io.threads=8`, `num.network.threads=3`, socket buffers 1MiB, RF 1                                            |

### Method

- Load generators run in separate BestEffort pods (`postgres/pgbench`, `redis/redis-bench`,
  `kafka/kafka-bench`) on the
  shared CPU pool `0,4,5,6,10,11`, so they never share cores with the system under test.
- Traffic goes through the in-cluster ClusterIP services (`postgres-rw`, `redis`,
  `kafka-kafka-bootstrap`).
- CPU and disk figures come from Prometheus (`container_cpu_usage_seconds_total`,
  `node_disk_*`) over the test window.

Client pods:

```bash
kubectl run pgbench -n postgres --image=ghcr.io/cloudnative-pg/postgresql:18 \
  --restart=Never --env PGPASSWORD=<password> --command -- sleep 7200
kubectl run redis-bench -n redis --image=redis:8.6.1 \
  --restart=Never --command -- sleep 7200
kubectl run kafka-bench -n kafka --image=quay.io/strimzi/kafka:1.3.0-kafka-4.3.1 \
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

### Kafka (kafka-producer-perf-test / kafka-consumer-perf-test)

Topic `perf-test`: 6 partitions, RF 1, created with a `KafkaTopic` CR.

```bash
B=kafka-kafka-bootstrap:9092
P=/opt/kafka/bin
# P1 max throughput, no compression
$P/kafka-producer-perf-test.sh --topic perf-test --num-records 5000000 --record-size 1024 --throughput -1 \
  --producer-props bootstrap.servers=$B acks=1 linger.ms=5 batch.size=131072 compression.type=none
# P2 same with lz4
$P/kafka-producer-perf-test.sh --topic perf-test --num-records 5000000 --record-size 1024 --throughput -1 \
  --producer-props bootstrap.servers=$B acks=1 linger.ms=5 batch.size=131072 compression.type=lz4
# P3 fixed rate latency
$P/kafka-producer-perf-test.sh --topic perf-test --num-records 1200000 --record-size 1024 --throughput 20000 \
  --producer-props bootstrap.servers=$B acks=all linger.ms=0
# P4 three P1 producers in parallel, 3M records each
# C1 consumer
$P/kafka-consumer-perf-test.sh --topic perf-test --messages 5000000 --bootstrap-server $B --group perf-test
```

| Test                  | Config                                     | Throughput                     | p50  | p99      | Max      |
| --------------------- | ------------------------------------------ | ------------------------------ | ---- | -------- | -------- |
| P1 producer max       | 1KB, `acks=1`, none, batch 128KB, linger 5 | **173k rec/s (169 MB/s)**      | 0 ms | 2,355 ms | 2,514 ms |
| P2 producer lz4       | as P1, `lz4`                               | 134k rec/s (131 MB/s)          | 1 ms | 2,541 ms | 4,310 ms |
| P3 fixed rate         | 20k rec/s, `acks=all`, linger 0            | 20k rec/s (19.5 MB/s)          | 0 ms | **1 ms** | 265 ms   |
| P4 3 producers        | as P1, x3 in parallel                      | **272k rec/s (265 MB/s)** sum  | 1 ms | ~4,050 ms | 4,144 ms |
| C1 consumer           | 5M records, 1 consumer                     | **534k rec/s (521 MB/s)**      | -    | -        | -        |

P3 p99.9 was 13 ms.

Observations:

- The broker is not the bottleneck. Even at 265 MB/s (P4) the Kafka JVM used about 0.44 of its
  2 pinned cores, request handler and network threads stayed above 99% idle, no throttling, GC near zero.
- The load generator is the limit: each producer process used about 1 core; three producers used
  2.3 cores of the 6-thread shared pool. NVMe writes reached 205 MB/s (55% busy) in P1 and
  285 MB/s (68% busy) in P4, so the disk was not saturated either.
- Multi-second p99 in P1, P2 and P4 is client-side queueing: with `--throughput -1` the producer
  `buffer.memory` (32MB) fills and time spent waiting in it counts as latency. At a sane rate (P3)
  p99 is 1 ms.
- `lz4` costs about 22% throughput here because compression runs on the client CPU and the
  benchmark payload barely compresses.
- To find the real broker ceiling, generate load from several client pods or from outside the node
  (NodePort `32090`), and raise `buffer.memory`.

### Next runs to compare

- Postgres with 4 pinned CPUs (read-only should scale; read-write should stay disk bound).
- Postgres with a separate WAL volume (`walStorage`) for the read-write case.
- Redis with load generated from outside the node (NodePort `30379`) to include real network.
- Kafka with several client pods or external clients to find the broker ceiling.
