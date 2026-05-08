# Postgres Scaling Guide (CloudNativePG)

Step-by-step procedures for scaling the Postgres cluster without data loss or application downtime.

---

## Current baseline

```
instances: 1   →   primary only, no standby, no failover
```

---

## Step 1: Single node → HA (1 → 3 instances)

This is the most important transition. CloudNativePG handles it as a rolling operation — the primary keeps serving traffic while standbys are provisioned and catch up via streaming replication.

### Pre-flight checks

```bash
# Confirm operator is healthy
kubectl get pods -n cnpg-system

# Confirm cluster is in a clean state (Phase: Cluster in healthy state)
kubectl get cluster postgres -n postgres

# Confirm you have ≥ 3 schedulable nodes (or at least enough PVC capacity on existing nodes)
kubectl get nodes
```

### Apply the change

Edit `helm-values.yaml`:
```yaml
spec:
  instances: 3   # was 1
```

Apply:
```bash
kubectl apply -f helm-values.yaml -n postgres
```

### What happens

1. Operator provisions `postgres-2` (first standby): creates PVC, starts pod, streams WAL from primary
2. Once `postgres-2` is caught up and in sync, operator provisions `postgres-3`
3. Both standbys register as streaming replicas — visible in `kubectl get cluster`
4. Primary (`postgres-1`) is untouched throughout

### Verify

```bash
# All 3 pods Running
kubectl get pods -n postgres

# Cluster shows "3 instances healthy"
kubectl get cluster postgres -n postgres

# Check replication lag on standbys (should be near 0)
kubectl cnpg status postgres -n postgres
```

### Rollback

Scaling back to 1 is safe — the operator demotes and removes standbys cleanly:
```yaml
instances: 1
```
```bash
kubectl apply -f helm-values.yaml -n postgres
```

---

## Step 2: Increase storage size

CloudNativePG supports online PVC resize if the StorageClass has `allowVolumeExpansion: true` (Longhorn does).

Edit `helm-values.yaml`:
```yaml
storage:
  size: 50Gi   # was 20Gi
```

Apply:
```bash
kubectl apply -f helm-values.yaml -n postgres
```

The operator patches each PVC one at a time and restarts pods in sequence (standbys first, then primary). No data loss, brief per-pod restart only.

Monitor:
```bash
kubectl get pvc -n postgres -w
```

---

## Step 3: Vertical scaling (CPU / memory)

Edit `helm-values.yaml`:
```yaml
resources:
  requests:
    cpu: "2"       # was 500m
    memory: 4Gi    # was 1Gi
  limits:
    cpu: "4"
    memory: 8Gi
```

Also tune PostgreSQL parameters to match the new memory:
```yaml
postgresql:
  parameters:
    shared_buffers: "1GB"           # ~25% of available memory
    effective_cache_size: "3GB"     # ~75% of available memory
    maintenance_work_mem: "256MB"
```

Apply:
```bash
kubectl apply -f helm-values.yaml -n postgres
```

The operator performs a rolling restart: standbys first, then a controlled primary switchover so the primary is restarted last with zero downtime for connected clients (requires the application to handle a brief reconnect).

---

## Step 4: Enable WAL archiving and backups

Required before treating the cluster as fully production-ready. Enables point-in-time recovery (PITR).

### Prerequisites

Create an S3 credentials secret (use MinIO if no external S3):
```bash
kubectl create secret generic s3-backup-creds \
  --from-literal=ACCESS_KEY_ID=<your-key> \
  --from-literal=SECRET_ACCESS_KEY=<your-secret> \
  -n postgres
```

Uncomment the backup block in `helm-values.yaml`:
```yaml
backup:
  retentionPolicy: "30d"
  barmanObjectStore:
    destinationPath: s3://postgres-backups/
    endpointURL: http://minio.minio:9000
    s3Credentials:
      accessKeyId:
        name: s3-backup-creds
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: s3-backup-creds
        key: SECRET_ACCESS_KEY
    wal:
      compression: gzip
```

Apply, then schedule a recurring base backup:
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: postgres-daily
  namespace: postgres
spec:
  schedule: "0 2 * * *"   # 2 AM daily
  cluster:
    name: postgres
  backupOwnerReference: self
```
```bash
kubectl apply -f scheduled-backup.yaml -n postgres
```

Verify the first backup runs:
```bash
kubectl get backup -n postgres
```

---

## Step 5: Enable monitoring

Once `kube-prometheus-stack` is deployed, flip the monitor flag:

```yaml
monitoring:
  enablePodMonitor: true
```

```bash
kubectl apply -f helm-values.yaml -n postgres
```

The operator creates a `PodMonitor` resource. Prometheus auto-discovers it within one scrape interval (default 15s). Import the official CloudNativePG Grafana dashboard (ID `20417`) from grafana.com.

---

## Step 6: Promote a standby (manual failover)

Used when you need to perform maintenance on the current primary node.

```bash
# Trigger a switchover to a specific standby
kubectl cnpg promote postgres postgres-2 -n postgres

# Or let the operator choose the most up-to-date standby
kubectl cnpg promote postgres -n postgres
```

The old primary becomes a standby automatically. No data loss — the operator waits for WAL sync before switching.

---

## Useful commands

```bash
# Full cluster status: replication lag, WAL position, timeline
kubectl cnpg status postgres -n postgres

# Connect to primary directly
kubectl cnpg psql postgres -n postgres

# Connect to a specific standby (read-only)
kubectl cnpg psql postgres --replica -n postgres

# List all backups
kubectl get backup -n postgres

# Trigger a manual base backup immediately
kubectl cnpg backup postgres -n postgres

# Check slow queries (queries > 1s per log_min_duration_statement setting)
kubectl logs -l cnpg.io/cluster=postgres -n postgres | grep duration
```

---

## Disaster recovery: restore from backup

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-restored
  namespace: postgres
spec:
  instances: 3
  bootstrap:
    recovery:
      source: postgres-backup
      recoveryTarget:
        targetTime: "2026-05-08 03:00:00"   # PITR: restore to this exact moment
  externalClusters:
    - name: postgres-backup
      barmanObjectStore:
        destinationPath: s3://postgres-backups/
        endpointURL: http://minio.minio:9000
        s3Credentials:
          accessKeyId:
            name: s3-backup-creds
            key: ACCESS_KEY_ID
          secretAccessKey:
            name: s3-backup-creds
            key: SECRET_ACCESS_KEY
  storage:
    storageClass: longhorn
    size: 20Gi
```

This creates a separate cluster named `postgres-restored` — it does not touch the running cluster. Validate data, then cut over application connection strings.

---

## Summary: scaling path

```
instances: 1          →  no HA, no failover (current)
instances: 3          →  streaming replication, automatic failover (~30s RTO)
instances: 3 + backup →  PITR, disaster recovery from any point in time
instances: 3 + PodMonitor → full observability in Grafana
```

Each step is a one-field change applied with `kubectl apply`. No cluster recreation required at any stage.
