# Postgres Production Readiness

Things that must be addressed before Postgres is genuinely production-ready, beyond the cluster CR and scaling setup.

---

## 1. Connection Pooling (PgBouncer)

Postgres creates a backend OS process per connection. At high concurrency this becomes the bottleneck — not the database itself. Without pooling, 200 app pods × 10 connections each = 2000 connections, each consuming ~5–10 MB of memory and a file descriptor.

CloudNativePG ships a first-class `Pooler` CR backed by PgBouncer:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: postgres-pooler-rw
  namespace: postgres
spec:
  cluster:
    name: postgres
  instances: 2              # pooler pods, not DB instances
  type: rw                  # rw = primary only; ro = standbys only

  pgbouncer:
    poolMode: transaction   # transaction mode: best for most web/API workloads
    parameters:
      max_client_conn: "1000"
      default_pool_size: "25"   # connections from pooler → postgres
      reserve_pool_size: "5"
      reserve_pool_timeout: "3"
      log_connections: "0"
      log_disconnections: "0"

  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi
```

Apply alongside the cluster CR:
```bash
kubectl apply -f pooler.yaml -n postgres
```

The operator creates a `postgres-pooler-rw` Service. Point your applications at this service, not at the cluster service directly.

### Pool mode choice

| Mode        | Use when                                                        | Caveat                                      |
| ----------- | --------------------------------------------------------------- | ------------------------------------------- |
| transaction | Most web/API apps (short queries, no session state)             | Cannot use `SET`, `LISTEN`, prepared stmts  |
| session     | Apps that rely on session-level settings or advisory locks      | Less efficient; one server conn per client  |
| statement   | Rarely used; single-statement transactions only                 | Very restrictive                            |

---

## 2. Services and Read/Write Splitting

CloudNativePG creates three services automatically:

| Service               | Target         | Use for                          |
| --------------------- | -------------- | -------------------------------- |
| `postgres-rw`         | Primary only   | All writes, read-after-write     |
| `postgres-ro`         | Standbys only  | Read-heavy queries, reporting    |
| `postgres-r`          | Any instance   | Not recommended — unpredictable  |

Route read-heavy workloads (reporting, analytics, search) to `postgres-ro`. This offloads the primary and makes standby capacity useful.

If using the PgBouncer pooler, create a second `Pooler` with `type: ro` for read replicas:
```yaml
metadata:
  name: postgres-pooler-ro
spec:
  type: ro
  pgbouncer:
    poolMode: transaction
    parameters:
      default_pool_size: "20"
```

---

## 3. Schema Migrations

Never run migrations from application startup code in a multi-replica deployment — all replicas race to run the same migration simultaneously.

**Recommended pattern:** a dedicated migration job that runs before the application deployment:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
  namespace: app
spec:
  backoffLimit: 3
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: migrate
          image: your-app:latest
          command: ["flyway", "migrate"]   # or liquibase, golang-migrate, etc.
          env:
            - name: FLYWAY_URL
              value: jdbc:postgresql://postgres-rw.postgres:5432/app
            - name: FLYWAY_USER
              valueFrom:
                secretKeyRef:
                  name: postgres-app-secret
                  key: username
            - name: FLYWAY_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-app-secret
                  key: password
```

Run this Job in CI before updating the application Deployment. Use `flyway migrate` or equivalent — never `flyway clean` in production.

### Safe migration rules

- Always use `ADD COLUMN` with a default rather than `ADD COLUMN NOT NULL` without one — the latter rewrites the entire table on Postgres < 11 and takes an `AccessExclusiveLock`
- Drop columns in a separate migration after the code no longer references them
- Add indexes with `CREATE INDEX CONCURRENTLY` — this does not lock the table
- Never rename a column without a multi-step migration (add new column → backfill → switch app → drop old column)

---

## 4. Autovacuum Tuning

The default autovacuum settings are conservative — designed for small tables. On large tables they fall behind, causing table bloat and query plan degradation.

Add to `postgresql.parameters` in the cluster CR:

```yaml
postgresql:
  parameters:
    # More aggressive autovacuum for busy tables
    autovacuum_vacuum_scale_factor: "0.01"    # vacuum when 1% of rows are dead (default 20%)
    autovacuum_analyze_scale_factor: "0.005"  # analyze when 0.5% of rows change (default 10%)
    autovacuum_vacuum_cost_delay: "2ms"       # less throttling (default 20ms)
    autovacuum_max_workers: "5"               # more parallel workers (default 3)
    # Prevent transaction ID wraparound (the worst kind of outage)
    autovacuum_freeze_max_age: "200000000"
```

For specific high-write tables, override per-table (run in psql after deploy):
```sql
ALTER TABLE events SET (
  autovacuum_vacuum_scale_factor = 0.01,
  autovacuum_analyze_scale_factor = 0.005
);
```

Monitor table bloat with:
```sql
SELECT schemaname, tablename,
       pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
       n_dead_tup, n_live_tup,
       round(100 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 2) AS dead_pct
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC
LIMIT 20;
```

---

## 5. Query Observability (pg_stat_statements)

Enable `pg_stat_statements` — it is the single most useful tool for diagnosing slow queries and understanding database load:

```yaml
postgresql:
  parameters:
    shared_preload_libraries: "pg_stat_statements"
    pg_stat_statements.max: "10000"
    pg_stat_statements.track: "all"
    track_io_timing: "on"   # adds I/O wait time to query stats
```

After the cluster restarts, create the extension once:
```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

Find the top 10 slowest queries by total time:
```sql
SELECT query, calls, total_exec_time, mean_exec_time,
       rows, shared_blks_hit, shared_blks_read
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;
```

Reset stats after a tuning change:
```sql
SELECT pg_stat_statements_reset();
```

---

## 6. TLS and Network Policy

By default CloudNativePG enables TLS on all connections between pods (intra-cluster). For application connections, enforce TLS at the pooler or cluster service level.

Restrict which pods can reach Postgres with a NetworkPolicy — this is especially important on a shared cluster:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgres-ingress
  namespace: postgres
spec:
  podSelector:
    matchLabels:
      cnpg.io/cluster: postgres
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: app    # only the app namespace
      ports:
        - port: 5432
        - port: 5433   # PgBouncer pooler port
```

---

## 7. Credential Rotation

Do not use a single shared password forever. Rotate the app user password without downtime:

```bash
# 1. Create a new secret with the new password
kubectl create secret generic postgres-app-secret-v2 \
  --from-literal=username=app \
  --from-literal=password="<new-password>" \
  -n postgres

# 2. Update the cluster CR to reference the new secret
# bootstrap.initdb.secret.name: postgres-app-secret-v2

# 3. Update the password in Postgres directly (operator will sync on next reconcile)
kubectl cnpg psql postgres -n postgres -- \
  -c "ALTER USER app PASSWORD '<new-password>';"

# 4. Update application secrets to use the new password

# 5. Delete the old secret after confirming applications are healthy
kubectl delete secret postgres-app-secret -n postgres
```

---

## 8. Major Version Upgrade

CloudNativePG does not support in-place major version upgrades (e.g. PG 15 → 16). The safe path is logical replication:

1. Spin up a new `Cluster` CR with `imageName: .../postgresql:17` and `instances: 1`
2. Set up logical replication from old cluster to new (using `pg_logical` or `pglogical` extension)
3. Once new cluster is caught up, update application connection strings to the new cluster service
4. Promote and decommission the old cluster

For minor versions (16.3 → 16.4), update `imageName` in the CR and apply — the operator handles a rolling restart automatically.

---

## 9. Backup Verification

A backup that has never been tested is not a backup. Schedule a monthly restore drill:

```bash
# Restore to a test namespace from the most recent backup
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-drill
  namespace: postgres-test
spec:
  instances: 1
  bootstrap:
    recovery:
      source: postgres-backup
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
EOF

# Verify row counts / key tables match production
kubectl cnpg psql postgres-drill -n postgres-test -- \
  -c "SELECT COUNT(*) FROM your_key_table;"

# Tear down after verification
kubectl delete cluster postgres-drill -n postgres-test
```

---

## Production readiness checklist

| Item | Done |
| ---- | ---- |
| `instances: 3` with streaming replication | [ ] |
| PgBouncer pooler deployed (`type: rw`) | [ ] |
| Read replica pooler deployed (`type: ro`) for heavy reads | [ ] |
| WAL archiving + `ScheduledBackup` CR active | [ ] |
| Backup restore drill completed and verified | [ ] |
| `pg_stat_statements` enabled | [ ] |
| Autovacuum tuned for table sizes | [ ] |
| NetworkPolicy restricting ingress to postgres namespace | [ ] |
| App connects via pooler service, not cluster service directly | [ ] |
| Schema migrations run as a pre-deploy Job, not app startup | [ ] |
| Grafana dashboard (ID 20417) imported and alerting configured | [ ] |
| Credential rotation procedure documented and tested | [ ] |
