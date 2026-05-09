#!/usr/bin/env bash
# ============================================================================
# apply-dual-mode-decode.sh — Patch the deployed DGD so decode workers run
# with --kv-transfer-config (so vLLM brings up NixlConnector at engine boot)
# and DYNAMO_RL_DUAL_MODE=1 (so dynamo.vllm wires the partner prefill
# endpoint + Reregistrar).  Also bumps Frontend + worker images to the
# requested tag and waits for rollout.
#
# This is a superset of deploy/auto-rollout/rollout-once.sh — that script
# only patches images, but our true-E2E switch requires the new args/envs
# on decode pods as well.
#
# Usage:
#   IMAGE=ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-844302352d \
#     ./test-scripts/apply-dual-mode-decode.sh
# ============================================================================
set -euo pipefail
IMAGE="${IMAGE:-${1:-}}"
NS="${NS:-dynamo-system}"
DGD="${DGD:-vllm-v1-disagg-router}"
MODEL="${MODEL:-Qwen/Qwen3-0.6B}"
DECODE_REPLICAS="${DECODE_REPLICAS:-2}"
PREFILL_REPLICAS="${PREFILL_REPLICAS:-1}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-900s}"
SIDECAR_PORT="${SIDECAR_PORT:-9091}"

[[ -n "${IMAGE}" ]] || { echo "ERROR: IMAGE not set"; exit 2; }

log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }
log "patching ${DGD} in ${NS} with image=${IMAGE}"

PATCH_JSON=$(cat <<JSON
{
  "spec": {
    "services": {
      "Frontend": {
        "extraPodSpec": {"mainContainer": {"image": "${IMAGE}"}}
      },
      "VllmDecodeWorker": {
        "replicas": ${DECODE_REPLICAS},
        "envs": [
          {"name": "DYNAMO_RL_DUAL_MODE", "value": "1"},
          {"name": "DYNAMO_RL_SIDECAR_PORT", "value": "${SIDECAR_PORT}"}
        ],
        "extraPodSpec": {
          "mainContainer": {
            "image": "${IMAGE}",
            "args": [
              "--model", "${MODEL}",
              "--disaggregation-mode", "decode",
              "--kv-transfer-config", "{\"kv_connector\":\"NixlConnector\",\"kv_role\":\"kv_both\"}",
              "--kv-events-config", "{\"publisher\":\"zmq\",\"topic\":\"kv-events\",\"endpoint\":\"tcp://*:20080\",\"enable_kv_cache_events\":true}"
            ]
          }
        }
      },
      "VllmPrefillWorker": {
        "replicas": ${PREFILL_REPLICAS},
        "extraPodSpec": {"mainContainer": {"image": "${IMAGE}"}}
      }
    }
  }
}
JSON
)
echo "${PATCH_JSON}"
kubectl -n "${NS}" patch dgd "${DGD}" --type merge -p "${PATCH_JSON}"

log "waiting for operator-managed deployments to roll out"
SEL="nvidia.com/dynamo-graph-deployment-name=${DGD}"
sleep 8
for _ in {1..30}; do
  mapfile -t DEPLOYS < <(kubectl -n "${NS}" get deploy -l "${SEL}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  (( ${#DEPLOYS[@]} > 0 )) && break
  sleep 5
done
for dep in "${DEPLOYS[@]}"; do
  log "  rollout status ${dep}"
  kubectl -n "${NS}" rollout status deploy/"${dep}" --timeout="${ROLLOUT_TIMEOUT}" || log "  WARN: ${dep} rollout returned non-zero"
done

log "final pod state:"
kubectl -n "${NS}" get pod -l "${SEL}" -o wide
log "decode pod env (sample):"
SAMPLE=$(kubectl -n "${NS}" get pod -l "nvidia.com/dynamo-component=VllmDecodeWorker,${SEL}" -o jsonpath='{.items[0].metadata.name}')
[[ -n "${SAMPLE}" ]] && kubectl -n "${NS}" exec "${SAMPLE}" -- printenv DYNAMO_RL_DUAL_MODE 2>/dev/null || true
log "done"
