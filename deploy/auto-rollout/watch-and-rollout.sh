#!/usr/bin/env bash
# Long-running watcher: polls GHCR for new rl-scaling-<sha> tags on the
# dynamo-vllm-runtime image and invokes rollout-once.sh whenever the moving
# `rl-scaling-latest` tag points to a digest we haven't deployed yet.
#
# We poll GHCR (not GHA workflow status) because the workflow can finish with
# conclusion!=success even when the docker-push step succeeded (the Notify
# step depends on a secret that may be unset in forks). The presence of an
# image in GHCR is the authoritative deployable signal.
#
# State (last deployed digest) is persisted under STATE_DIR.
#
# Env (all optional):
#   POLL_INTERVAL_SECS   (default: 60)
#   IMAGE_REPO           (default: ghcr.io/shqizhang/dynamo-vllm-runtime)
#   STATE_DIR            (default: $HOME/.local/state/rl-scaling-auto-rollout)
#   NAMESPACE / DGD_NAME / DECODE_REPLICAS / PREFILL_REPLICAS — see rollout-once.sh
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

POLL_INTERVAL_SECS="${POLL_INTERVAL_SECS:-60}"
IMAGE_REPO="${IMAGE_REPO:-ghcr.io/shqizhang/dynamo-vllm-runtime}"
STATE_DIR="${STATE_DIR:-${HOME}/.local/state/rl-scaling-auto-rollout}"
mkdir -p "${STATE_DIR}"
LAST_DIGEST_FILE="${STATE_DIR}/last_deployed_digest"

PKG_PATH="${IMAGE_REPO#ghcr.io/}"  # e.g. shqizhang/dynamo-vllm-runtime

log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }

log "watcher up. image_repo=${IMAGE_REPO} interval=${POLL_INTERVAL_SECS}s"
log "state file: ${LAST_DIGEST_FILE}"
log "rollout script: ${SCRIPT_DIR}/rollout-once.sh"

ghcr_token() {
  curl -sSf "https://ghcr.io/token?scope=repository:${PKG_PATH}:pull" \
    | jq -r .token 2>/dev/null
}

# Get the manifest digest for a tag.
ghcr_digest_for_tag() {
  local tag="$1" token="$2"
  curl -sS -o /dev/null -D - \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.oci.image.index.v1+json" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json" \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
    "https://ghcr.io/v2/${PKG_PATH}/manifests/${tag}" \
    | grep -i '^docker-content-digest:' | tr -d '\r' | awk '{print $2}'
}

while true; do
  token="$(ghcr_token)" || token=""
  if [[ -z "${token}" || "${token}" == "null" ]]; then
    log "could not obtain GHCR pull token; sleeping"
    sleep "${POLL_INTERVAL_SECS}"
    continue
  fi

  latest_digest="$(ghcr_digest_for_tag rl-scaling-latest "${token}" || true)"
  if [[ -z "${latest_digest}" ]]; then
    log "rl-scaling-latest not found yet (no successful build pushed); sleeping"
    sleep "${POLL_INTERVAL_SECS}"
    continue
  fi

  last_digest=""
  [[ -f "${LAST_DIGEST_FILE}" ]] && last_digest="$(cat "${LAST_DIGEST_FILE}")"

  if [[ "${latest_digest}" == "${last_digest}" ]]; then
    sleep "${POLL_INTERVAL_SECS}"
    continue
  fi

  # Find the SHA-style tag that shares this digest (so we deploy by an
  # immutable tag, not the moving `latest`).
  tags="$(curl -sSf -H "Authorization: Bearer ${token}" \
          "https://ghcr.io/v2/${PKG_PATH}/tags/list" 2>/dev/null \
          | jq -r '.tags[]?')"
  sha_tag=""
  for t in ${tags}; do
    [[ "${t}" == "rl-scaling-latest" ]] && continue
    [[ "${t}" =~ ^rl-scaling-[0-9a-f]{6,}$ ]] || continue
    d="$(ghcr_digest_for_tag "${t}" "${token}" || true)"
    if [[ "${d}" == "${latest_digest}" ]]; then
      sha_tag="${t}"
      break
    fi
  done

  if [[ -z "${sha_tag}" ]]; then
    log "found new rl-scaling-latest digest=${latest_digest} but no matching sha tag; deploying by digest pin"
    image="${IMAGE_REPO}@${latest_digest}"
  else
    image="${IMAGE_REPO}:${sha_tag}"
  fi
  log "new image detected: ${image} (digest=${latest_digest})"

  if IMAGE="${image}" "${SCRIPT_DIR}/rollout-once.sh"; then
    echo "${latest_digest}" > "${LAST_DIGEST_FILE}"
    log "rollout OK; recorded digest=${latest_digest}"
  else
    log "rollout FAILED for ${image}; will retry on next poll"
  fi

  sleep "${POLL_INTERVAL_SECS}"
done
