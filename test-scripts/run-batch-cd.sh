#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# run-batch-cd.sh — one-shot Batch C+D for the fast-switch round (2026-07-22).
#
# Follows AGENTS.md (tunnel: ssh -N -L 16443:192.168.1.246:6443 gpu14) and
# RL-SCALING-IMAGE-BUILD.md §3.2/pyfix (thin overlay image — the changes are
# pure Python under components/src/dynamo/vllm/, no toolchain rebuild needed).
#
# Run from Git Bash on the workstation that has: ssh alias gpu14, kubectl
# (kubeconfig → 127.0.0.1:16443), docker (logged in to ghcr.io), python.
#
#   cd /c/projects/IP && bash RL-Scaling/test-scripts/run-batch-cd.sh
#
# Stages (idempotent; rerun resumes cheaply):
#   1 preflight   tunnel + kubectl + docker + ghcr auth
#   2 commit      record the fast-switch changes in both repos
#   3 image       pyfix overlay build FROM the currently-deployed worker image
#   4 deploy      patch worker Deployments (operator is at 0 → patch directly)
#                 image + DYNAMO_RL_CORDON_SETTLE=0.5, wait for rollout
#   5 suite       run_phased_rollout_5scenario_e2e.py --repeats 3
#   6 gates       check_suite_gates.py on the new suite dir
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # C:/projects/IP
DYN="$ROOT/dynamo"
RLS="$ROOT/RL-Scaling"
NS_WORKERS="${NS_WORKERS:-dynamo-system}"
SETTLE="${SETTLE:-0.5}"
REPEATS="${REPEATS:-3}"
REGISTRY="${REGISTRY:-ghcr.io/shqizhang}"
IMAGE_REPO="${IMAGE_REPO:-dynamo-vllm-runtime}"

log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

# ── 1. preflight ─────────────────────────────────────────────────────────────
log "1/6 preflight"
if ! kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then
  echo "tunnel down; starting: ssh -f -N -L 16443:192.168.1.246:6443 gpu14"
  ssh -f -N -L 16443:192.168.1.246:6443 gpu14 || die "ssh tunnel failed (check ssh alias gpu14)"
  sleep 2
  kubectl cluster-info --request-timeout=10s >/dev/null || die "kubectl still unreachable"
fi
docker info >/dev/null 2>&1 || die "docker not running"
python --version >/dev/null 2>&1 || die "python not on PATH"
# operator must stay at 0 replicas (AGENTS.md invariant)
OP_REPLICAS=$(kubectl -n dynamo-system get deploy -l app.kubernetes.io/name=dynamo-operator \
  -o jsonpath='{.items[0].spec.replicas}' 2>/dev/null || echo "?")
[ "$OP_REPLICAS" = "0" ] || echo "WARN: operator replicas=$OP_REPLICAS (expected 0 — tests own the Deployments)"

# ── 2. commit (traceability; nothing depends on push) ────────────────────────
log "2/6 commit"
git -C "$DYN" add components/src/dynamo/vllm/dual_mode.py components/src/dynamo/vllm/main.py
git -C "$DYN" diff --cached --quiet || git -C "$DYN" commit -m \
  "S2: zero-loss fast switch — hold-during-switch dispatcher + frontend ack surrogate; settle 3.0->0.5"
git -C "$RLS" add test-scripts/run_phased_rollout_5scenario_e2e.py \
  test-scripts/check_suite_gates.py test-scripts/run-batch-cd.sh \
  docs/PLAN-metrics-and-s2s3-optimization-20260722-zh.md \
  docs/ending-report/Evaluation-DataAudit-20260722.md || true
git -C "$RLS" diff --cached --quiet || git -C "$RLS" commit -m \
  "test: phased v2 — nvext queue-time/TTFT, role-aware GPU, S2 trigger calibration, pre-T0 guard, gates"
SHORT_SHA=$(git -C "$DYN" rev-parse --short HEAD)
NEW_TAG="rl-scaling-fastswitch-${SHORT_SHA}"
NEW_IMAGE="${REGISTRY}/${IMAGE_REPO}:${NEW_TAG}"
echo "worker image will be: $NEW_IMAGE"

# ── 3. pyfix overlay image ───────────────────────────────────────────────────
log "3/6 image (pyfix overlay)"
DECODE_DEPLOY=$(kubectl -n "$NS_WORKERS" get deploy -o name | grep -i vllmdecodeworker | head -1)
PREFILL_DEPLOY=$(kubectl -n "$NS_WORKERS" get deploy -o name | grep -i vllmprefillworker | head -1)
[ -n "$DECODE_DEPLOY" ] && [ -n "$PREFILL_DEPLOY" ] || die "worker Deployments not found in $NS_WORKERS"
BASE_IMAGE=$(kubectl -n "$NS_WORKERS" get "$DECODE_DEPLOY" \
  -o jsonpath='{.spec.template.spec.containers[0].image}')
echo "base image (currently deployed): $BASE_IMAGE"
if docker manifest inspect "$NEW_IMAGE" >/dev/null 2>&1; then
  echo "image already in registry; skipping build"
else
  ( cd "$DYN" && docker build -f deploy/RL-Scaling/Dockerfile.pyfix \
      --build-arg BASE_IMAGE="$BASE_IMAGE" -t "$NEW_IMAGE" . )
  docker push "$NEW_IMAGE"
fi

# ── 4. deploy ────────────────────────────────────────────────────────────────
log "4/6 deploy (patch Deployments directly; operator held at 0)"
# FD hygiene: a long-lived frontend accumulates leaked fds across suites and
# eventually dies mid-run with "Too many open files (os error 24)" — observed
# 2026-07-23 00:31, killing all 44 in-flight A streams with 500s. Start every
# suite on a fresh frontend.
FRONTEND_DEPLOY=$(kubectl -n "$NS_WORKERS" get deploy -o name | grep -i frontend | head -1)
if [ -n "$FRONTEND_DEPLOY" ]; then
  kubectl -n "$NS_WORKERS" rollout restart "$FRONTEND_DEPLOY"
  kubectl -n "$NS_WORKERS" rollout status "$FRONTEND_DEPLOY" --timeout=300s
fi
for D in "$DECODE_DEPLOY" "$PREFILL_DEPLOY"; do
  kubectl -n "$NS_WORKERS" set image "$D" "*=$NEW_IMAGE"
  kubectl -n "$NS_WORKERS" set env "$D" DYNAMO_RL_CORDON_SETTLE="$SETTLE"
done
# best-effort: keep the DGD spec consistent so a transient operator reconcile
# cannot revert the image (the operator is normally at 0)
kubectl -n "$NS_WORKERS" patch dgd vllm-v1-disagg-router --type merge -p \
  "{\"spec\":{\"services\":{\"VllmDecodeWorker\":{\"extraPodSpec\":{\"mainContainer\":{\"image\":\"$NEW_IMAGE\"}}},\"VllmPrefillWorker\":{\"extraPodSpec\":{\"mainContainer\":{\"image\":\"$NEW_IMAGE\"}}}}}}" \
  2>/dev/null || echo "note: DGD patch skipped (schema/CRD mismatch is fine — operator is at 0)"
for D in "$DECODE_DEPLOY" "$PREFILL_DEPLOY"; do
  kubectl -n "$NS_WORKERS" rollout status "$D" --timeout=600s
done
RUNNING=$(kubectl -n "$NS_WORKERS" get pods -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | sort -u)
echo "running images:"; echo "$RUNNING"
echo "$RUNNING" | grep -q "$NEW_TAG" || die "new image not running"

# ── 5. suite ─────────────────────────────────────────────────────────────────
log "5/6 five-scenario suite (repeats=$REPEATS, interleaved/counterbalanced)"
SUITE_DIR="reports/phased-v2-$(date +%Y%m%d-%H%M%S)"
( cd "$RLS/test-scripts" && python run_phased_rollout_5scenario_e2e.py \
    --repeats "$REPEATS" --suite-dir "$SUITE_DIR" )

# ── 6. gates ─────────────────────────────────────────────────────────────────
log "6/6 gates"
( cd "$RLS/test-scripts" && python check_suite_gates.py "$SUITE_DIR" ) \
  && log "ALL GATES PASS — suite: RL-Scaling/test-scripts/$SUITE_DIR" \
  || die "gate failures — inspect $SUITE_DIR (do NOT write the report from this data)"
