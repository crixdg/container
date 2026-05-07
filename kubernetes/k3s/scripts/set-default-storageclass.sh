#!/bin/bash

# Switch the default StorageClass from local-path to longhorn.
# Run this only after Longhorn is installed and healthy.

set -euo pipefail

echo "Removing default annotation from local-path ..."
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'

echo "Setting longhorn as default ..."
kubectl patch storageclass longhorn \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

echo ""
kubectl get storageclass
echo ""
echo "Done. New PVCs without an explicit storageClassName will now use Longhorn."
echo "Existing local-path PVCs are unchanged — see docs/migrate-to-longhorn.md to move them."
