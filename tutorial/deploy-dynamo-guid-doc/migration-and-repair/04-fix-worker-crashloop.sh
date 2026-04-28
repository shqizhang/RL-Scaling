#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# 04-fix-worker-crashloop.sh
#
# 目的：  一键修复 SSD 迁移（或 containerd 重启）后 vllm Worker
#         CrashLoopBackOff 问题
#
# 根因：  containerd 重启触发 GPU Operator toolkit daemonset 覆写
#         config.toml，导致 3 个配置项偏离正确状态：
#           ① defaultRuntimeName 回退为 runc → libcuda.so.1 缺失
#           ② enable_cdi 被重置为 false → GPU 设备隔离失效
#           ③ device-plugin 未重启 → CDI annotation 未注入
#
# 修复策略（3 步缺一不可）：
#   ① kubectl set env toolkit daemonset NVIDIA_RUNTIME_SET_AS_DEFAULT=true
#   ② sudo sed enable_cdi = true + restart containerd
#   ③ kubectl rollout restart device-plugin daemonset
#   然后重建 DGD（manifest 不设 runtimeClassName，依赖 CDI 隔离）
#
# ⚠️ 不要用 runtimeClassName: nvidia 作为修复方案：
#   它会绕过 CDI 设备隔离 → 每个容器看到全部 8 张 GPU → OOM
#
# 适用场景：
#   - Platform (Operator/etcd/NATS) 正常运行
#   - VllmDecodeWorker / VllmPrefillWorker 处于 CrashLoopBackOff
#   - 症状: libcuda.so.1 缺失 或 CUDA OOM
#
# 前置条件：
#   - kubectl 可访问集群
#   - sudo 权限（修改 containerd config）
#   - manifest 模板位于同目录下的 manifests/ 子目录
#
# 用法：
#   bash 04-fix-worker-crashloop.sh
#
# 参数覆盖（可选，脚本会自动从集群提取，也可手动指定）：
#   RELEASE_VERSION=0.7.1 MODEL_NAME=Qwen/Qwen3-0.6B \
#   DECODE_REPLICAS=1 PREFILL_REPLICAS=1 \
#   bash 04-fix-worker-crashloop.sh
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"
DGD_NAME="vllm-v1-disagg-router"

# ─── 颜色输出 ──────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fatal() { echo -e "${RED}[FATAL]${NC} $*" >&2; exit 1; }

# ─── 临时文件清理 ───────────────────────────────────────────────────
TMPFILES=()
cleanup_tmpfiles() {
  for f in "${TMPFILES[@]:-}"; do
    [[ -f "$f" ]] && rm -f "$f"
  done
}
trap cleanup_tmpfiles EXIT

# ─── Banner ────────────────────────────────────────────────────────
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  04-fix-worker-crashloop.sh — Worker CrashLoop 一键修复     ║"
echo "║  根因：containerd 3 项 GPU 配置不正确                       ║"
echo "║  修复：toolkit env + CDI + device-plugin + 重建 DGD         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ─── 依赖检查 ──────────────────────────────────────────────────────
for cmd in kubectl envsubst python3; do
  command -v "$cmd" &>/dev/null || fatal "缺少依赖：$cmd（需要 kubectl、envsubst、python3）"
done

[[ -d "$MANIFESTS_DIR" ]] \
  || fatal "manifests 目录不存在：${MANIFESTS_DIR}\n  请确认脚本与 manifests/ 在同一目录下执行"
[[ -f "${MANIFESTS_DIR}/dgd-vllm-disagg-router.yaml" ]] \
  || fatal "缺少模板文件：manifests/dgd-vllm-disagg-router.yaml"

# ═══════════════════════════════════════════════════════════════════
# 阶段 1：诊断 & 修复 containerd GPU 配置（3 步缺一不可）
#
# 目的：  containerd 重启后 toolkit daemonset 会覆写配置，导致：
#         ① defaultRuntimeName 回退为 runc
#         ② enable_cdi 被重置为 false
#         ③ device-plugin 未感知配置变更
#         本阶段检测并修复这 3 个配置项。
# ═══════════════════════════════════════════════════════════════════
info "阶段 1：诊断 & 修复 containerd GPU 配置"

# 检查 nvidia-container-toolkit-daemonset 是否就绪
TOOLKIT_READY=$(kubectl get daemonset nvidia-container-toolkit-daemonset \
  -n gpu-operator \
  -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
if [[ "${TOOLKIT_READY}" -ge 1 ]]; then
  ok "nvidia-container-toolkit-daemonset 就绪（${TOOLKIT_READY} 个节点）"
else
  fatal "nvidia-container-toolkit-daemonset 未就绪！\n\
  请先修复 GPU Operator：kubectl get pods -n gpu-operator"
fi

# ── 1.1 检查 containerd 当前配置 ──
info "检查 containerd 实际配置（crictl info）..."
RUNTIME_INFO=$(sudo crictl info 2>/dev/null || true)
if [[ -z "$RUNTIME_INFO" ]]; then
  fatal "无法获取 containerd 配置（crictl info 失败）\n  请确认 containerd 正在运行: systemctl status containerd"
fi

DEFAULT_RT=$(echo "$RUNTIME_INFO" | python3 -c "
import json, sys
try:
    info = json.load(sys.stdin)
    print(info.get('config',{}).get('containerd',{}).get('defaultRuntimeName','unknown'))
except: print('error')" 2>/dev/null)

CDI_ENABLED=$(echo "$RUNTIME_INFO" | python3 -c "
import json, sys
try:
    info = json.load(sys.stdin)
    print(str(info.get('config',{}).get('enableCDI', False)))
except: print('error')" 2>/dev/null)

echo "  当前 defaultRuntimeName: ${DEFAULT_RT}"
echo "  当前 enableCDI: ${CDI_ENABLED}"

CONTAINERD_CHANGED=false

# ── 1.2 修复 ① defaultRuntimeName ──
if [[ "$DEFAULT_RT" != "nvidia" ]]; then
  warn "defaultRuntimeName = ${DEFAULT_RT}（应为 nvidia），正在修复..."
  info "设置 toolkit env NVIDIA_RUNTIME_SET_AS_DEFAULT=true"
  kubectl set env daemonset/nvidia-container-toolkit-daemonset \
    -n gpu-operator \
    NVIDIA_RUNTIME_SET_AS_DEFAULT=true
  info "等待 toolkit daemonset 重新配置..."
  kubectl rollout status ds/nvidia-container-toolkit-daemonset \
    -n gpu-operator --timeout=120s
  CONTAINERD_CHANGED=true
  ok "defaultRuntimeName 已修复为 nvidia"
else
  ok "defaultRuntimeName: nvidia ✓"
fi

# ── 1.3 修复 ② enable_cdi ──
if [[ "$CDI_ENABLED" != "True" ]]; then
  warn "enableCDI = ${CDI_ENABLED}（应为 True），正在修复..."
  if grep -q 'enable_cdi = false' /etc/containerd/config.toml 2>/dev/null; then
    sudo sed -i 's/enable_cdi = false/enable_cdi = true/' /etc/containerd/config.toml
    info "已修改 /etc/containerd/config.toml: enable_cdi = true"
  else
    warn "config.toml 中未找到 'enable_cdi = false'，尝试直接重启 containerd"
  fi
  sudo systemctl restart containerd
  CONTAINERD_CHANGED=true
  ok "CDI 已启用"
else
  ok "enableCDI: True ✓"
fi

# ── 1.4 修复 ③ 重启 device-plugin ──
if $CONTAINERD_CHANGED; then
  info "containerd 配置已变更，重启 nvidia-device-plugin-daemonset..."
  kubectl rollout restart daemonset/nvidia-device-plugin-daemonset -n gpu-operator
  kubectl rollout status ds/nvidia-device-plugin-daemonset -n gpu-operator --timeout=120s
  ok "device-plugin 已重启"
else
  # 即使配置没变，也检查 device-plugin 是否太旧
  DP_AGE=$(kubectl get pods -n gpu-operator \
    -l app=nvidia-device-plugin-daemonset \
    -o jsonpath='{.items[0].metadata.creationTimestamp}' 2>/dev/null || echo "")
  if [[ -n "$DP_AGE" ]]; then
    info "device-plugin Pod 启动时间: ${DP_AGE}"
    info "如果 Worker 仍然 OOM（8 卡全可见），考虑重启 device-plugin:"
    echo "    kubectl rollout restart ds/nvidia-device-plugin-daemonset -n gpu-operator"
  fi
fi

# ── 1.5 验证修复结果 ──
info "重新检查 containerd 配置..."
VERIFY_INFO=$(sudo crictl info 2>/dev/null || true)
VERIFY_RT=$(echo "$VERIFY_INFO" | python3 -c "
import json, sys
try:
    info = json.load(sys.stdin)
    print(info.get('config',{}).get('containerd',{}).get('defaultRuntimeName','unknown'))
except: print('error')" 2>/dev/null)
VERIFY_CDI=$(echo "$VERIFY_INFO" | python3 -c "
import json, sys
try:
    info = json.load(sys.stdin)
    print(str(info.get('config',{}).get('enableCDI', False)))
except: print('error')" 2>/dev/null)

echo "  修复后 defaultRuntimeName: ${VERIFY_RT}"
echo "  修复后 enableCDI: ${VERIFY_CDI}"

if [[ "$VERIFY_RT" != "nvidia" || "$VERIFY_CDI" != "True" ]]; then
  fatal "containerd 配置修复失败！\n\
  defaultRuntimeName=${VERIFY_RT}（期望 nvidia）\n\
  enableCDI=${VERIFY_CDI}（期望 True）\n\
  请参考 DIAGNOSIS-AND-REPAIR.md 第五节手动排查"
fi
ok "containerd GPU 配置全部正确 ✓"
echo ""

# ═══════════════════════════════════════════════════════════════════
# 阶段 2：定位 DGD，自动提取部署参数
#
# 目的：  从集群现有状态中提取 NAMESPACE、RELEASE_VERSION、MODEL_NAME、
#         DECODE_REPLICAS、PREFILL_REPLICAS，确保修复前后配置完全一致。
#         优先使用调用方设置的环境变量，其次从集群自动探测。
# ═══════════════════════════════════════════════════════════════════
info "阶段 2：定位 DGD，提取部署参数"

# 查找 DGD 所在 namespace
# 注意：kubectl get <resource> <name> -A 与单独指定名称时返回单一对象而非列表，
# 导致 .items[0] 为空。改用列出所有 DGD 再用 awk 按名称过滤。
NAMESPACE=$(kubectl get dgd -A \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.namespace}{"\n"}{end}' \
  2>/dev/null | awk -v name="$DGD_NAME" '$1 == name {print $2}' || true)
[[ -n "$NAMESPACE" ]] \
  || fatal "未找到 DGD ${DGD_NAME}。\n  请确认 Platform 已部署并运行正常：\n  kubectl get dgd -A"
ok "DGD ${DGD_NAME} 位于 namespace: ${NAMESPACE}"

DECODE_DEPLOY="vllm-v1-disagg-router-vllmdecodeworker"
PREFILL_DEPLOY="vllm-v1-disagg-router-vllmprefillworker"

# RELEASE_VERSION —— 从 DecodeWorker Deployment 的 image tag 提取
RELEASE_VERSION="${RELEASE_VERSION:-}"
if [[ -z "$RELEASE_VERSION" ]]; then
  RELEASE_VERSION=$(kubectl get deployment "$DECODE_DEPLOY" -n "$NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null \
    | awk -F: '{print $NF}') || true
fi
[[ -n "$RELEASE_VERSION" ]] \
  || fatal "无法提取 RELEASE_VERSION。\n  请手动设置：RELEASE_VERSION=0.7.1 bash $0"
ok "RELEASE_VERSION = ${RELEASE_VERSION}"

# MODEL_NAME —— 从 DecodeWorker Deployment args 中提取 --model 后的值
MODEL_NAME="${MODEL_NAME:-}"
if [[ -z "$MODEL_NAME" ]]; then
  MODEL_NAME=$(kubectl get deployment "$DECODE_DEPLOY" -n "$NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null \
    | python3 -c "
import sys, json
try:
    args = json.load(sys.stdin)
    idx = args.index('--model')
    print(args[idx + 1])
except (ValueError, IndexError, json.JSONDecodeError):
    print('')
" 2>/dev/null) || true
fi
[[ -n "$MODEL_NAME" ]] \
  || fatal "无法提取 MODEL_NAME。\n  请手动设置：MODEL_NAME=Qwen/Qwen3-0.6B bash $0"
ok "MODEL_NAME = ${MODEL_NAME}"

# DECODE_REPLICAS / PREFILL_REPLICAS —— 从各自 Deployment.spec.replicas 提取
DECODE_REPLICAS="${DECODE_REPLICAS:-}"
[[ -z "$DECODE_REPLICAS" ]] && DECODE_REPLICAS=$(kubectl get deployment "$DECODE_DEPLOY" \
  -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")

PREFILL_REPLICAS="${PREFILL_REPLICAS:-}"
[[ -z "$PREFILL_REPLICAS" ]] && PREFILL_REPLICAS=$(kubectl get deployment "$PREFILL_DEPLOY" \
  -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")

ok "DECODE_REPLICAS = ${DECODE_REPLICAS}  |  PREFILL_REPLICAS = ${PREFILL_REPLICAS}"

echo ""
info "将以以下参数重建 DGD："
printf "  %-20s = %s\n" "NAMESPACE"       "$NAMESPACE"
printf "  %-20s = %s\n" "RELEASE_VERSION" "$RELEASE_VERSION"
printf "  %-20s = %s\n" "MODEL_NAME"      "$MODEL_NAME"
printf "  %-20s = %s\n" "DECODE_REPLICAS" "$DECODE_REPLICAS"
printf "  %-20s = %s\n" "PREFILL_REPLICAS" "$PREFILL_REPLICAS"
echo ""

# ═══════════════════════════════════════════════════════════════════
# 阶段 3：删除现有 DGD
#
# 目的：  删除 DGD 触发 Dynamo Operator 清理下属 Deployment（含 Worker），
#         释放 GPU 资源配额，为重建做准备。
# 后果：  Frontend Deployment 也会被删除，Platform 不受影响。
# ═══════════════════════════════════════════════════════════════════
info "阶段 3：删除现有 DGD（${NAMESPACE}/${DGD_NAME}）"

kubectl delete dgd "$DGD_NAME" -n "$NAMESPACE" --wait=false 2>/dev/null || true

info "等待 DGD 完全删除（最多 120s）..."
WAIT_SECS=0
while kubectl get dgd "$DGD_NAME" -n "$NAMESPACE" &>/dev/null 2>&1; do
  sleep 5
  WAIT_SECS=$((WAIT_SECS + 5))
  printf "\r  等待中... %ds" "$WAIT_SECS"
  if [[ $WAIT_SECS -ge 120 ]]; then
    echo ""
    warn "120s 内 DGD 未完全删除，尝试强制删除..."
    kubectl delete dgd "$DGD_NAME" -n "$NAMESPACE" \
      --force --grace-period=0 2>/dev/null || true
    break
  fi
done
echo ""
ok "DGD 已删除"

# ═══════════════════════════════════════════════════════════════════
# 阶段 3.5：等待旧 Worker Pod 完全终止（GPU 内存释放）
#
# 目的：  DGD K8s 对象消失（Operator 移除 finalizer）不代表 Pod 已结束。
#         vLLM EngineCore 进程正常退出需 10~30s，SIGKILL 后 GPU 内存
#         才完全归还给 OS。如果在此之前创建新 Pod，NVIDIA device plugin
#         可能将 GPU 0 分配给新 Decode Pod（因 K8s 状态竞态），而旧
#         Prefill EngineCore 仍占用该 GPU 的显存 → 新 Decode OOM。
#
#         这是 本脚本已知的竞态条件根因，此等待步骤为关键修复。
# ═══════════════════════════════════════════════════════════════════
info "阶段 3.5：等待旧 Worker Pod 完全终止（GPU 内存释放）"

echo "  检查残留 Pod..."
LABEL_SELECTOR="nvidia.com/dynamo-graph-deployment-name=${DGD_NAME}"
POD_DRAIN_TIMEOUT=180
POD_DRAIN_ELAPSED=0

while [[ $POD_DRAIN_ELAPSED -lt $POD_DRAIN_TIMEOUT ]]; do
  REMAINING=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" \
    --no-headers 2>/dev/null | grep -c . || echo "0") 2>/dev/null || REMAINING=0

  if [[ "$REMAINING" -eq 0 ]]; then
    echo ""
    ok "所有旧 Worker Pod 已从 K8s 消失"
    break
  fi

  printf "\r  等待中（%ds/%ds）：仍有 %d 个 Pod（含 Terminating）..." \
    "$POD_DRAIN_ELAPSED" "$POD_DRAIN_TIMEOUT" "$REMAINING"
  sleep 5
  POD_DRAIN_ELAPSED=$((POD_DRAIN_ELAPSED + 5))

  if [[ $POD_DRAIN_ELAPSED -ge $POD_DRAIN_TIMEOUT ]]; then
    echo ""
    warn "Pod 在 ${POD_DRAIN_TIMEOUT}s 内未完全终止，尝试强制。"
    kubectl delete pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" \
      --force --grace-period=0 2>/dev/null || true
    sleep 5
  fi
done

# vLLM EngineCore 是 Pod 内子进程，Pod 消失后进程也应被 SIGKILL。
# 额外等待 30s 确保 GPU 驱动完成内存回收，避免 device plugin 状态竞态。
info "等待 GPU 显存彻底释放（30s buffer）..."
for i in $(seq 1 30); do
  printf "\r  %ds..." "$i"
  sleep 1
done
echo ""
ok "GPU 释放等待完成"
echo ""

# ═══════════════════════════════════════════════════════════════════
# 阶段 4：渲染并重建 DGD（不设 runtimeClassName，依赖 CDI 隔离）
#
# 目的：  阶段 1 已确保 containerd 配置正确（defaultRuntime=nvidia + CDI=true），
#         DGD manifest 不设 runtimeClassName，Pod 自动使用 nvidia runtime，
#         CDI 实现每个 Worker 只看到 1 张 GPU。
# ═══════════════════════════════════════════════════════════════════
info "阶段 4：重建 DGD（依赖 CDI 设备隔离）"

# envsubst 变量白名单：只替换这些变量，避免误替换 YAML 中其他 ${} 语法
TEMPLATE_VARS='${NAMESPACE} ${RELEASE_VERSION} ${MODEL_NAME} ${DECODE_REPLICAS} ${PREFILL_REPLICAS}'

export NAMESPACE RELEASE_VERSION MODEL_NAME DECODE_REPLICAS PREFILL_REPLICAS

TMPFILE=$(mktemp /tmp/dgd-fix-XXXXXX.yaml)
TMPFILES+=("$TMPFILE")

envsubst "$TEMPLATE_VARS" < "${MANIFESTS_DIR}/dgd-vllm-disagg-router.yaml" > "$TMPFILE"

kubectl apply -f "$TMPFILE"
ok "DGD 已提交"

# ═══════════════════════════════════════════════════════════════════
# 阶段 5：等待 Worker Deployment 就绪
#
# 目的：  vLLM Worker 需要加载模型权重，首次启动耗时取决于模型大小：
#         Qwen3-0.6B 约 1~3 分钟，大模型可达 10+ 分钟。
#         可在另一窗口用 kubectl logs 观察进度。
# ═══════════════════════════════════════════════════════════════════
info "阶段 5：等待 Worker Deployment 就绪（最多 600s）"
echo "  提示：可用以下命令实时观察启动进度："
echo "    kubectl logs -f -n ${NAMESPACE} -l app=${DECODE_DEPLOY} --tail=30"
echo ""

ROLLOUT_FAILED=0
for DEPLOY in "$DECODE_DEPLOY" "$PREFILL_DEPLOY"; do
  info "等待 Deployment ${DEPLOY}..."
  if kubectl rollout status "deployment/${DEPLOY}" -n "$NAMESPACE" --timeout=600s; then
    ok "${DEPLOY} 已就绪"
  else
    warn "${DEPLOY} 在 600s 内未完全就绪，请手动排查"
    echo "    kubectl get pods -n ${NAMESPACE}"
    echo "    kubectl logs -n ${NAMESPACE} -l app=${DEPLOY} --tail=50"
    ROLLOUT_FAILED=1
  fi
done

# ═══════════════════════════════════════════════════════════════════
# 阶段 6：验证
# ═══════════════════════════════════════════════════════════════════
info "阶段 6：部署结果验证"
echo ""
kubectl get pods -n "$NAMESPACE"
echo ""

# 确认 Worker Pod 未设置 runtimeClassName（依赖 CDI 隔离而非 RuntimeClass）
RUNTIME_CHECK=$(kubectl get pods -n "$NAMESPACE" \
  -l "app=${DECODE_DEPLOY}" \
  -o jsonpath='{.items[0].spec.runtimeClassName}' 2>/dev/null || echo "")
if [[ -z "$RUNTIME_CHECK" ]]; then
  ok "Worker Pod 未设置 runtimeClassName（正确：依赖 CDI 隔离）✓"
else
  warn "Worker Pod runtimeClassName = '${RUNTIME_CHECK}'（期望为空）"
  warn "runtimeClassName 会绕过 CDI，可能导致 8 卡全可见 → OOM"
fi

echo ""
if [[ $ROLLOUT_FAILED -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}"
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  修复完成！所有 Worker 已就绪                                ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo "  端对端功能验证："
  echo "    bash ${SCRIPT_DIR}/03-test-dynamo.sh"
else
  echo -e "${YELLOW}${BOLD}"
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  修复脚本已执行，但部分 Worker 未在超时内就绪                ║"
  echo "║  请手动检查上方 kubectl 输出或 Pod 日志                      ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo "  排查命令："
  echo "    kubectl get pods -n ${NAMESPACE}"
  echo "    kubectl describe pod -n ${NAMESPACE} <pod-name>"
  echo "    kubectl logs -n ${NAMESPACE} <pod-name> --previous"
fi
