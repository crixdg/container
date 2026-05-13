#!/bin/bash

# Cutover script for Phase 1 → Phase 2 Redis migration.
#
# Preconditions (must be true before running this script):
#   1. redis-replication-0 is already replicating from redis-0
#      (you ran: redis-cli REPLICAOF redis.redis.svc.cluster.local 6379 on redis-replication-0)
#   2. Initial bulk sync is complete (master_sync_in_progress = 0)
#
# What this script does:
#   - Pauses writes on the old master (CLIENT PAUSE WRITE) — reads keep working
#   - CLIENT PAUSE queues in-flight writes rather than rejecting them; they wait
#   - Waits for the replica to drain the replication backlog (WAIT)
#   - Promotes the new master (REPLICAOF NO ONE)
#   - Verifies key count matches
#   - Does NOT call CLIENT UNPAUSE — the pause is left to expire or the pod deleted
#
# Why no UNPAUSE:
#   Writes queued during PAUSE that execute after UNPAUSE would land on the old
#   master only (new master is already independent). Keeping the pause forces clients
#   to get a connection reset when the old pod is deleted, so they reconnect via
#   Sentinel to the new master and retry — no silent data loss.
#
# Typical client-visible pause: 1–3 seconds.

set -euo pipefail

NAMESPACE="${NAMESPACE:-redis}"
OLD_POD="redis-0"
NEW_POD="redis-replication-0"
PAUSE_MS=10000   # safety ceiling; pod should be deleted before this expires
WAIT_TIMEOUT=5000

kexec() {
  kubectl exec -n "$NAMESPACE" "$1" -- redis-cli "${@:2}"
}

echo "==> Checking replication status on $NEW_POD..."
SYNC_IN_PROGRESS=$(kexec "$NEW_POD" info replication | grep "master_sync_in_progress" | tr -d '[:space:]' | cut -d: -f2)
if [ "${SYNC_IN_PROGRESS:-1}" != "0" ]; then
  echo "ERROR: Initial bulk sync is still in progress. Wait for it to finish before cutting over."
  echo "       Run: kubectl exec -n $NAMESPACE $NEW_POD -- redis-cli info replication | grep master_sync"
  exit 1
fi

OLD_KEYS=$(kexec "$OLD_POD" DBSIZE | tr -d '[:space:]')
echo "    Old master key count: $OLD_KEYS"

echo ""
echo "==> Pausing writes on old master ($OLD_POD) for up to ${PAUSE_MS}ms..."
# CLIENT PAUSE WRITE queues (not rejects) write commands. Reads keep working.
# In-flight writes from lagging clients arrive and are held in the queue.
# The replica continues draining the replication stream during this window.
kexec "$OLD_POD" CLIENT PAUSE "$PAUSE_MS" WRITE > /dev/null

PAUSE_START=$(date +%s%3N)

echo "==> Waiting for $NEW_POD to drain replication backlog (WAIT 1 ${WAIT_TIMEOUT}ms)..."
# WAIT blocks until 1 replica has acknowledged all pending writes, or timeout.
SYNCED=$(kexec "$OLD_POD" WAIT 1 "$WAIT_TIMEOUT")
PAUSE_END=$(date +%s%3N)
ELAPSED=$(( PAUSE_END - PAUSE_START ))

if [ "$SYNCED" -lt 1 ]; then
  echo "ERROR: Replica did not fully sync within ${WAIT_TIMEOUT}ms (WAIT returned $SYNCED)."
  echo "       Unpausing old master — no changes made."
  kexec "$OLD_POD" CLIENT UNPAUSE > /dev/null
  exit 1
fi

echo "    Replica in sync after ${ELAPSED}ms."

echo ""
echo "==> Promoting $NEW_POD to master..."
kexec "$NEW_POD" REPLICAOF NO ONE > /dev/null
# Old master remains paused — intentional. Any writes queued during PAUSE would land
# on the old master only after UNPAUSE (new master is already independent). Keeping
# the pause forces clients to get a connection reset on pod deletion, not silent loss.

echo ""
echo "==> Verifying key counts..."
NEW_KEYS=$(kexec "$NEW_POD" DBSIZE | tr -d '[:space:]')
echo "    Old master: $OLD_KEYS keys"
echo "    New master: $NEW_KEYS keys"

if [ "$OLD_KEYS" != "$NEW_KEYS" ]; then
  echo "WARNING: Key counts differ. This can happen if TTL expiry ran between checks — verify manually."
  echo "         Run: kubectl exec -n $NAMESPACE $NEW_POD -- redis-cli info keyspace"
else
  echo "    Key counts match."
fi

echo ""
echo "==> Done. Replica in sync after ${ELAPSED}ms."
echo ""
echo "Next steps (complete in order — old master is still paused):"
echo "  1. Update your app's Redis connection to Sentinel:"
echo "       host: redis-sentinel.$NAMESPACE.svc.cluster.local"
echo "       port: 26379"
echo "       master-name: mymaster"
echo ""
echo "  2. Delete the old standalone CR promptly (before the ${PAUSE_MS}ms pause expires):"
echo "       kubectl delete redis redis -n $NAMESPACE"
echo "     Deleting the pod resets queued client connections → they reconnect via"
echo "     Sentinel to the new master and retry. No silent data loss."
