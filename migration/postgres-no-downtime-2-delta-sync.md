# No-Downtime PostgreSQL Migration: Delta Sync Strategy

Migrating from an old PostgreSQL instance to a new one without downtime requires a bulk-copy phase followed by a delta catch-up phase before the final cutover. This doc covers the delta phase — syncing the rows that changed or arrived while the bulk copy was running.

---

## Overview

```
Old DB ──── bulk copy ────► New DB
  │                            │
  └── CDC / delta tracking ────┘
            │
        cutover swap
```

### Phases

| Phase           | What Happens                                         |
| --------------- | ---------------------------------------------------- |
| 1. Prep         | Enable WAL-level logical replication on old DB       |
| 2. Bulk copy    | `pg_dump` or `COPY` snapshot into new DB             |
| 3. Delta replay | Stream / apply changes that arrived during bulk copy |
| 4. Lag zero     | Wait until replication lag reaches 0                 |
| 5. Cutover      | Re-point app to new DB; drop replication slot        |

---

## Prerequisites

Old DB (`postgresql.conf`):

```ini
wal_level = logical
max_replication_slots = 5
max_wal_senders = 5
```

Apply and reload (no restart needed for `max_replication_slots` / `max_wal_senders` on PostgreSQL 10+, but `wal_level` requires a restart if not already `logical`):

```sql
-- check current level
SHOW wal_level;

-- if already logical, no restart needed
SELECT pg_reload_conf();
```

Old DB `pg_hba.conf` — allow replication from new DB host:

```
host replication replicator <new-db-ip>/32 scram-sha-256
```

Create a dedicated replication user on the old DB:

```sql
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'strong_password';
-- grant SELECT on all tables for initial snapshot
GRANT SELECT ON ALL TABLES IN SCHEMA public TO replicator;
```

---

## Phase 1 — Create a Logical Replication Slot Before Bulk Copy

Creating the slot **before** the dump guarantees the WAL stream is preserved from the exact LSN the dump started at. Without this, delta rows written during the dump are lost.

```sql
-- Run on old DB
SELECT pg_create_logical_replication_slot('migration_slot', 'pgoutput');

-- Note the confirmed_flush_lsn — keep it
SELECT slot_name, confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name = 'migration_slot';
```

---

## Phase 2 — Bulk Copy (Snapshot)

Use `pg_dump` with the slot's snapshot so the dump and the WAL slot are consistent:

```bash
# Get the snapshot name tied to the slot
psql -h old-db-host -U replicator -d mydb \
  -c "SELECT pg_export_snapshot();"
# returns something like: 00000003-0000001B-1

# Dump using that snapshot
pg_dump \
  --snapshot=00000003-0000001B-1 \
  -h old-db-host -U replicator -d mydb \
  -Fc -f /tmp/mydb_bulk.dump

# Restore into new DB
pg_restore \
  -h new-db-host -U postgres -d mydb \
  --no-owner --no-acl \
  /tmp/mydb_bulk.dump
```

> If `pg_export_snapshot()` is not used (e.g. you used `pg_dump` without `--snapshot`), the slot still works but you may replay a small number of duplicate rows — your upsert strategy in Phase 3 handles this safely.

---

## Phase 3 — Delta Catch-Up via Logical Replication

### Option A — Native `pg_logical` / `pgoutput` (PostgreSQL 10+)

Set up a publication on the old DB:

```sql
-- Old DB: publish all tables
CREATE PUBLICATION migration_pub FOR ALL TABLES;
```

Set up the subscription on the new DB, pointing at the existing slot:

```sql
-- New DB
CREATE SUBSCRIPTION migration_sub
  CONNECTION 'host=old-db-host port=5432 dbname=mydb user=replicator password=strong_password'
  PUBLICATION migration_pub
  WITH (
    copy_data = false,          -- bulk data already loaded
    create_slot = false,        -- use the slot we already created
    slot_name = 'migration_slot'
  );
```

Monitor lag:

```sql
-- New DB: check replication lag (bytes behind)
SELECT
  subname,
  received_lsn,
  latest_end_lsn,
  (latest_end_lsn - received_lsn) AS lag_bytes
FROM pg_stat_subscription;

-- Old DB: check slot retention (how much WAL is held)
SELECT slot_name, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS retained_wal
FROM pg_replication_slots
WHERE slot_name = 'migration_slot';
```

### Option B — pglogical Extension (PostgreSQL 9.4–9.6 or cross-version)

Install on both nodes:

```bash
# RHEL / Rocky
dnf install -y pglogical_14   # match your PG major version
```

```sql
-- Old DB
CREATE EXTENSION pglogical;
SELECT pglogical.create_node(node_name := 'provider', dsn := 'host=old-db-host dbname=mydb user=replicator');
SELECT pglogical.create_replication_set('migration_set');
SELECT pglogical.replication_set_add_all_tables('migration_set', ARRAY['public']);

-- New DB
CREATE EXTENSION pglogical;
SELECT pglogical.create_node(node_name := 'subscriber', dsn := 'host=new-db-host dbname=mydb user=postgres');
SELECT pglogical.create_subscription(
  subscription_name := 'migration_sub',
  provider_dsn := 'host=old-db-host dbname=mydb user=replicator password=strong_password',
  replication_sets := ARRAY['migration_set'],
  synchronize_data := false   -- bulk data already loaded
);
```

---

## Phase 4 — Wait for Lag to Reach Zero

Do not cut over until the subscriber has fully caught up. Poll until `lag_bytes = 0` and the LSN values match:

```sql
-- New DB: loop until caught up
SELECT
  subname,
  received_lsn = latest_end_lsn AS caught_up,
  (latest_end_lsn - received_lsn) AS lag_bytes
FROM pg_stat_subscription;
```

You can also compare table row counts as a sanity check:

```bash
# Row count on old DB
psql -h old-db-host -U replicator -d mydb \
  -c "SELECT schemaname, relname, n_live_tup FROM pg_stat_user_tables ORDER BY relname;"

# Row count on new DB
psql -h new-db-host -U postgres -d mydb \
  -c "SELECT schemaname, relname, n_live_tup FROM pg_stat_user_tables ORDER BY relname;"
```

---

## Phase 5 — Cutover

1. **Put the app in read-only mode** (feature flag, load-balancer drain, or connection-level):

   ```sql
   -- Old DB: prevent new writes temporarily (seconds, not minutes)
   REVOKE INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public FROM app_user;
   ```

2. **Wait for the final lag to flush** — recheck `lag_bytes = 0`.

3. **Re-point the app** to the new DB host (update `DATABASE_URL`, Kubernetes `ConfigMap`, or HAProxy backend).

4. **Re-grant write permissions** on the new DB if needed:

   ```sql
   -- New DB
   GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_user;
   ```

5. **Drop the subscription and slot**:

   ```sql
   -- New DB
   DROP SUBSCRIPTION migration_sub;

   -- Old DB
   SELECT pg_drop_replication_slot('migration_slot');
   DROP PUBLICATION migration_pub;
   ```

---

## Handling Conflicts During Delta Replay

Logical replication can encounter conflicts when a row from the WAL already exists in the new DB (e.g. from the bulk copy). Common causes and fixes:

| Conflict type           | Cause                                  | Fix                                                                                                        |
| ----------------------- | -------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Duplicate key on INSERT | Row in bulk dump + same INSERT in WAL  | Use `ON CONFLICT DO NOTHING` trigger or `pglogical.replication_set` conflict resolution `last_update_wins` |
| UPDATE on missing row   | Row not in bulk dump but UPDATE in WAL | Pre-seed with `copy_data = true` or ignore with `skip` conflict action                                     |
| Sequence out of sync    | Sequences not replicated               | Manually sync sequences after cutover (see below)                                                          |

### Sync sequences after cutover

```sql
-- Run on new DB after cutover
DO $$
DECLARE
  rec RECORD;
  max_val BIGINT;
BEGIN
  FOR rec IN
    SELECT sequence_schema, sequence_name, table_name, column_name
    FROM information_schema.sequences
    JOIN information_schema.columns
      ON column_default LIKE '%' || sequence_name || '%'
  LOOP
    EXECUTE format(
      'SELECT COALESCE(MAX(%I), 0) FROM %I.%I',
      rec.column_name, rec.sequence_schema, rec.table_name
    ) INTO max_val;
    EXECUTE format(
      'SELECT setval(''%I.%I'', %s)',
      rec.sequence_schema, rec.sequence_name, max_val + 1
    );
  END LOOP;
END $$;
```

---

## Rollback Plan

If the cutover fails, revert by:

1. Re-pointing the app back to the old DB (already running, slot still present until dropped).
2. Re-granting writes on the old DB:
   ```sql
   GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_user;
   ```
3. The replication slot on the old DB will have accumulated WAL during the failed cutover window. Resume or discard the new DB and start a fresh delta catch-up if you want to retry.

---

## Checklist

- [ ] `wal_level = logical` on old DB; restarted if changed
- [ ] Replication slot created **before** bulk dump
- [ ] Bulk dump + restore completed successfully
- [ ] Publication and subscription created; `copy_data = false`
- [ ] Replication lag confirmed at 0 before cutover
- [ ] App writes revoked on old DB during cutover window
- [ ] App re-pointed to new DB
- [ ] Sequences synced on new DB
- [ ] Replication slot and publication dropped on old DB
- [ ] Old DB decommissioned after validation period
