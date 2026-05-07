# No-Downtime PostgreSQL Migration: Pre-Delta Phase

This doc covers everything that must be done **before** the delta sync phase begins. It is the companion to `postgres-no-downtime-2-delta-sync.md`, which covers delta catch-up and cutover.

---

## Full Migration Sequence

```
[1. Assess]──►[2. Provision New DB]──►[3. Schema Migration]──►[4. Prep Old DB]──►[5. Bulk Copy]
                                                                                        │
                                                                              ► delta sync (see other doc)
```

---

## Phase 1 — Assessment

Before touching anything, capture a baseline of the old DB.

### Version and extensions

```sql
-- PostgreSQL version
SELECT version();

-- Installed extensions
SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE installed_version IS NOT NULL
ORDER BY name;
```

### Database size

```sql
-- Per-database size
SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size
FROM pg_database
ORDER BY pg_database_size(datname) DESC;

-- Per-table size (top 20)
SELECT
  schemaname,
  relname,
  pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
  pg_size_pretty(pg_relation_size(relid)) AS table_size,
  pg_size_pretty(pg_indexes_size(relid)) AS index_size,
  n_live_tup AS row_count
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 20;
```

### Active connections and workload

```sql
-- Connection count by user/app
SELECT usename, application_name, COUNT(*) AS connections
FROM pg_stat_activity
WHERE state != 'idle'
GROUP BY usename, application_name
ORDER BY connections DESC;

-- Long-running queries (potential blockers during cutover)
SELECT pid, now() - query_start AS duration, query, state
FROM pg_stat_activity
WHERE state != 'idle' AND query_start < now() - INTERVAL '5 minutes'
ORDER BY duration DESC;
```

### WAL and replication readiness

```sql
SHOW wal_level;           -- must be 'logical' or plan a restart
SHOW max_replication_slots;
SHOW max_wal_senders;
```

### Sequences — capture current values for later sync

```sql
SELECT
  n.nspname AS schema,
  c.relname AS sequence_name,
  t.relname AS table_name,
  a.attname AS column_name
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_depend d ON d.objid = c.oid AND d.deptype = 'a'
JOIN pg_class t ON t.oid = d.refobjid
JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = d.refobjsubid
WHERE c.relkind = 'S'
ORDER BY schema, table_name;
```

### Tables without primary keys (logical replication requirement)

Logical replication requires every replicated table to have a primary key (or `REPLICA IDENTITY FULL` as a fallback).

```sql
-- Find tables without primary keys
SELECT n.nspname AS schema, c.relname AS table_name
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND NOT EXISTS (
    SELECT 1 FROM pg_constraint k
    WHERE k.conrelid = c.oid AND k.contype = 'p'
  )
ORDER BY schema, table_name;
```

Fix by adding a primary key or setting `REPLICA IDENTITY FULL`:

```sql
-- Preferred: add a primary key
ALTER TABLE public.event_log ADD PRIMARY KEY (id);

-- Fallback: replicate full row (slower, use only if schema cannot change)
ALTER TABLE public.event_log REPLICA IDENTITY FULL;
```

---

## Phase 2 — Provision the New PostgreSQL Instance

### Version target

Match the major version of the old DB or go one major version higher. Cross-major-version logical replication is supported (e.g. PG 14 → PG 16) but test it in a staging environment first.

```bash
# Docker Compose example — place in docker-composes/databases/postgres-new.yaml
services:
  postgres-new:
    image: postgres:16
    container_name: postgres-new
    restart: unless-stopped
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: mydb
    volumes:
      - postgres_new_data:/var/lib/postgresql/data
    ports:
      - "5433:5432"   # different host port to avoid collision with old instance

volumes:
  postgres_new_data:
```

### `postgresql.conf` on new DB

```ini
# Must also be logical on the subscriber side when using pglogical
wal_level = logical
max_connections = 200

# Performance — tune to your hardware
shared_buffers = 4GB
effective_cache_size = 12GB
maintenance_work_mem = 1GB
checkpoint_completion_target = 0.9
wal_buffers = 64MB
default_statistics_target = 100
random_page_cost = 1.1       # for SSD
work_mem = 64MB
```

### Create the target database and roles

```sql
-- On new DB
CREATE DATABASE mydb;

-- Recreate application roles (match old DB exactly)
CREATE ROLE app_user WITH LOGIN PASSWORD 'app_password';
CREATE ROLE readonly_user WITH LOGIN PASSWORD 'readonly_password';
```

### Test connectivity from old DB host to new DB host

```bash
psql -h new-db-host -p 5432 -U postgres -d mydb -c "SELECT 1;"
```

---

## Phase 3 — Schema Migration

Migrate schema **before** data so that `pg_restore` and logical replication have valid targets.

### Export schema-only from old DB

```bash
pg_dump \
  -h old-db-host -U postgres -d mydb \
  --schema-only \
  --no-owner --no-acl \
  -Fp -f /tmp/mydb_schema.sql
```

### Review and apply schema on new DB

```bash
psql -h new-db-host -U postgres -d mydb -f /tmp/mydb_schema.sql
```

### Verify schema parity

```bash
# Diff table definitions between old and new
psql -h old-db-host -U postgres -d mydb \
  -c "\d+ public.*" > /tmp/schema_old.txt

psql -h new-db-host -U postgres -d mydb \
  -c "\d+ public.*" > /tmp/schema_new.txt

diff /tmp/schema_old.txt /tmp/schema_new.txt
```

### Apply any pending schema changes now

If the new DB needs schema changes (new columns, dropped constraints), apply them **on the new DB only** before bulk copy. Do not alter the old DB schema during migration — it risks breaking the running application.

```sql
-- Example: new column with a default (safe to add on new DB before bulk copy)
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS processed_at TIMESTAMPTZ DEFAULT NULL;
```

> Columns added to the new DB with `DEFAULT NULL` are safe — the bulk copy and replication will simply leave them NULL until the app starts writing to the new DB.

---

## Phase 4 — Prepare the Old DB for Logical Replication

### Enable logical WAL (restart required if `wal_level` is not already `logical`)

```sql
-- Check
SHOW wal_level;
```

If it returns `replica` or `minimal`, update `postgresql.conf`:

```ini
wal_level = logical
max_replication_slots = 5
max_wal_senders = 5
```

Then restart PostgreSQL:

```bash
# systemd
systemctl restart postgresql-14

# Docker
docker-compose restart postgres-old
```

> Restarting the old DB is the **only** brief service interruption in the entire process. It takes 5–30 seconds. Schedule it during low-traffic hours. Everything after this point is truly zero-downtime.

### Allow replication connections in `pg_hba.conf`

```
# TYPE   DATABASE    USER         ADDRESS              METHOD
host     replication replicator   <new-db-ip>/32       scram-sha-256
```

Reload:

```bash
psql -h old-db-host -U postgres -c "SELECT pg_reload_conf();"
```

### Create the replication user

```sql
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'strong_password';
GRANT SELECT ON ALL TABLES IN SCHEMA public TO replicator;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO replicator;
```

### Verify the replication user can connect

```bash
psql -h old-db-host -U replicator -d mydb -c "SELECT current_user;"
```

---

## Phase 5 — Create the Replication Slot (Before Bulk Copy)

This is the critical step that ties the WAL start position to the bulk copy snapshot. **Do this immediately before starting `pg_dump`** — the slot holds WAL from this point forward.

```sql
-- On old DB
SELECT pg_create_logical_replication_slot('migration_slot', 'pgoutput');

-- Capture and record these values
SELECT slot_name, lsn, snapshot_name
FROM pg_create_logical_replication_slot('migration_slot', 'pgoutput')
-- Note: above creates a NEW slot. If slot already exists, just query:
SELECT slot_name, confirmed_flush_lsn, restart_lsn
FROM pg_replication_slots
WHERE slot_name = 'migration_slot';
```

Export the snapshot tied to the slot — use this name in Phase 6 with `pg_dump --snapshot`:

```sql
-- In the same session that created the slot (do not disconnect)
SELECT pg_export_snapshot();
-- Returns: 00000003-0000001B-1  (use this in pg_dump --snapshot)
```

> **Important:** `pg_export_snapshot()` must be called in the **same connection** that created the slot, before that connection closes. Open a second `psql` session to run `pg_dump --snapshot` while keeping this connection alive.

---

## Phase 6 — Bulk Copy

With the replication slot and snapshot in place, perform the full data copy.

### Option A — pg_dump / pg_restore (recommended for most cases)

```bash
# Terminal 1: keep the slot connection open (from Phase 5)
# Terminal 2: run the dump

pg_dump \
  --snapshot=00000003-0000001B-1 \
  -h old-db-host -U replicator -d mydb \
  -Fc \
  --no-owner --no-acl \
  --exclude-table-data='*.audit_log' \   # optionally skip large low-priority tables
  -f /tmp/mydb_bulk.dump

# Restore to new DB
pg_restore \
  -h new-db-host -U postgres -d mydb \
  --no-owner --no-acl \
  -j 4 \                                 # parallel jobs — match CPU count
  /tmp/mydb_bulk.dump
```

### Option B — COPY via psql pipe (faster for very large DBs on same network)

```bash
# Stream table-by-table without a dump file
for table in $(psql -h old-db-host -U postgres -d mydb -Atc \
  "SELECT tablename FROM pg_tables WHERE schemaname='public'"); do
  psql -h old-db-host -U replicator -d mydb \
    -c "COPY public.$table TO STDOUT" | \
  psql -h new-db-host -U postgres -d mydb \
    -c "COPY public.$table FROM STDIN"
done
```

> Option B does not use the snapshot — use it only if the slot is already created and you accept replaying a small number of duplicate rows (the subscription's upsert/skip logic handles them).

### Verify bulk copy row counts

```bash
psql -h old-db-host -U postgres -d mydb \
  -c "SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY relname;" \
  > /tmp/rowcount_old.txt

psql -h new-db-host -U postgres -d mydb \
  -c "SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY relname;" \
  > /tmp/rowcount_new.txt

diff /tmp/rowcount_old.txt /tmp/rowcount_new.txt
```

Counts will differ slightly — that is expected and correct. Rows written to the old DB after the snapshot LSN are queued in the WAL slot and will be applied during delta sync.

---

## Pre-Delta Readiness Checklist

- [ ] Old DB assessed: version, extensions, sizes, table PKs documented
- [ ] Tables without PKs fixed (`ADD PRIMARY KEY` or `REPLICA IDENTITY FULL`)
- [ ] New DB provisioned with matching or target version
- [ ] Schema applied to new DB; diff shows no unexpected differences
- [ ] `wal_level = logical` on old DB (restarted if changed)
- [ ] Replication user created and connectivity verified
- [ ] `pg_hba.conf` updated and reloaded
- [ ] Replication slot `migration_slot` created
- [ ] Snapshot name captured (`pg_export_snapshot()`)
- [ ] Bulk copy completed and row counts verified
- [ ] Old DB connection holding the snapshot still open (or dump already running)

---

## Next Step

Proceed to `postgres-no-downtime-2-delta-sync.md` — Phase 3 (Delta Catch-Up) onwards.
