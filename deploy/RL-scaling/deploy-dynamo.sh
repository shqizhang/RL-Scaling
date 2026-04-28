#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy-dynamo.sh — Reuse the existing 1.0.1 platform deploy script with a
# *custom RL-Scaling image* by:
#   1) copying the original manifests/ to a temp dir,
#   2) sed-rewriting the image registry/repo references in that copy,
#   3) invoking the existing 01-deploy-dynamo-1.0.1.sh with MANIFEST_DIR
#      and RELEASE_VERSION pointing at the new image.
#
# Nothing in the original tutorial scripts is mutated except a one-line
# `MANIFEST_DIR="${MANIFEST_DIR:-…}"` override that's already been applied.
#
# Usage:
#   DYNAMO_IMAGE_REGISTRY=ghcr.io/your-name \
#   DYNAMO_IMAGE_REPO=dynamo-vllm-runtime \
#   RELEASE_VERSION=rl-scaling-abc1234 \
#   HF_TOKEN=... NGC_API_KEY=... \
#   ./deploy-dynamo.sh --router
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

UPSTREAM_DEPLOYER="${REPO_ROOT}/tutorial/dynamo-auto-deploy/1.0.1/01-deploy-dynamo-1.0.1.sh"
UPSTREAM_MANIFESTS="${REPO_ROOT}/tutorial/dynamo-auto-deploy/1.0.1/manifests"

[[ -x "${UPSTREAM_DEPLOYER}" ]] || chmod +x "${UPSTREAM_DEPLOYER}" || true
[[ -d "${UPSTREAM_MANIFESTS}" ]] || { echo "manifests not found: ${UPSTREAM_MANIFESTS}"; exit 1; }

# ── overrides ────────────────────────────────────────────────────────────────
DYNAMO_IMAGE_REGISTRY="${DYNAMO_IMAGE_REGISTRY:-ghcr.io/shqizhang}"
DYNAMO_IMAGE_REPO="${DYNAMO_IMAGE_REPO:-dynamo-vllm-runtime}"
# RELEASE_VERSION is consumed by both the wrapper and the upstream deployer
RELEASE_VERSION="${RELEASE_VERSION:?must set RELEASE_VERSION (e.g. rl-scaling-<sha>)}"

# Build a sed-modified manifests copy
TMP_MANIFESTS="$(mktemp -d /tmp/rl-scaling-manifests-XXXXXX)"
trap 'rm -rf "${TMP_MANIFESTS}"' EXIT
cp -r "${UPSTREAM_MANIFESTS}/." "${TMP_MANIFESTS}/"

# Rewrite the image base. We keep the ${RELEASE_VERSION} placeholder intact so
# the upstream renderer still substitutes the tag.
NEW_BASE="${DYNAMO_IMAGE_REGISTRY}/${DYNAMO_IMAGE_REPO}"
find "${TMP_MANIFESTS}" -type f -name '*.yaml' -print0 | xargs -0 \
    sed -i "s|nvcr.io/nvidia/ai-dynamo/vllm-runtime|${NEW_BASE}|g; \
            s|nvcr.io/nvidia/ai-dynamo/mocker-runtime|${NEW_BASE}|g"

echo "==> Patched manifests at ${TMP_MANIFESTS}"
grep -RH "image: " "${TMP_MANIFESTS}" | head -n5 || true

# Invoke upstream deployer
export MANIFEST_DIR="${TMP_MANIFESTS}"
export RELEASE_VERSION
echo "==> Invoking upstream deployer with MANIFEST_DIR=${MANIFEST_DIR} RELEASE_VERSION=${RELEASE_VERSION}"
exec bash "${UPSTREAM_DEPLOYER}" "$@"
