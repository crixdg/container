# Operators vs Plain Helm for Stateful Infrastructure

A decision guide for when to use a Kubernetes Operator instead of (or alongside) plain Helm values, with a focus on the services in this repo.

---

## The Core Problem Operators Solve

Plain Helm is a templating and packaging tool. It applies manifests and tracks releases — but it has no understanding of what is running inside a StatefulSet. When you `helm upgrade` a Kafka chart, Helm restarts pods in StatefulSet order without any awareness of leader election, partition leadership, or quorum state.

An Operator is a controller that runs inside the cluster and continuously reconciles the desired state you declare. It understands the application's internals and can sequence operations safely.

| Operation                       | Plain Helm                                                    | Operator                                                      |
| ------------------------------- | ------------------------------------------------------------- | ------------------------------------------------------------- |
| Upgrade broker version          | Restarts all pods in index order; may lose quorum mid-upgrade | Drains one broker at a time, waits for partition reassignment |
| Scale brokers from 3 → 5        | Adds pods; you manually rebalance partitions                  | Triggers rebalance automatically after pods are ready         |
| Node failure + pod rescheduled  | Pod restarts; PVC must follow; no data repair                 | Operator detects, reschedules, and triggers repair/rejoin     |
| Config change requiring restart | Helm upgrade restarts everything at once                      | Rolling restart respecting quorum                             |
| PVC resize                      | Manual `kubectl patch` + StatefulSet delete/recreate          | In-place via CR update                                        |
| Certificate rotation            | Manual secret update + pod restart                            | Operator handles rotation without downtime                    |

---

## When Plain Helm Is Fine

- **Stateless services**: AKHQ, Schema Registry, Grafana, Prometheus. These have no quorum, no data, no leader — a rolling restart is safe and Helm handles it correctly.
- **Single-replica stateful services**: If you're running one Prometheus, one Grafana, the operator's HA orchestration logic adds complexity for zero benefit.
- **Early-stage / single-node**: The operational overhead of learning a new CRD API is not worth it until you need the HA guarantees the operator provides.

---

## Per-Service Operator Recommendation

### Kafka — Strimzi

**Switch when:** You go to HA (3+ brokers) or need safe version upgrades.

Strimzi replaces the Bitnami Helm chart entirely. You declare a `Kafka` custom resource:

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: kafka
  namespace: kafka
spec:
  kafka:
    version: 3.9.0
    replicas: 3
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
      - name: external
        port: 9094
        type: nodeport
        tls: false
    config:
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
      transaction.state.log.min.isr: 2
      default.replication.factor: 3
      min.insync.replicas: 2
    storage:
      type: persistent-claim
      size: 30Gi
      class: longhorn
    resources:
      requests:
        cpu: "1"
        memory: 2Gi
      limits:
        cpu: "2"
        memory: 4Gi
  zookeeper: # or use KRaft mode in Strimzi 0.39+
    replicas: 3
    storage:
      type: persistent-claim
      size: 8Gi
      class: longhorn
  entityOperator:
    topicOperator: {} # manages KafkaTopic CRs
    userOperator: {} # manages KafkaUser CRs
```

**What you gain over Bitnami Helm:**

- Safe rolling upgrades — Strimzi checks under-replicated partitions before moving to the next broker
- `KafkaTopic` and `KafkaUser` CRs — manage topics and ACLs declaratively in git
- Built-in JMX metrics endpoint wiring
- Cruise Control integration for partition rebalancing

**Migration path from Bitnami:** Non-trivial. Strimzi uses different pod naming and a different storage layout. Plan for a parallel cluster + consumer group migration rather than in-place conversion.

---

### Elasticsearch — ECK (Elastic Cloud on Kubernetes)

**Switch when:** You go to 3+ master nodes or need zero-downtime version upgrades.

ECK is free for basic use (self-managed license). You declare an `Elasticsearch` CR:

```yaml
apiVersion: elasticsearch.k8s.elastic.co/v1
kind: Elasticsearch
metadata:
  name: elasticsearch
  namespace: elastic
spec:
  version: 8.17.0
  nodeSets:
    - name: masters
      count: 3
      config:
        node.roles: ["master"]
        xpack.security.enabled: false
      podTemplate:
        spec:
          containers:
            - name: elasticsearch
              resources:
                requests:
                  cpu: 1
                  memory: 4Gi
      volumeClaimTemplates:
        - metadata:
            name: elasticsearch-data
          spec:
            accessModes: ["ReadWriteOnce"]
            storageClassName: longhorn
            resources:
              requests:
                storage: 8Gi
    - name: data
      count: 3
      config:
        node.roles: ["data", "ingest"]
        xpack.security.enabled: false
      podTemplate:
        spec:
          containers:
            - name: elasticsearch
              resources:
                requests:
                  cpu: 4
                  memory: 16Gi
      volumeClaimTemplates:
        - metadata:
            name: elasticsearch-data
          spec:
            accessModes: ["ReadWriteOnce"]
            storageClassName: longhorn
            resources:
              requests:
                storage: 60Gi
```

**What you gain over Bitnami Helm:**

- ECK knows about shard allocation — it won't restart a data node until shards are relocated
- Handles the `cluster.initial_master_nodes` bootstrap problem automatically
- Version upgrades are orchestrated (masters first, then data nodes)
- Kibana CR that auto-wires to the Elasticsearch CR

---

### Cassandra — K8ssandra

**Switch when:** You need cross-datacenter replication, automated repairs, or safe rolling upgrades.

K8ssandra adds Medusa (backup/restore), Reaper (anti-entropy repair scheduling), and a `CassandraDatacenter` CR on top of the DataStax operator:

```yaml
apiVersion: k8ssandra.io/v1alpha1
kind: K8ssandraCluster
metadata:
  name: cassandra
  namespace: cassandra
spec:
  cassandra:
    serverVersion: "4.1.3"
    datacenters:
      - metadata:
          name: dc1
        size: 3
        storageConfig:
          cassandraDataVolumeClaimSpec:
            storageClassName: longhorn
            accessModes: ["ReadWriteOnce"]
            resources:
              requests:
                storage: 100Gi
        config:
          cassandraYaml:
            num_tokens: 16
        resources:
          requests:
            cpu: "4"
            memory: 16Gi
          limits:
            cpu: "8"
            memory: 32Gi
  reaper:
    autoScheduling:
      enabled: true # automated anti-entropy repair — critical for Cassandra health
  medusa:
    storageProperties:
      storageProvider: s3_compatible
      bucketName: cassandra-backups
      prefix: dc1
```

**What you gain over Bitnami Helm:**

- Automated Reaper scheduling — without regular repairs, Cassandra accumulates data inconsistencies silently
- Medusa backup/restore wired in from day one
- Safe decommission and scale-up (the operator issues `nodetool decommission` correctly)

---

### Postgres — CloudNativePG

**Switch when:** You need a standby replica, point-in-time recovery, or connection pooling.

CloudNativePG (CNPG) is the most production-ready Postgres operator available:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres
  namespace: postgres
spec:
  instances: 3 # 1 primary + 2 standbys
  primaryUpdateStrategy: unsupervised

  postgresql:
    parameters:
      max_connections: "200"
      shared_buffers: "256MB"

  storage:
    storageClass: longhorn
    size: 20Gi

  resources:
    requests:
      cpu: "1"
      memory: 1Gi
    limits:
      cpu: "2"
      memory: 2Gi

  backup:
    retentionPolicy: "30d"
    barmanObjectStore:
      destinationPath: s3://postgres-backups/
      s3Credentials:
        accessKeyId:
          name: s3-creds
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: s3-creds
          key: SECRET_ACCESS_KEY
```

**What you gain:**

- Automatic failover — primary failure triggers promotion of a standby in ~30 seconds
- Continuous WAL archiving to S3 — point-in-time recovery from any moment
- `kubectl cnpg status` shows replication lag, WAL position, and health at a glance
- PgBouncer pooler as a first-class CR

---

## Prometheus and Grafana — Stay on Helm

Use `kube-prometheus-stack` (the community Helm chart), not separate Prometheus and Grafana charts. It bundles Prometheus Operator, Alertmanager, Grafana, and default dashboards in one release.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack \
  -f helm-values.yaml -n monitor
```

The Prometheus Operator introduces `ServiceMonitor` and `PrometheusRule` CRDs — instead of editing scrape configs in `helm-values.yaml`, each service declares its own `ServiceMonitor`. This scales much better as the number of services grows.

For HA Prometheus, the right answer is **Thanos** (sidecar mode) rather than running two independent Prometheus instances — but this is only relevant when a single Prometheus instance becomes a bottleneck or you need cross-cluster federation.

---

## Decision Tree

```
Is the service stateless (AKHQ, Schema Registry, Grafana)?
  └─ Yes → Plain Helm is fine. Done.

Is it single-node / single-replica?
  └─ Yes → Plain Helm is fine. Revisit when you add replicas.

Are you running ≥ 3 replicas of a stateful service?
  └─ Yes → Do you need safe rolling upgrades without downtime?
              └─ Yes → Use the operator.
              └─ No  → Plain Helm is acceptable but risky.
```

---

## Migration Strategy: Bitnami Helm → Operator

Do not attempt an in-place migration. The pod naming, PVC naming, and internal bootstrap procedures differ between Bitnami charts and operators.

**Safe migration path:**

1. Deploy the operator-managed cluster in a **new namespace** alongside the existing Bitnami cluster
2. For Kafka: mirror topics using MirrorMaker 2, switch producers first, then consumers
3. For Elasticsearch: use cross-cluster replication or re-index from source
4. For Cassandra: add the new cluster as a second datacenter, let it replicate, then decommission the old datacenter
5. For Postgres: set up logical replication from old to new cluster, then promote and cut over

This approach keeps the old cluster live as a fallback until you are confident in the new one.

---

## Summary

| Service         | Current approach | Recommended for HA    | Migration complexity                         |
| --------------- | ---------------- | --------------------- | -------------------------------------------- |
| Kafka           | Bitnami Helm     | Strimzi               | High — parallel cluster + consumer migration |
| Elasticsearch   | Bitnami Helm     | ECK                   | Medium — cross-cluster replication           |
| Cassandra       | Bitnami Helm     | K8ssandra             | Medium — add datacenter, decommission old    |
| Postgres        | (none yet)       | CloudNativePG         | Low — start fresh with CNPG                  |
| Prometheus      | Bitnami Helm     | kube-prometheus-stack | Low — drop-in replacement                    |
| Grafana         | Bitnami Helm     | kube-prometheus-stack | Low — export dashboards, re-import           |
| AKHQ            | Bitnami Helm     | Stay on Helm          | N/A                                          |
| Schema Registry | Bitnami Helm     | Stay on Helm          | N/A                                          |
