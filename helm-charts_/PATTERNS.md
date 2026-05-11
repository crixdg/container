# Helm Chart Patterns for Infrastructure

A practical guide for deploying infrastructure on Kubernetes — starting lean on a single node, with a clear path to HA and multi-node scale without breaking production.

---

## Core Philosophy

> Start simple. Design for change. Never trap yourself.

The goal is not to deploy HA on day one, but to **never make a choice today that prevents HA tomorrow**. Every value you set, every field you skip, should be consciously decided with that lens.

---

## 1. Replica Count — The Single Most Important Knob

```yaml
# Single-node start (dev / early prod)
replicaCount: 1

# HA minimum (requires ≥ 3 schedulable nodes)
replicaCount: 3
```

**Rules:**

- Never hardcode `replicaCount` in a chart template. Always expose it as a value.
- For stateful sets (Kafka, Cassandra, Elasticsearch), `replicaCount: 1` is valid but means **zero fault tolerance** — document this explicitly in your values file with a comment.
- For quorum-based systems (Kafka KRaft, Elasticsearch master), the jump from 1 → 3 is non-disruptive if your PVC naming scheme and `podManagementPolicy` are correct.

---

## 2. Storage — Never Paint Yourself into a Corner

### Always enable persistence, even on a single node

```yaml
persistence:
  enabled: true # NEVER false in production
  storageClass: longhorn # or your CSI driver
  size: 20Gi
```

`enabled: false` means data lives in an emptyDir — it is gone on pod restart. There is no safe migration path from emptyDir to PVC after go-live.

### StorageClass must support ReadWriteOnce at minimum

For HA, pods need to reschedule to different nodes. `ReadWriteOnce` PVCs bind to a node; if a pod reschedules, the volume must follow. Longhorn handles this. HostPath does not — using HostPath traps you on a single node permanently.

| StorageClass | Single-node OK | Multi-node OK | Notes     |
| ------------ | -------------- | ------------- | --------- |
| `longhorn`   | Yes            | Yes           | Preferred |
| `local-path` | Yes            | No            | Traps you |
| `hostPath`   | Yes            | No            | Traps you |

### Size the PVC conservatively but not too small

Resizing PVCs requires the `allowVolumeExpansion: true` flag on the StorageClass, and **StatefulSet PVCs cannot be resized by Helm** — you must patch them manually. Size generously upfront to avoid this.

---

## 3. Resource Requests and Limits

### Always set requests. Limits are optional but recommended.

```yaml
resources:
  requests:
    cpu: 500m
    memory: 1Gi
  limits:
    cpu: 2
    memory: 2Gi
```

**Why requests matter:**

- Kubernetes uses requests for scheduling. Without them, the scheduler places pods randomly and a node can be OOM-killed silently.
- In a single-node cluster, this prevents one service from starving another.
- When you scale to multi-node, requests are already tuned — pods land on the right nodes automatically.

**Limits gotcha:**

- CPU limits cause throttling, not eviction. A service that occasionally needs burst CPU will become slow, not die. Consider setting limits 2–4× above requests.
- Memory limits cause OOM kills. Set them based on observed peak, not theoretical. If you don't know, start without a memory limit and observe.

### Single-node budget

On a single node you have a fixed budget. Sum your `requests` across all services and leave headroom:

```
Total node memory - OS overhead (~2Gi) - k3s system pods (~1Gi) = available budget
```

If your requests exceed the budget, pods will be Pending. Start lean, monitor with Prometheus, and resize as you learn actual usage.

---

## 4. Pod Anti-Affinity — The Bridge to HA

This is the single most important field to add **before** you need HA:

```yaml
# Soft anti-affinity: prefer spreading, but don't block scheduling on single node
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: kafka
          topologyKey: kubernetes.io/hostname

# Hard anti-affinity: enforce spreading (use only when you have enough nodes)
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app.kubernetes.io/name: kafka
        topologyKey: kubernetes.io/hostname
```

**Strategy:**

- Use `preferred` (soft) from day one. It works on a single node (all pods land on the same node — fine) and automatically spreads when new nodes join.
- Switch to `required` (hard) only after you have confirmed ≥ N nodes where N = replicaCount.

Do not skip anti-affinity. Adding it later means restarting pods, which causes a brief outage for stateless services and a rolling restart for stateful ones.

---

## 5. Probes — Disable Only With a Comment, Re-enable Before HA

Several charts in this repo have probes disabled:

```yaml
livenessProbe:
  enabled: false # resource-constrained single node: avoids false restarts under load
readinessProbe:
  enabled: false
```

This is acceptable on a single dev/early-prod node but **dangerous at HA scale**. Without a readiness probe, a pod that is still initializing will receive traffic and return errors.

**Checklist before enabling HA:**

- [ ] Re-enable `readinessProbe` on all stateful services
- [ ] Tune `initialDelaySeconds` to be > actual startup time (check pod logs)
- [ ] Re-enable `livenessProbe` with a generous `failureThreshold` (≥ 3)

---

## 6. Topology Spread Constraints (Kubernetes 1.19+)

A more expressive alternative to anti-affinity for spreading across zones:

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule # hard
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: kafka
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway # soft fallback for single-node
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: kafka
```

Use `ScheduleAnyway` when you don't yet have multiple zones. It degrades gracefully.

---

## 7. PodDisruptionBudget — Required for Safe Node Maintenance

Without a PDB, `kubectl drain` will evict all replicas of a service simultaneously, causing downtime.

```yaml
# In your helm values or as a separate manifest
podDisruptionBudget:
  enabled: true
  minAvailable: 1 # for replicaCount 3, this means at most 2 can be evicted at once
  # OR
  maxUnavailable: 1
```

Add this from day one. It is a no-op on a single node (there are no drain operations) and critical the moment you add a second node.

---

## 8. Ingress — Use IngressClass from Day One

```yaml
ingress:
  enabled: true
  ingressClassName: nginx # always explicit
  pathType: Prefix
  hostname: service.ip.nip.io
```

Never rely on the default ingress class annotation. If you add a second ingress controller later (e.g., for internal vs external traffic), explicit `ingressClassName` means services don't silently move to the wrong controller.

For production, replace `nip.io` wildcard hostnames with real DNS before going HA — nip.io is a free public DNS resolver and may be unreliable.

---

## 9. Secrets Management

**Do not commit passwords to git**, even in a private repo.

Current anti-pattern in this repo (to be fixed):

```yaml
admin:
  password: "admin" # NEVER commit real passwords
```

Acceptable patterns in order of preference:

1. **Sealed Secrets** — encrypt secrets with `kubeseal`, commit the sealed form
2. **External Secrets Operator** — sync from Vault, AWS SSM, or similar
3. **Helm --set at deploy time** — `helm upgrade ... --set admin.password=$SECRET_FROM_ENV`
4. **Pre-created k8s Secrets** — create manually or via CI, reference by name in values

For a small studio, option 3 (Helm `--set`) is the pragmatic start. The key constraint: the secret must come from an environment variable or secret manager in CI, never from a committed file.

---

## 10. Upgrade Safety — Helm Values Discipline

### Use `helm diff` before every upgrade

```bash
helm diff upgrade <release> <chart> -f helm-values.yaml
```

Always review what will change before applying.

### StatefulSet caveats

Helm cannot change certain StatefulSet fields (storage size, `volumeClaimTemplates`) without a delete-and-recreate. Plan for this:

- If you need to resize a PVC: do it manually via `kubectl patch pvc`, not via Helm
- If you need to change a StatefulSet's `volumeClaimTemplates`: you must delete the StatefulSet (`kubectl delete sts --cascade=orphan`) and re-apply — the `--cascade=orphan` flag keeps the pods and PVCs running during the transition

### Test upgrades on a staging namespace first

```bash
helm upgrade <release> <chart> -f helm-values.yaml -n staging --dry-run
```

---

## 11. Monitoring — Wire It In Before You Need It

Every service in this repo has metrics enabled. Keep it that way:

```yaml
metrics:
  enabled: true
```

The cost of scraping metrics is low. The cost of debugging a production incident without metrics is high. Prometheus and Grafana are already deployed — use them.

**Minimum dashboards to have before calling a service "production-ready":**

- Pod restarts over time
- Memory usage vs limit
- CPU usage vs request
- Error rate / latency (application-level)
- PVC usage %

---

## 12. The Single-Node → HA Migration Checklist

When you are ready to add nodes and enable HA, run through this list for each service:

| Check                                          | Why                                                          |
| ---------------------------------------------- | ------------------------------------------------------------ |
| StorageClass supports multi-node               | HostPath/local-path will prevent pod scheduling on new nodes |
| `replicaCount` ≥ 3 for quorum systems          | Kafka, Elasticsearch master, Cassandra need odd quorum       |
| Anti-affinity set to `preferred` or `required` | Prevents all replicas landing on one node                    |
| Readiness and liveness probes enabled          | Without them, traffic hits unready pods                      |
| PodDisruptionBudget enabled                    | Prevents simultaneous eviction during drain                  |
| Resource requests set on all pods              | Ensures scheduler distributes load correctly                 |
| No hardcoded node names or nodeSelectors       | Binds pods to a specific node                                |
| Ingress using explicit `ingressClassName`      | Avoids misrouting when adding controllers                    |
| Secrets not in git                             | Rotation and compliance                                      |

---

## 13. Naming and Label Conventions

Consistent labels enable multi-dimensional querying in Prometheus and cross-service correlation in Grafana.

Always include:

```yaml
labels:
  app.kubernetes.io/name: kafka
  app.kubernetes.io/instance: kafka-prod
  app.kubernetes.io/component: broker # broker / controller / master / data
  app.kubernetes.io/part-of: data-platform # logical grouping
  app.kubernetes.io/managed-by: helm
```

These are standard Kubernetes recommended labels and most Helm charts generate them automatically — do not override or strip them.

---

## 14. Per-Chart Quick Reference

| Chart           | Single-node safe?       | HA replica min            | Key HA concern                                                         |
| --------------- | ----------------------- | ------------------------- | ---------------------------------------------------------------------- |
| Kafka (KRaft)   | Yes (1 broker + 1 ctrl) | 3 controllers + 3 brokers | Quorum needs odd number; external NodePorts must be 1:1 per pod        |
| Elasticsearch   | Yes (combined node)     | 3 master + 2 data         | Split-brain if master quorum wrong; use dedicated master nodes         |
| Cassandra       | Yes (1 replica)         | 3 replicas                | RF=1 means no redundancy; set `replication_factor` ≥ 3 in keyspace DDL |
| Prometheus      | Yes (1 replica)         | Use Thanos/Cortex for HA  | Single instance is acceptable; HA needs remote write                   |
| Grafana         | Yes (1 replica)         | 2+ with shared DB         | Default SQLite is single-node only; switch to Postgres for HA          |
| Kafka AKHQ      | Yes (1 replica)         | 2+ (stateless)            | Stateless — easiest to scale                                           |
| Schema Registry | Yes (1 replica)         | 2+ (stateless)            | Stateless — just increase replicaCount                                 |

---

## 15. File Layout Convention

Each chart directory should contain:

```
helm-charts/
└── <service>/
    ├── helm-values.yaml          # active production values
    ├── helm-values.single.yaml   # single-node minimal values (for reference / staging)
    └── external.yaml             # if the service is external (no k8s deployment)
```

`helm-values.single.yaml` serves as documentation of what was trimmed for the single-node phase and what the HA version added. Do not delete it when you graduate to HA — it is useful for provisioning test environments cheaply.
