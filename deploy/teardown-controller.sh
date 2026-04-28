#!/usr/bin/env bash
# Wipe the controller (does NOT touch DGD/DGDSA workloads).
set -euo pipefail
NAMESPACE="${NAMESPACE:-dynamo}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubectl delete -f "${REPO_ROOT}/deploy/manifests/03-deployment.yaml" --ignore-not-found
kubectl delete -f "${REPO_ROOT}/deploy/manifests/02-configmap.yaml" --ignore-not-found
kubectl delete -f "${REPO_ROOT}/deploy/manifests/01-rbac.yaml"      --ignore-not-found
echo "Removed."
