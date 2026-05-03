#!/usr/bin/env bash
# Post-deployment integration test runner.
# Waits until the DGD is fully rolled out to the target image, then runs
# test-s2 + test-s3 and saves a timestamped report.
#
# Usage:
#   TARGET_SHA=d78e0879b7 bash deploy/auto-rollout/wait-and-test.sh
# or let the script autodetect the current rl-scaling-latest tag.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
NAMESPACE="${NAMESPACE:-dynamo-system}"
DGD_NAME="${DGD_NAME:-vllm-v1-disagg-router}"
TARGET_SHA="${TARGET_SHA:-}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-1800}"   # 30 min max for build+pull
POLL_SECS="${POLL_SECS:-30}"
REPORT_DIR="${REPORT_DIR:-${REPO_ROOT}/test-scripts/reports}"
mkdir -p "${REPORT_DIR}"

IMAGE_REPO="ghcr.io/shqizhang/dynamo-vllm-runtime"
PKG_PATH="${IMAGE_REPO#ghcr.io/}"

log()   { printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "${LOG_FILE}"; }
log_nl(){ printf '\n' >> "${LOG_FILE}"; }

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${REPORT_DIR}/run-${TIMESTAMP}.log"
touch "${LOG_FILE}"

# ── 0. decide target image ──────────────────────────────────────────────────
if [[ -z "${TARGET_SHA}" ]]; then
  # Try to infer from the latest commit on the RL-Scaling branch of dynamo.
  TARGET_SHA="$(cd "${REPO_ROOT}" && git -C ../dynamo rev-parse --short=10 RL-Scaling 2>/dev/null || true)"
fi
log "target sha=${TARGET_SHA:-<any new tag>}  namespace=${NAMESPACE}  dgd=${DGD_NAME}"
log "report will be saved to: ${REPORT_DIR}/report-${TIMESTAMP}.md"

# ── 1. wait for cluster to be running the target image ──────────────────────
log "=== Phase 1: waiting for rollout of v3.6 image ==="
DEADLINE=$(( $(date +%s) + WAIT_TIMEOUT ))

wait_for_image() {
  local token img current_img
  token="$(curl -sSf "https://ghcr.io/token?scope=repository:${PKG_PATH}:pull" \
           | jq -r .token 2>/dev/null || true)"
  # Get tag list and find one matching TARGET_SHA
  if [[ -n "${TARGET_SHA}" && -n "${token}" && "${token}" != "null" ]]; then
    img="$(curl -sSf -H "Authorization: Bearer ${token}" \
           "https://ghcr.io/v2/${PKG_PATH}/tags/list" 2>/dev/null \
           | jq -r ".tags[]?" \
           | grep "^rl-scaling-${TARGET_SHA:0:7}" | head -1 || true)"
  fi

  if [[ -z "${img:-}" ]]; then
    log "  image not yet in GHCR (build still in progress)"
    return 1
  fi

  # Check that the cluster's DGD spec already has this image.
  current_img="$(kubectl -n "${NAMESPACE}" get dgd "${DGD_NAME}" \
                 -o jsonpath='{.spec.services.VllmDecodeWorker.extraPodSpec.mainContainer.image}' \
                 2>/dev/null || true)"
  TARGET_IMAGE="${IMAGE_REPO}:${img}"
  if [[ "${current_img}" != "${TARGET_IMAGE}" ]]; then
    log "  GHCR has ${img} but DGD still on ${current_img##*:} (watcher hasn't rolled yet)"
    return 1
  fi

  # All pods with the new image healthy?
  NOT_READY="$(kubectl -n "${NAMESPACE}" get pod \
               -l "nvidia.com/dynamo-graph-deployment-name=${DGD_NAME}" \
               --no-headers 2>/dev/null \
               | awk '$2 != $2 {next} $2 !~ /^[0-9]+\/[0-9]+$/ || $3 != "Running" {print $1}' || true)"
  # simpler: use Ready condition
  NOT_READY="$(kubectl -n "${NAMESPACE}" get pod \
               -l "nvidia.com/dynamo-graph-deployment-name=${DGD_NAME}" \
               -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' \
               2>/dev/null | grep -v Running || true)"
  if [[ -n "${NOT_READY}" ]]; then
    log "  waiting for pods: $(echo "${NOT_READY}" | tr '\n' ' ')"
    return 1
  fi
  log "  all pods running image ${img} ✓"
  return 0
}

while ! wait_for_image; do
  if (( $(date +%s) >= DEADLINE )); then
    log "ERROR: timeout waiting for rollout after ${WAIT_TIMEOUT}s"
    exit 1
  fi
  sleep "${POLL_SECS}"
done

log_nl
kubectl -n "${NAMESPACE}" get pod \
  -l "nvidia.com/dynamo-graph-deployment-name=${DGD_NAME}" -o wide \
  2>&1 | tee -a "${LOG_FILE}"

# ── 2. run tests ─────────────────────────────────────────────────────────────
S2_LOG="${REPORT_DIR}/s2-${TIMESTAMP}.log"
S3_LOG="${REPORT_DIR}/s3-${TIMESTAMP}.log"
S2_RC=0; S3_RC=0

run_test() {
  local name="$1" script="$2" logfile="$3" rc_var="$4"
  log_nl
  log "=== Phase 2: running ${name} ==="
  if NAMESPACE="${NAMESPACE}" DGD_NAME="${DGD_NAME}" RUN_DIR="${REPORT_DIR}/s${name:(-1)}-data-${TIMESTAMP}" \
       bash "${REPO_ROOT}/test-scripts/${script}" 2>&1 | tee "${logfile}"; then
    log "  ${name}: PASSED ✓"
    eval "${rc_var}=0"
  else
    log "  ${name}: FAILED ✗ (see ${logfile})"
    eval "${rc_var}=1"
  fi
}

run_test "test-s2" "test-s2.sh" "${S2_LOG}" "S2_RC"
run_test "test-s3" "test-s3.sh" "${S3_LOG}" "S3_RC"

# ── 3. generate report ────────────────────────────────────────────────────────
log_nl
log "=== Phase 3: generating report ==="

REPORT="${REPORT_DIR}/report-${TIMESTAMP}.md"
OVERALL="PASS"
(( S2_RC != 0 || S3_RC != 0 )) && OVERALL="FAIL"

# extract a few key facts from logs
s2_flip_ms="$(grep -oE 'wall-clock ms: [0-9]+' "${S2_LOG}" | head -1 | awk '{print $3}' || echo '?')"
s2_new_role="$(grep -oE '"new_role":"[^"]+"' "${S2_LOG}" | head -1 | sed 's/.*:"\(.*\)"/\1/' || echo '?')"
s3_roundtrip="$(grep -E 'roundtrip ok|FAIL' "${S3_LOG}" | head -1 || echo '?')"
s3_kvbm="$(grep -E 'KVBM block-transfer' "${S3_LOG}" | head -1 || echo '?')"
s3_connector="$(grep -E 'Phase-2.B' "${S3_LOG}" | tail -1 || echo 'not tested')"

cat > "${REPORT}" <<REPORT_EOF
# RL-Scaling v3.6 Deployment Test Report

**Date:** $(date -Is)
**Overall:** ${OVERALL}
**Target SHA:** ${TARGET_SHA:-auto}
**Image:** ${TARGET_IMAGE:-unknown}
**Namespace:** ${NAMESPACE}
**DGD:** ${DGD_NAME}

---

## S2 — Elastic Role Switch

| Field | Value |
|---|---|
| Result | $([ "${S2_RC}" -eq 0 ] && echo "✅ PASS" || echo "❌ FAIL") |
| new_role | ${s2_new_role} |
| switch_time wall-clock | ${s2_flip_ms} ms |
| Full log | s2-${TIMESTAMP}.log |

$(tail -30 "${S2_LOG}" | sed 's/^/    /')

---

## S3 — Request Consolidation / Migration

| Field | Value |
|---|---|
| Result | $([ "${S3_RC}" -eq 0 ] && echo "✅ PASS" || echo "❌ FAIL") |
| migrate_out/in roundtrip | ${s3_roundtrip} |
| KVBM counters | ${s3_kvbm} |
| Phase-2.B (connector path) | ${s3_connector} |
| Full log | s3-${TIMESTAMP}.log |

$(tail -30 "${S3_LOG}" | sed 's/^/    /')

---

## Pod State at Test Time

\`\`\`
$(kubectl -n "${NAMESPACE}" get pod \
    -l "nvidia.com/dynamo-graph-deployment-name=${DGD_NAME}" -o wide 2>&1)
\`\`\`

---

*Generated by deploy/auto-rollout/wait-and-test.sh*
REPORT_EOF

log "Report written: ${REPORT}"
log "=== Overall: ${OVERALL} ==="

if [[ "${OVERALL}" == "FAIL" ]]; then
  exit 1
fi
