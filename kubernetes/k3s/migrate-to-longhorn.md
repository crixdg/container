# Migrating from local-path to Longhorn

local-path stores data directly on one node's filesystem with no replication. Longhorn provides replicated block volumes with snapshots and backup. Existing PVCs cannot be moved between storage classes in-place — each one must be migrated by copying its data into a new Longhorn volume.

**Estimated time:** 10–30 minutes per PVC depending on data size.

---

## Before you start

- [ ] Longhorn is installed and healthy (`bash helm/longhorn/install.sh`)
- [ ] All Longhorn pods are Running: `kubectl get pods -n storage-controller`
- [ ] You have `kubectl` access with cluster-admin privileges
- [ ] You have identified all workloads using local-path PVCs (step 1 below)

---

## Step 1 — Inventory existing local-path PVCs

List every PVC that uses the `local-path` storage class:

```bash
kubectl get pvc -A -o wide | grep local-path
```

For each namespace, list which workload owns the PVC:

```bash
# Replace <namespace> with your target namespace
kubectl get pods -n <namespace> -o json \
  | jq -r '.items[] | .metadata.name as $pod
    | .spec.volumes[]?
    | select(.persistentVolumeClaim != null)
    | [$pod, .persistentVolumeClaim.claimName] | @tsv'
```

Save the output — you will work through each PVC one at a time.

---

## Step 2 — Set Longhorn as the default StorageClass

Remove the `default` annotation from local-path and set it on Longhorn so that new PVCs that do not specify a storage class go to Longhorn automatically.

```bash
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'

kubectl patch storageclass longhorn \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

Verify:

```bash
kubectl get storageclass
# longhorn should show (default), local-path should not
```

> New PVCs from this point on will use Longhorn. Existing PVCs are unchanged until migrated.

---

## Step 3 — Migrate each PVC

Repeat the steps below for every PVC found in step 1. Replace the placeholders:

| Placeholder | Meaning |
|-------------|---------|
| `<namespace>` | Namespace of the workload |
| `<old-pvc>` | Name of the existing local-path PVC |
| `<new-pvc>` | Name you will give the new Longhorn PVC |
| `<size>` | Same size as the old PVC (or larger) |
| `<workload>` | Deployment / StatefulSet name |

### 3a — Note the old PVC size

```bash
kubectl get pvc <old-pvc> -n <namespace> \
  -o jsonpath='{.spec.resources.requests.storage}'
```

### 3b — Scale the workload to zero

Data must not be written during the copy.

```bash
kubectl scale deployment <workload> --replicas=0 -n <namespace>
# For a StatefulSet:
# kubectl scale statefulset <workload> --replicas=0 -n <namespace>

# Wait until all pods are terminated
kubectl wait pod -l app=<workload> -n <namespace> \
  --for=delete --timeout=120s
```

### 3c — Create the new Longhorn PVC

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <new-pvc>
  namespace: <namespace>
spec:
  storageClassName: longhorn
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: <size>
EOF
```

Wait for the new PVC to be bound:

```bash
kubectl wait pvc <new-pvc> -n <namespace> \
  --for=jsonpath='{.status.phase}'=Bound --timeout=60s
```

### 3d — Copy data with a migration pod

This pod mounts both volumes and copies all data from old to new using `rsync`.

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: pvc-migrator
  namespace: <namespace>
spec:
  restartPolicy: Never
  containers:
    - name: migrator
      image: alpine
      command:
        - sh
        - -c
        - |
          apk add --no-cache rsync && \
          rsync -avh --progress /source/ /dest/ && \
          echo "Migration complete."
      volumeMounts:
        - name: source
          mountPath: /source
        - name: dest
          mountPath: /dest
  volumes:
    - name: source
      persistentVolumeClaim:
        claimName: <old-pvc>
    - name: dest
      persistentVolumeClaim:
        claimName: <new-pvc>
EOF
```

Follow the copy progress:

```bash
kubectl logs -f pvc-migrator -n <namespace>
```

Wait for the pod to complete:

```bash
kubectl wait pod pvc-migrator -n <namespace> \
  --for=condition=Succeeded --timeout=30m
```

If the pod fails, inspect with:

```bash
kubectl describe pod pvc-migrator -n <namespace>
kubectl logs pvc-migrator -n <namespace>
```

### 3e — Delete the migration pod

```bash
kubectl delete pod pvc-migrator -n <namespace>
```

### 3f — Update the workload to use the new PVC

Edit the Deployment (or StatefulSet) and replace every reference to `<old-pvc>` with `<new-pvc>`:

```bash
kubectl edit deployment <workload> -n <namespace>
```

Find the `volumes` section and change `claimName`:

```yaml
volumes:
  - name: data
    persistentVolumeClaim:
      claimName: <new-pvc>   # was <old-pvc>
```

### 3g — Scale the workload back up

```bash
kubectl scale deployment <workload> --replicas=1 -n <namespace>

kubectl rollout status deployment/<workload> -n <namespace>
```

### 3h — Verify the workload is healthy

```bash
kubectl get pods -n <namespace>
kubectl logs -n <namespace> -l app=<workload> --tail=50
```

Check the application is reading data correctly before proceeding to the next PVC.

### 3i — Delete the old PVC

Only do this after confirming the workload is healthy.

```bash
kubectl delete pvc <old-pvc> -n <namespace>
```

> The underlying local-path PV will be released and deleted automatically.

---

## Step 4 — Verify all PVCs are on Longhorn

```bash
kubectl get pvc -A -o wide
# No PVC should show local-path in the STORAGECLASS column
```

Check Longhorn volume health in the UI or via CLI:

```bash
kubectl get volumes.longhorn.io -n storage-controller
# All volumes should show state=attached or state=detached (healthy)
```

---

## Step 5 — Disable local-path (optional)

Once all PVCs are migrated you can remove local-path entirely to prevent accidental use.

```bash
kubectl delete storageclass local-path
```

> **Note:** k3s re-creates the `local-path` StorageClass on restart. To prevent this permanently, add `--disable local-storage` to the k3s server flags (already set in `config.env` as `DISABLE_LOCAL_STORAGE=true` for new installs).

---

## Rollback

If anything goes wrong before you delete the old PVC:

1. Scale the workload back to zero.
2. Revert `claimName` in the Deployment back to `<old-pvc>`.
3. Scale back up.
4. Delete the failed `<new-pvc>` and retry from step 3c.

Data on the old PVC is untouched until step 3i.

---

## StatefulSet notes

StatefulSets manage their own PVCs via `volumeClaimTemplates`. The procedure is slightly different:

1. Scale the StatefulSet to zero replicas.
2. For each pod's PVC (e.g. `data-myapp-0`, `data-myapp-1`), follow steps 3b–3i above.
3. The StatefulSet cannot be edited to change `volumeClaimTemplates` in-place. Instead:
   - Delete the StatefulSet **without** deleting pods/PVCs: `kubectl delete statefulset <name> --cascade=orphan`
   - Re-apply the StatefulSet manifest with updated `volumeClaimTemplates` pointing to Longhorn.
   - The new PVCs will be created and the migrated data PVCs renamed to match the template name pattern.

---

## Quick reference — full migration for one PVC

```bash
NS=<namespace>
OLD=<old-pvc>
NEW=<new-pvc>
SIZE=<size>          # e.g. 5Gi
WORKLOAD=<workload>

# Scale down
kubectl scale deployment $WORKLOAD --replicas=0 -n $NS
kubectl wait pod -l app=$WORKLOAD -n $NS --for=delete --timeout=120s

# Create new PVC
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $NEW
  namespace: $NS
spec:
  storageClassName: longhorn
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: $SIZE
EOF

# Copy data
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: pvc-migrator
  namespace: $NS
spec:
  restartPolicy: Never
  containers:
    - name: migrator
      image: alpine
      command: [sh, -c, "apk add --no-cache rsync && rsync -avh /source/ /dest/ && echo done"]
      volumeMounts:
        - {name: source, mountPath: /source}
        - {name: dest,   mountPath: /dest}
  volumes:
    - {name: source, persistentVolumeClaim: {claimName: "$OLD"}}
    - {name: dest,   persistentVolumeClaim: {claimName: "$NEW"}}
EOF

kubectl wait pod pvc-migrator -n $NS --for=condition=Succeeded --timeout=30m
kubectl logs pvc-migrator -n $NS
kubectl delete pod pvc-migrator -n $NS

# Patch workload, scale up, verify, then clean up
kubectl patch deployment $WORKLOAD -n $NS \
  --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/volumes/0/persistentVolumeClaim/claimName\",\"value\":\"$NEW\"}]"

kubectl scale deployment $WORKLOAD --replicas=1 -n $NS
kubectl rollout status deployment/$WORKLOAD -n $NS

# Delete old PVC only after verifying workload health
kubectl delete pvc $OLD -n $NS
```
