#!/usr/bin/env bash
# Apply-only deploy: pulls the controller image from a registry (no local build)
# and applies the K8s manifests. Use this on disk-constrained nodes where
# `deploy-controller.sh` (which always runs `docker build`) is not viable.
#
# Usage:
#   IMAGE=ghcr.io/<owner>/rl-scaling-controller:<tag> ./deploy/apply-controller.sh
#   NAMESPACE=dynamo IMAGE=...                        ./deploy/apply-controller.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-dynamo}"
IMAGE="${IMAGE:?IMAGE env var is required, e.g. ghcr.io/shqizhang/rl-scaling-controller:latest}"

echo "==> Ensure namespace ${NAMESPACE}"
kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${NAMESPACE}"

echo "==> Apply RBAC + ConfigMap"
kubectl apply -f "${REPO_ROOT}/deploy/manifests/01-rbac.yaml"
kubectl apply -f "${REPO_ROOT}/deploy/manifests/02-configmap.yaml"

echo "==> Apply Deployment + Service (image=${IMAGE})"
sed "s|image: .*rl-scaling-controller:.*|image: ${IMAGE}|" \
    "${REPO_ROOT}/deploy/manifests/03-deployment.yaml" | kubectl apply -f -

echo "==> Restart to pick up new image"
kubectl -n "${NAMESPACE}" rollout restart deploy/rl-scaling-controller

echo "==> Wait for rollout"
kubectl -n "${NAMESPACE}" rollout status deploy/rl-scaling-controller --timeout=300s

echo "==> Status"
kubectl -n "${NAMESPACE}" get deploy,svc,pod -l app=rl-scaling-controller
echo
echo "==> Done. Reach the API via:"
echo "    kubectl -n ${NAMESPACE} port-forward svc/rl-scaling-controller 8080:8080"
