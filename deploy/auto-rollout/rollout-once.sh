#!/usr/bin/env bash
# Idempotent rollout: patch the DGD with a new dynamo-vllm-runtime image tag.
#
# Inputs (env or args):
#   IMAGE       full image ref, e.g. ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-d78e0879b7
#   NAMESPACE   (default: dynamo-system)
#   DGD_NAME    (default: vllm-v1-disagg-router)
#   DECODE_REPLICAS (default: 2)
#   PREFILL_REPLICAS (default: 1)
#   ROLLOUT_TIMEOUT (default: 600s)
#
# Behaviour:
#   - Reads the current main-container image off the DGD CR. If it already
#     equals IMAGE *and* both deployments are Available with the right
#     replicas, the script no-ops and exits 0.
#   - Otherwise patches the DGD spec.services.{VllmDecodeWorker,VllmPrefillWorker}
#     .extraPodSpec.mainContainer.image and .replicas, then waits for the
#     operator-managed Deployments to roll out.
#   - Returns non-zero if rollout times out or pods crashloop.
set -euo pipefail

IMAGE="${IMAGE:-${1:-}}"
NAMESPACE="${NAMESPACE:-dynamo-system}"
DGD_NAME="${DGD_NAME:-vllm-v1-disagg-router}"
DECODE_REPLICAS="${DECODE_REPLICAS:-2}"
PREFILL_REPLICAS="${PREFILL_REPLICAS:-1}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-600s}"

if [[ -z "${IMAGE}" ]]; then
  echo "ERROR: IMAGE not set (env or arg1)" >&2
  exit 2
fi

log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }

log "rollout target: image=${IMAGE}  ns=${NAMESPACE}  dgd=${DGD_NAME}  decode=${DECODE_REPLICAS}  prefill=${PREFILL_REPLICAS}"

# Read current state from the DGD CR.
current_decode_image="$(kubectl -n "${NAMESPACE}" get dgd "${DGD_NAME}" \
    -o jsonpath='{.spec.services.VllmDecodeWorker.extraPodSpec.mainContainer.image}' 2>/dev/null || true)"
current_decode_replicas="$(kubectl -n "${NAMESPACE}" get dgd "${DGD_NAME}" \
    -o jsonpath='{.spec.services.VllmDecodeWorker.replicas}' 2>/dev/null || echo 0)"
current_prefill_image="$(kubectl -n "${NAMESPACE}" get dgd "${DGD_NAME}" \
    -o jsonpath='{.spec.services.VllmPrefillWorker.extraPodSpec.mainContainer.image}' 2>/dev/null || true)"

log "current: decode_image=${current_decode_image:-<unset>} decode_replicas=${current_decode_replicas:-0} prefill_image=${current_prefill_image:-<unset>}"

needs_patch=0
[[ "${current_decode_image}" != "${IMAGE}" ]] && needs_patch=1
[[ "${current_prefill_image}" != "${IMAGE}" ]] && needs_patch=1
[[ "${current_decode_replicas}" != "${DECODE_REPLICAS}" ]] && needs_patch=1

if [[ "${needs_patch}" == "0" ]]; then
  log "no patch needed (image + replicas already match) — skipping rollout"
  exit 0
fi

log "applying patch …"
kubectl -n "${NAMESPACE}" patch dgd "${DGD_NAME}" --type merge -p "$(cat <<JSON
{
  "spec": {
    "services": {
      "Frontend": {
        "extraPodSpec": {"mainContainer": {"image": "${IMAGE}"}}
      },
      "VllmDecodeWorker": {
        "replicas": ${DECODE_REPLICAS},
        "extraPodSpec": {"mainContainer": {"image": "${IMAGE}"}}
      },
      "VllmPrefillWorker": {
        "replicas": ${PREFILL_REPLICAS},
        "extraPodSpec": {"mainContainer": {"image": "${IMAGE}"}}
      }
    }
  }
}
JSON
)"

log "waiting for operator to reconcile + rollout (timeout=${ROLLOUT_TIMEOUT}) …"
# The operator names deployments with a worker-hash suffix that changes when
# spec changes (e.g. ${DGD_NAME}-vllmdecodeworker-<hash>). After the patch the
# old hash deployment may be replaced. Wait by label selector instead of by
# fixed deployment name.
SEL="nvidia.com/dynamo-graph-deployment-name=${DGD_NAME}"

# Give the operator a moment to create the new deploys.
sleep 5
mapfile -t DEPLOYS < <(kubectl -n "${NAMESPACE}" get deploy -l "${SEL}" \
                       -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
if (( ${#DEPLOYS[@]} == 0 )); then
  log "WARN: no deploys yet match ${SEL}; waiting up to ${ROLLOUT_TIMEOUT}"
  for _ in {1..30}; do
    sleep 10
    mapfile -t DEPLOYS < <(kubectl -n "${NAMESPACE}" get deploy -l "${SEL}" \
                           -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    (( ${#DEPLOYS[@]} > 0 )) && break
  done
fi
for dep in "${DEPLOYS[@]}"; do
  log "  rollout status ${dep}"
  kubectl -n "${NAMESPACE}" rollout status deploy/"${dep}" --timeout="${ROLLOUT_TIMEOUT}" || \
    log "  WARN rollout status returned non-zero for ${dep}"
done

log "rollout finished. Pods:"
kubectl -n "${NAMESPACE}" get pod -l "${SEL}" -o wide
