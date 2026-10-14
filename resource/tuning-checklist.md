# Service Tuning Checklist (Performance Test Lab)

Checklist for data services running on the single-node k3s performance lab.
Node, OS and k3s tuning lives in the `k3s` repo: `TUNING.md`.

Reference budget on 6C/12T, 19Gi:

| Component                   | CPU  | Memory | QoS        |
| --------------------------- | ---- | ------ | ---------- |
| system + kube reserved      | 2    | 2Gi    | -          |
| Kafka                       | 3    | 4Gi    | Guaranteed |
| Postgres                    | 3    | 5Gi    | Guaranteed |
| Redis                       | 1    | 2Gi    | Guaranteed |
| Monitoring                  | ~1.5 | ~3Gi   | Burstable  |
| Apps + load generator       | ~1.5 | ~3Gi   | -          |

## 0. Common to all services

- [ ] `storageClass` matches what the cluster actually has (`local-path`, not `longhorn`)
  `kubectl get sc`
- [ ] requests == limits with integer CPU (Guaranteed QoS, eligible for static CPU pinning)
  `kubectl get pod <pod> -n <ns> -o jsonpath='{.status.qosClass}'`
- [ ] No CPU limit below the real need (CFS throttling shows up as p99 spikes)
  `cat /sys/fs/cgroup/kubepods.slice/.../cpu.stat | grep throttled`
- [ ] Operator chart versions and images pinned
- [ ] Exporter / metrics endpoint enabled and scraped by Prometheus (ServiceMonitor or PodMonitor)
- [ ] PVC `deleteClaim` / reclaim policy chosen on purpose (Delete for lab, Retain for anything kept)
- [ ] Credentials from a Secret, not inline in the CR
- [ ] Unused operators and CRs removed (Mongo, akhq, cert-manager when not tested)

## 1. Kafka (Strimzi, KRaft)

- [ ] Resources: `requests == limits`, `cpu: 3`, `memory: 4Gi`
- [ ] JVM heap set explicitly, about 50% of container memory (`jvmOptions: -Xms: 2g, -Xmx: 2g`); the rest stays free for the OS page cache that Kafka relies on
- [ ] G1 GC defaults kept; `-XX:MaxGCPauseMillis=20` only if latency tests show GC pauses
- [ ] Broker config for the lab:
  - [ ] `num.network.threads: 3`, `num.io.threads: 8` (scale with cores)
  - [ ] `num.partitions` and `default.replication.factor: 1` match a single broker
  - [ ] `log.segment.bytes`, `log.retention.hours` / `log.retention.bytes` sized so a test run cannot fill the PVC
  - [ ] `socket.send.buffer.bytes` / `socket.receive.buffer.bytes: 1048576`
  - [ ] `compression.type: producer` (let the benchmark choose)
- [ ] PVC size covers retention x throughput of the longest test
- [ ] Topic partitions sized for consumer parallelism of the test
- [ ] Metrics: Strimzi `metricsConfig` (JMX Prometheus exporter) + Kafka Exporter for consumer lag
- [ ] External access: NodePort listener fixed (`32090`) for out-of-cluster load generators
- [ ] Entity operator resources set (it is BestEffort by default)
- [ ] Verify: `kubectl get kafka,kafkanodepool -n kafka`, producer/consumer perf test baseline recorded
  `kafka-producer-perf-test.sh`, `kafka-consumer-perf-test.sh`

## 2. Postgres (CloudNativePG)

- [ ] Resources: `requests == limits`, `cpu: 3`, `memory: 5Gi`
- [ ] Memory parameters sized to the container, not to the node:
  - [ ] `shared_buffers: 1280MB` (about 25% of memory)
  - [ ] `effective_cache_size: 3584MB` (about 70%)
  - [ ] `work_mem: 16MB` (watch: per sort/hash, per connection)
  - [ ] `maintenance_work_mem: 256MB`
- [ ] Parallelism matches the CPU limit, not the node (CNPG default is 32):
  - [ ] `max_worker_processes: 4`
  - [ ] `max_parallel_workers: 3`
  - [ ] `max_parallel_workers_per_gather: 2`
- [ ] WAL and checkpoints:
  - [ ] `wal_buffers: 16MB`
  - [ ] `max_wal_size: 4GB`, `min_wal_size: 1GB`
  - [ ] `checkpoint_completion_target: 0.9`
  - [ ] `wal_compression: lz4`
- [ ] SSD planner costs: `random_page_cost: 1.1`, `effective_io_concurrency: 200`
- [ ] `max_connections` sized to the test; put PgBouncer (CNPG `Pooler`) in front for high connection counts instead of raising it
- [ ] `wal_level: replica` unless logical decoding is part of the test (logical adds WAL volume)
- [ ] `synchronous_commit`: keep `on` for realistic numbers; document if a run uses `off`
- [ ] `pg_stat_statements` in `shared_preload_libraries` for query-level analysis
- [ ] Optional: separate WAL volume (`walStorage`) when testing write-heavy loads
- [ ] Metrics: CNPG built-in exporter on `:9187` + PodMonitor (`monitoring.enablePodMonitor: true`)
- [ ] Verify: `kubectl cnpg status postgres -n postgres`, `pgbench` baseline recorded

## 3. Redis (ot-container-kit operator)

- [ ] Resources: `requests == limits`, `cpu: 1`, `memory: 2Gi` (Redis is single-threaded for commands; 1 core is enough, the limit only prevents throttling of background threads)
- [ ] `maxmemory` about 75-80% of the limit (`1536mb` for 2Gi) so the dataset fits; the test must not silently evict
- [ ] `maxmemory-policy`: `noeviction` for store tests (errors instead of silent data loss), `allkeys-lru` only for cache tests
- [ ] Persistence off for throughput tests (`appendonly no`, `save ""`); on and documented for durability tests
- [ ] `io-threads: 2` (offloads socket I/O on Redis 6+)
- [ ] `tcp-backlog: 65535` (needs `net.core.somaxconn` raised on the node)
- [ ] `timeout 0` during load tests (idle connection reaping skews pooled clients)
- [ ] THP disabled on the node (Redis logs a warning when enabled)
- [ ] `vm.overcommit_memory = 1` on the node (fork for BGSAVE)
- [ ] Metrics: `redisExporter.enabled: true` + ServiceMonitor
- [ ] Verify: `redis-cli INFO memory`, `redis-cli INFO stats | grep evicted_keys` stays 0, `redis-benchmark` baseline recorded

## 4. Monitoring (kube-prometheus-stack)

- [ ] Prometheus resources bounded (`requests: 500m/1.5Gi`, `limits: memory 2Gi`)
- [ ] Short retention for the lab (`retention: 7d`, `retentionSize: 15GB`) on a PVC
- [ ] `scrapeInterval: 15s` (5s only for short focused runs)
- [ ] Alertmanager disabled unless alerts are tested
- [ ] Grafana dashboards: Node Exporter Full, Kubernetes compute resources, Strimzi Kafka, CNPG, Redis
- [ ] `serviceMonitorSelectorNilUsesHelmValues: false` and `podMonitorSelectorNilUsesHelmValues: false` so ServiceMonitors from other namespaces are picked up
- [ ] k3s component scraping adjusted (k3s runs etcd/scheduler/controller-manager inside one process; disable the default `kubeEtcd`, `kubeScheduler`, `kubeControllerManager`, `kubeProxy` targets or point them at the node IP)
- [ ] Grafana exposed via NodePort or Traefik ingress

## 5. Test run hygiene

- [ ] Fresh data or known dataset loaded before each run
- [ ] Warm-up period excluded from results
- [ ] Throttling, eviction and OOM counters checked after each run
  `kubectl get events -A | grep -E 'OOM|Evict'`
- [ ] Results recorded with the exact config: chart versions, CR spec, service parameters, node sysctl dump
