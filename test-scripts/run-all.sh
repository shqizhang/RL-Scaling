#!/usr/bin/env bash
# Run all unit tests + (optionally) all e2e scripts in order.
# Usage:
#   ./test-scripts/run-all.sh unit         # unit tests only
#   ./test-scripts/run-all.sh e2e          # e2e scripts only (requires cluster)
#   ./test-scripts/run-all.sh all          # both
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-unit}"

unit() {
  echo "==> Python unit tests"
  python -m pytest "${REPO_ROOT}/rl-signal-sdk" "${REPO_ROOT}/rl-scaling-controller" -q
  echo "==> Dynamo unit tests (skipped here; run inside dynamo/)"
}

e2e() {
  echo "==> S1"
  bash "${REPO_ROOT}/test-scripts/test-s1.sh"
  echo "==> S2"
  bash "${REPO_ROOT}/test-scripts/test-s2.sh"
  echo "==> S3"
  bash "${REPO_ROOT}/test-scripts/test-s3.sh"
}

case "${MODE}" in
  unit) unit ;;
  e2e)  e2e  ;;
  all)  unit; e2e ;;
  *)    echo "usage: $0 {unit|e2e|all}"; exit 2 ;;
esac
