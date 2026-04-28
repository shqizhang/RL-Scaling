#!/usr/bin/env bash
# ============================================================================
# cleanup-old.sh — 清理旧版本 Dynamo (0.7.x) 与遗留资源
#
# 设计目标:
#   - 仅保留 1.0.1 最小化部署所需资源
#   - 卸载顺序: DGD → DGDSA → Helm Release → CRD → Namespace → 残留 PV
#   - 默认 dry-run。需要 --apply 才真正执行
#   - 需要 --include-monitoring 才一并清理 monitoring 命名空间
#
# 使用:
#   bash cleanup-old.sh                      # dry-run
#   bash cleanup-old.sh --apply              # 真删
#   bash cleanup-old.sh --apply --include-monitoring
# ============================================================================
set -euo pipefail

NAMESPACE="${NAMESPACE:-dynamo-system}"
MONITORING_NS="${MONITORING_NS:-monitoring}"
APPLY=false
INCLUDE_MON=false

DELETE_NS=false
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=true ;;
    --include-monitoring) INCLUDE_MON=true ;;
    --delete-namespace) DELETE_NS=true ;;
    -h|--help)
      grep '^#' "$0" | sed -n '2,20p'; exit 0 ;;
    *) echo "Unknown arg: $arg"; exit 1 ;;
  esac
done

GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; NC='\033[0m'
log() { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERR ]${NC} $*"; }

run() {
  if $APPLY; then
    eval "$@"
  else
    echo "  [dry-run] $*"
  fi
}

command -v kubectl >/dev/null || { err "kubectl 未安装"; exit 1; }
command -v helm    >/dev/null || { err "helm 未安装"; exit 1; }

log "===== Cleanup Plan ($($APPLY && echo APPLY || echo dry-run)) ====="

# ── 1. 删除所有 DynamoGraphDeployment / DGDSA / DGDR ────────────────────
log "Step 1: 删除 Dynamo CR (DGD / DGDSA / DGDR / DynamoComponent*)"
for crd in dynamographdeployments \
           dynamographdeploymentscalingadapters \
           dynamographdeploymentrollouts \
           dynamocomponentdeployments \
           dynamoworkermetadata \
           dynamocheckpoints; do
  if kubectl get crd "${crd}.nvidia.com" &>/dev/null; then
    items=$(kubectl get "$crd" -A --no-headers 2>/dev/null | wc -l || echo 0)
    if [[ "$items" -gt 0 ]]; then
      log "  - $crd: $items 个实例"
      run "kubectl delete $crd --all -A --wait=false --ignore-not-found=true"
    fi
  fi
done

# ── 2. 卸载 Helm Releases ────────────────────────────────────────────────
log "Step 2: 卸载 Helm releases (旧版 dynamo-platform / dynamo-crds / 0.7.x)"
for release in dynamo-platform dynamo-crds dynamo-operator; do
  for ns in "$NAMESPACE" default kube-system; do
    if helm status "$release" -n "$ns" &>/dev/null; then
      log "  - 卸载 $release (ns=$ns)"
      run "helm uninstall $release -n $ns --wait --timeout 5m"
    fi
  done
done

# ── 3. 删除残留 Dynamo CRD ────────────────────────────────────────────────
# !! 关键: 只匹配 'dynamo' 字样, 绝对不能匹配 nvidia.com 通配 (gpu-operator 用 nvidia.com)
#         否则会误删 clusterpolicies.nvidia.com / nvidiadrivers.nvidia.com
#         导致 gpu-operator 拆掉驱动 DaemonSet, nvidia-smi 不可用!
log "Step 3: 删除 dynamo 相关 CRD (跳过 gpu-operator 的 nvidia.com CRD)"
DYNAMO_CRDS=$(kubectl get crd -o name 2>/dev/null \
  | grep -iE 'dynamo' \
  | grep -v -E 'clusterpolicies\.nvidia|nvidiadrivers\.nvidia|nvidiadriver|gpuoperator' \
  || true)
if [[ -n "$DYNAMO_CRDS" ]]; then
  echo "$DYNAMO_CRDS" | while read -r crd; do
    log "  - $crd"
    run "kubectl delete $crd --ignore-not-found=true --wait=false"
  done
else
  log "  - 无残留 CRD"
fi
# 显式保护 GPU Operator 的 CRD
if kubectl get crd 2>/dev/null | grep -qE 'clusterpolicies\.nvidia|nvidiadrivers\.nvidia'; then
  log "  - 保留 GPU Operator CRD (clusterpolicies.nvidia.com / nvidiadrivers.nvidia.com)"
fi

# ── 4. 清理可能残留的 ServiceMonitor / PodMonitor (旧 0.7.x 配置) ────────
log "Step 4: 清理旧 PodMonitor/ServiceMonitor"
if kubectl get crd podmonitors.monitoring.coreos.com &>/dev/null; then
  for kind in podmonitors servicemonitors; do
    items=$(kubectl get "$kind" -A -o name 2>/dev/null | grep -iE 'dynamo' || true)
    if [[ -n "$items" ]]; then
      echo "$items" | while read -r r; do
        ns=$(echo "$r" | awk -F/ '{print $1}')  # 实际 -A 输出不含 ns prefix; 走另一路径
      done
      # 简化: 直接按 name 删
      kubectl get "$kind" -A 2>/dev/null | awk '/dynamo/ {print $1, $2}' | while read -r ns name; do
        log "  - $kind/$name in $ns"
        run "kubectl delete $kind $name -n $ns --ignore-not-found=true"
      done
    fi
  done
fi

# ── 5. 删除命名空间 (仅当显式 --delete-namespace 时) ─────────────────────
log "Step 5: namespace 清理"
if [[ "${DELETE_NS:-false}" == "true" ]] && kubectl get ns "$NAMESPACE" &>/dev/null; then
  log "  - 删除 ns/$NAMESPACE (--delete-namespace 已指定)"
  run "kubectl delete ns $NAMESPACE --wait=false --ignore-not-found=true"
else
  log "  - 跳过 namespace 删除 (默认保留, 加 --delete-namespace 才删)"
  log "    若 ns 内还有其他人/etcd/nats, 不要轻易删"
fi

if $INCLUDE_MON && kubectl get ns "$MONITORING_NS" &>/dev/null; then
  log "  - 删除 ns/$MONITORING_NS (--include-monitoring)"
  run "helm uninstall kube-prometheus-stack -n $MONITORING_NS --ignore-not-found 2>/dev/null || true"
  run "kubectl delete ns $MONITORING_NS --wait=false --ignore-not-found=true"
fi

# ── 6. 残留 PV (Released / Failed) ─────────────────────────────────────
log "Step 6: 检查 Released/Failed PV"
ORPHAN_PVS=$(kubectl get pv --no-headers 2>/dev/null | awk '$5 ~ /(Released|Failed)/ {print $1}' || true)
if [[ -n "$ORPHAN_PVS" ]]; then
  echo "$ORPHAN_PVS" | while read -r pv; do
    log "  - 删除 PV/$pv"
    run "kubectl delete pv $pv --ignore-not-found=true"
  done
else
  log "  - 无残留 PV"
fi

log "===== Done ====="
$APPLY || warn "这是 dry-run。加 --apply 实际执行。"
