#!/usr/bin/env bash
# Build, push, and apply the rl-scaling-controller to a target cluster.
#
# Usage:
#   IMAGE=ghcr.io/<you>/rl-scaling-controller:v0.1.0 ./deploy/deploy-controller.sh
#   NAMESPACE=dynamo IMAGE=...                      ./deploy/deploy-controller.sh
#
# Pre-reqs: docker, kubectl pointing at the target cluster.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-dynamo}"
IMAGE="${IMAGE:-rl-scaling-controller:dev}"
PUSH="${PUSH:-true}"

echo "==> Build image: ${IMAGE}"
docker build -f "${REPO_ROOT}/deploy/Dockerfile" -t "${IMAGE}" "${REPO_ROOT}"

if [[ "${PUSH}" == "true" && "${IMAGE}" != *":dev" ]]; then
  echo "==> Push ${IMAGE}"
  docker push "${IMAGE}"
fi

echo "==> Ensure namespace ${NAMESPACE}"
kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${NAMESPACE}"

echo "==> Apply RBAC + ConfigMap"
kubectl apply -f "${REPO_ROOT}/deploy/manifests/01-rbac.yaml"
kubectl apply -f "${REPO_ROOT}/deploy/manifests/02-configmap.yaml"

echo "==> Apply Deployment + Service (image=${IMAGE})"
sed "s|image: .*rl-scaling-controller:dev|image: ${IMAGE}|" \
    "${REPO_ROOT}/deploy/manifests/03-deployment.yaml" | kubectl apply -f -

echo "==> Wait for rollout"
kubectl -n "${NAMESPACE}" rollout status deploy/rl-scaling-controller --timeout=180s

echo "==> Quick smoke"
kubectl -n "${NAMESPACE}" get deploy,svc,pod -l app=rl-scaling-controller
POD=$(kubectl -n "${NAMESPACE}" get pod -l app=rl-scaling-controller -o jsonpath='{.items[0].metadata.name}')
kubectl -n "${NAMESPACE}" exec "${POD}" -- python -c \
  "import urllib.request,json;print(json.load(urllib.request.urlopen('http://127.0.0.1:8080/api/v1/status')))"

echo "==> Done. Reach the API via:"
echo "    kubectl -n ${NAMESPACE} port-forward svc/rl-scaling-controller 8080:8080"
