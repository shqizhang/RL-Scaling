#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy-all.sh — Orchestrate a full RL-Scaling deployment:
#   1) Deploy/Upgrade the rl-scaling-controller (this repo's deploy/)
#   2) Deploy/Upgrade the Dynamo platform + DGD with the custom RL-Scaling
#      vLLM-runtime image (this folder's deploy-dynamo.sh)
#
# Both steps are idempotent. Any flags passed to this script are forwarded to
# deploy-dynamo.sh (e.g. --router | --planner | --mocker | --skip-monitoring).
#
# Required env vars:
#   CONTROLLER_IMAGE        e.g. ghcr.io/shqizhang/rl-scaling-controller:v0.1.0
#   DYNAMO_IMAGE_REGISTRY   e.g. ghcr.io/shqizhang
#   DYNAMO_IMAGE_REPO       e.g. dynamo-vllm-runtime
#   RELEASE_VERSION         e.g. rl-scaling-<short-sha>
#   HF_TOKEN, NGC_API_KEY
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

: "${CONTROLLER_IMAGE:?CONTROLLER_IMAGE not set}"
: "${RELEASE_VERSION:?RELEASE_VERSION not set}"

echo "==> [1/2] Deploy rl-scaling-controller (${CONTROLLER_IMAGE})"
IMAGE="${CONTROLLER_IMAGE}" PUSH=false bash "${REPO_ROOT}/deploy/deploy-controller.sh"

echo "==> [2/2] Deploy Dynamo with RL-Scaling image (${RELEASE_VERSION})"
bash "${SCRIPT_DIR}/deploy-dynamo.sh" "$@"

echo
echo "Done. Sanity check:"
echo "  kubectl -n dynamo get deploy,svc,dgd,dgdsa"
echo "  kubectl -n dynamo-system get pods"
