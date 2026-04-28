#!/bin/bash
# =============================================================================
# 00-upgrade-driver-apt.sh — NVIDIA 驱动 + CUDA Toolkit 升级 (apt 单源版)
#
# 设计原则 (从 Upgrade_Issue_Analysis_Report.md §10 提炼):
#   1. 单源驱动管理:  apt cuda-drivers-NNN 元包, 不混用 .run
#   2. 冻结内核:      升级期间 hold linux-image-* 防 reboot 后内核漂移
#   3. Operator 解耦: 先 freeze GPU Operator (driver-DaemonSet 删除), 再动主机驱动
#   4. 三处校验:      kernel module / NVML / nvidia-smi 输出版本必须完全一致
#   5. purge 必跟 reinstall: 不留时间窗口
#   6. 不 reboot 优先: 在线 modprobe -r/modprobe 切换
#   7. 失败立即停: 任何阶段失败均 abort, 不推进到 reboot
#
# 适用环境:
#   - Ubuntu 22.04 + NVIDIA GPU (Ampere/Ada/Hopper/Blackwell)
#   - K8s 单节点, GPU Operator helm release 名为 gpu-operator (driver.enabled=false)
#   - cuda repo (cuda-keyring) 已或自动安装
#
# 用法:
#   sudo bash 00-upgrade-driver-apt.sh --check          # 干跑, 只显示计划
#   sudo bash 00-upgrade-driver-apt.sh --phase1         # 升级 (in-place, 不 reboot)
#   sudo bash 00-upgrade-driver-apt.sh --phase1 --reboot # 升级后 reboot
#   sudo bash 00-upgrade-driver-apt.sh --phase2         # reboot 后唤醒 GPU Operator
#   sudo bash 00-upgrade-driver-apt.sh --rollback       # 回滚到上次备份的版本
#
# 环境变量 (可覆盖默认值):
#   TARGET_DRIVER_MAJOR=595           主驱动版本号 (apt: cuda-drivers-${MAJOR})
#   TARGET_CUDA_APT=13-2              CUDA toolkit apt 后缀 (cuda-toolkit-${X})
#   GPU_OPERATOR_NS=gpu-operator      GPU Operator 所在 ns
#   ASSUME_YES=yes                    跳过所有交互
# =============================================================================
set -Eeuo pipefail

# ── 颜色 ──────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${BLUE}══════════════════════════════════════════════════════════${NC}"
          echo -e "${BLUE}  $*${NC}"
          echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"; }
die()   { error "$*"; exit 1; }

# ── 默认参数 ──────────────────────────────────────────────────────────────────
TARGET_DRIVER_MAJOR="${TARGET_DRIVER_MAJOR:-595}"
TARGET_CUDA_APT="${TARGET_CUDA_APT:-13-2}"
GPU_OPERATOR_NS="${GPU_OPERATOR_NS:-gpu-operator}"
ASSUME_YES="${ASSUME_YES:-no}"
DO_REBOOT="no"

CUDA_REPO_DEB_URL="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb"
SENTINEL="/var/lib/nvidia-upgrade.sentinel"
BACKUP_DIR="/var/backup/nvidia-upgrade-$(date +%Y%m%d-%H%M%S)"
LOG_FILE="/var/log/nvidia-upgrade.log"

# ── 解析参数 ──────────────────────────────────────────────────────────────────
MODE=""
for arg in "$@"; do
  case "$arg" in
    --check)    MODE="check" ;;
    --phase1)   MODE="phase1" ;;
    --phase2)   MODE="phase2" ;;
    --rollback) MODE="rollback" ;;
    --reboot)   DO_REBOOT="yes" ;;
    -y|--yes)   ASSUME_YES="yes" ;;
    -h|--help)  sed -n '2,32p' "$0"; exit 0 ;;
    *)          die "未知参数: $arg (可用: --check/--phase1/--phase2/--rollback/--reboot/-y)" ;;
  esac
done
[[ -z "$MODE" ]] && die "必须指定模式: --check | --phase1 | --phase2 | --rollback"

# ── 通用工具 ──────────────────────────────────────────────────────────────────
confirm() {
  [[ "$ASSUME_YES" == "yes" ]] && { info "[ASSUME_YES] 自动确认: $1"; return 0; }
  read -r -p "$(echo -e "${YELLOW}$1 [y/N]: ${NC}")" reply
  [[ "$reply" =~ ^[Yy]$ ]]
}
log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG_FILE"; }
trap 'error "脚本在第 $LINENO 行失败 (上一条命令: $BASH_COMMAND)"; exit 1' ERR

# ── Root 检查 ─────────────────────────────────────────────────────────────────
[[ "$EUID" -eq 0 ]] || die "需要 root: sudo bash $0 $*"

mkdir -p "$BACKUP_DIR" "$(dirname "$LOG_FILE")"
chmod 700 "$BACKUP_DIR"

# ── 探测当前状态 ──────────────────────────────────────────────────────────────
detect_state() {
  RUNNING_KERNEL="$(uname -r)"
  CURR_DRIVER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo none)"
  CURR_NVCC="$(/usr/local/cuda/bin/nvcc --version 2>/dev/null | grep -oP 'release \K[0-9.]+' || echo none)"
  GPU_COUNT="$(lspci -nn 2>/dev/null | grep -ic '\[10de:' || echo 0)"
  K8S_AVAILABLE="no"
  command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1 && K8S_AVAILABLE="yes"
}

print_state() {
  cat <<EOF
─── 当前状态 ──────────────────────────────────────────────
  内核:           $RUNNING_KERNEL
  GPU 设备:       $GPU_COUNT 个 NVIDIA PCI 设备
  当前驱动:       $CURR_DRIVER
  当前 nvcc:      $CURR_NVCC
  K8s 可用:       $K8S_AVAILABLE
─── 升级目标 ──────────────────────────────────────────────
  目标驱动元包:   cuda-drivers-${TARGET_DRIVER_MAJOR}
  目标 CUDA:      cuda-toolkit-${TARGET_CUDA_APT}
  Reboot 策略:    $DO_REBOOT
  备份目录:       $BACKUP_DIR
EOF
}

# ── 三处版本一致性校验 (核心安全护栏) ─────────────────────────────────────────
verify_consistency() {
  local target="$1"   # 主版本号, 如 595
  local kmod proc nvml smi
  kmod="$(modinfo nvidia 2>/dev/null | awk '/^version:/{print $2}' || echo missing)"
  proc="$(awk '/NVRM version/{print $8}' /proc/driver/nvidia/version 2>/dev/null || echo missing)"
  nvml="$(strings /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 2>/dev/null \
            | grep -oE '[5-9][0-9]{2}\.[0-9]+\.[0-9]+' | head -1 || echo missing)"
  smi="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo missing)"

  echo "  kmod($kmod) proc($proc) nvml($nvml) smi($smi)  期望主版本: $target"

  for v in "$kmod" "$proc" "$nvml" "$smi"; do
    [[ "$v" == missing ]] && { error "组件缺失: kmod=$kmod proc=$proc nvml=$nvml smi=$smi"; return 1; }
    [[ "${v%%.*}" == "$target" ]] || { error "版本不一致: $v 不属于主版本 $target"; return 1; }
  done

  # 还要校验 .ko 装在当前内核
  local ko_path="/lib/modules/$RUNNING_KERNEL/updates/dkms/nvidia.ko"
  [[ -f "$ko_path" ]] || { error "当前内核 $RUNNING_KERNEL 没有 nvidia.ko ($ko_path 不存在)"; return 1; }

  # nvidia-drm 必须在 (上次踩坑点)
  [[ -f "/lib/modules/$RUNNING_KERNEL/updates/dkms/nvidia-drm.ko" ]] \
    || { error "缺少 nvidia-drm.ko — DKMS 可能 NV_EXCLUDE_BUILD_MODULES 排除了它"; return 1; }

  return 0
}

# =============================================================================
# MODE: check (干跑)
# =============================================================================
if [[ "$MODE" == "check" ]]; then
  step "Phase 0: 环境检查 (--check 干跑)"
  detect_state
  print_state

  echo "─── apt 旧驱动包 (将在 phase1 被 purge) ────────────────"
  dpkg -l 2>/dev/null | awk '/^.i.*nvidia-driver-[0-9]/ || /^.i.*libnvidia-.*-[0-9]/{print "  "$2"  "$3}'  || echo "  (无)"

  echo "─── DKMS 状态 ─────────────────────────────────────────"
  dkms status 2>/dev/null | grep -i nvidia | sed 's/^/  /' || echo "  (无)"

  echo "─── GPU Operator ──────────────────────────────────────"
  if [[ "$K8S_AVAILABLE" == yes ]]; then
    kubectl -n "$GPU_OPERATOR_NS" get deploy,ds 2>/dev/null | sed 's/^/  /' || echo "  (未部署)"
  else
    echo "  (K8s 不可用)"
  fi

  echo "─── 磁盘空间 ──────────────────────────────────────────"
  df -h /usr /var /boot 2>/dev/null | sed 's/^/  /'
  echo
  info "干跑完成。如要执行升级: sudo bash $0 --phase1"
  exit 0
fi

# =============================================================================
# MODE: rollback
# =============================================================================
if [[ "$MODE" == "rollback" ]]; then
  step "Rollback: 恢复到上次备份的驱动版本"
  LAST_BACKUP="$(ls -1d /var/backup/nvidia-upgrade-* 2>/dev/null | tail -1)"
  [[ -z "$LAST_BACKUP" ]] && die "找不到任何备份目录"
  [[ -f "$LAST_BACKUP/dpkg-nvidia.list" ]] || die "备份不完整: $LAST_BACKUP"

  warn "将回滚到: $LAST_BACKUP"
  cat "$LAST_BACKUP/dpkg-nvidia.list" | head -20
  confirm "确认回滚?" || die "用户取消"

  OLD_MAJOR="$(awk '/cuda-drivers-[0-9]+/{ if (match($0,/cuda-drivers-([0-9]+)/,m)) print m[1]; exit }' "$LAST_BACKUP/dpkg-nvidia.list")"
  [[ -z "$OLD_MAJOR" ]] && die "无法从备份解析旧主版本号"

  apt-mark unhold $(dpkg -l | awk '/^hi.*nvidia/{print $2}') 2>/dev/null || true
  apt-get purge -y '^nvidia-.*-[0-9]+.*' '^libnvidia-.*-[0-9]+.*' '^cuda-drivers-[0-9]+$' || true
  apt-get autoremove -y --purge || true
  apt-get install -y "cuda-drivers-${OLD_MAJOR}"
  apt-mark hold "cuda-drivers-${OLD_MAJOR}"
  info "回滚完成。请 reboot 或执行: sudo bash $0 --phase2"
  exit 0
fi

# =============================================================================
# MODE: phase1 — 主升级流程
# =============================================================================
if [[ "$MODE" == "phase1" ]]; then
  step "Phase 0: 环境检查"
  detect_state
  print_state
  [[ "$GPU_COUNT" -eq 0 ]] && die "未检测到 NVIDIA GPU (lspci 找不到 10de: 设备)"

  log "phase1 start: kernel=$RUNNING_KERNEL driver=$CURR_DRIVER target=$TARGET_DRIVER_MAJOR"
  confirm "继续升级到 cuda-drivers-${TARGET_DRIVER_MAJOR} + cuda-toolkit-${TARGET_CUDA_APT}?" \
    || die "用户取消"

  # ── 备份当前状态 ─────────────────────────────────────────
  step "Phase 1: 备份当前驱动 / 内核状态"
  dpkg -l | grep -iE 'nvidia|cuda' > "$BACKUP_DIR/dpkg-nvidia.list" || true
  dkms status > "$BACKUP_DIR/dkms.status" 2>&1 || true
  uname -a > "$BACKUP_DIR/uname.txt"
  nvidia-smi > "$BACKUP_DIR/nvidia-smi.before.txt" 2>&1 || true
  cp /proc/driver/nvidia/version "$BACKUP_DIR/proc-nvidia-version.txt" 2>/dev/null || true
  info "备份保存到: $BACKUP_DIR"

  # ── Freeze GPU Operator (规避问题: Operator 重建 DaemonSet 抢驱动) ─────
  step "Phase 2: Freeze GPU Operator"
  if [[ "$K8S_AVAILABLE" == yes ]]; then
    if kubectl -n "$GPU_OPERATOR_NS" get deploy/gpu-operator &>/dev/null; then
      kubectl -n "$GPU_OPERATOR_NS" scale deploy/gpu-operator --replicas=0
      kubectl -n "$GPU_OPERATOR_NS" delete ds -l app.kubernetes.io/managed-by=gpu-operator \
        --ignore-not-found=true --timeout=120s
      info "GPU Operator 已 freeze (deploy=0, driver-DaemonSet 已删除)"
    else
      warn "未发现 GPU Operator deployment, 跳过"
    fi
  else
    warn "K8s 不可用, 跳过 GPU Operator freeze"
  fi

  # ── 冻结内核 (规避问题: reboot 后内核漂移导致 DKMS 没编对版本) ────────
  step "Phase 3: Hold 当前内核"
  apt-mark hold "linux-image-${RUNNING_KERNEL}" "linux-headers-${RUNNING_KERNEL}" \
                linux-image-generic linux-headers-generic 2>/dev/null || true
  info "已 hold linux-image-${RUNNING_KERNEL}"

  # ── 安装 cuda repo + 编译依赖 ───────────────────────────
  step "Phase 4: 安装 cuda-keyring + 编译依赖"
  if ! dpkg -l cuda-keyring &>/dev/null; then
    TMP_DEB="$(mktemp --suffix=.deb)"
    wget -O "$TMP_DEB" "$CUDA_REPO_DEB_URL"
    dpkg -i "$TMP_DEB"
    rm -f "$TMP_DEB"
  fi
  apt-get update
  apt-get install -y "linux-headers-${RUNNING_KERNEL}" \
                     "linux-modules-extra-${RUNNING_KERNEL}" \
                     dkms build-essential

  # ── 卸载所有旧 nvidia 驱动包 (规避问题: apt + .run 混用) ────────────
  step "Phase 5: Purge 所有旧 nvidia 驱动包 (保留 CUDA toolkit / container-toolkit)"
  systemctl stop nvidia-persistenced nvidia-fabricmanager 2>/dev/null || true

  HOLDS="$(dpkg -l | awk '/^hi.*nvidia/{print $2}')"
  [[ -n "$HOLDS" ]] && apt-mark unhold $HOLDS

  # 注意正则: 只匹配 'nvidia-X-NNN' 形式 (主版本号驱动包),
  # 不动 nvidia-container-toolkit / cuda-* / libcuda1
  apt-get purge -y \
    '^nvidia-driver-[0-9]+$'                  '^nvidia-driver-[0-9]+-.*' \
    '^nvidia-dkms-[0-9]+$'                    '^nvidia-dkms-[0-9]+-.*' \
    '^nvidia-kernel-source-[0-9]+$'           '^nvidia-kernel-source-[0-9]+-.*' \
    '^nvidia-kernel-common-[0-9]+$'           '^nvidia-kernel-common-[0-9]+-.*' \
    '^nvidia-utils-[0-9]+$'                   '^nvidia-utils-[0-9]+-.*' \
    '^nvidia-compute-utils-[0-9]+$'           '^nvidia-compute-utils-[0-9]+-.*' \
    '^nvidia-firmware-[0-9]+.*' \
    '^nvidia-fabricmanager-[0-9]+$' \
    '^nvidia-headless-[0-9]+.*' \
    '^libnvidia-.*-[0-9]+$'                   '^libnvidia-.*-[0-9]+-.*' \
    '^xserver-xorg-video-nvidia-[0-9]+.*' \
    '^cuda-drivers-[0-9]+$' \
    'cuda-drivers' 2>/dev/null || true

  apt-get autoremove -y --purge

  # ── 安装目标驱动 (元包一次拉齐所有用户空间 + DKMS) ────────────────────
  step "Phase 6: 安装 cuda-drivers-${TARGET_DRIVER_MAJOR}"
  apt-get install -y "cuda-drivers-${TARGET_DRIVER_MAJOR}"

  # 立刻 hold 防止 unattended-upgrades 改版本
  apt-mark hold \
    "cuda-drivers-${TARGET_DRIVER_MAJOR}" \
    "nvidia-driver-${TARGET_DRIVER_MAJOR}" \
    "nvidia-dkms-${TARGET_DRIVER_MAJOR}" \
    "nvidia-utils-${TARGET_DRIVER_MAJOR}" 2>/dev/null || true

  # ── 验证 DKMS 编到当前内核 (规避问题: 只编到旧 kernel) ────────────────
  step "Phase 7: 验证 DKMS 已编到 $RUNNING_KERNEL"
  if ! dkms status 2>/dev/null | grep -E "nvidia/.*${RUNNING_KERNEL}.*(installed|built)" >/dev/null; then
    warn "DKMS 中未发现 nvidia/* for $RUNNING_KERNEL, 尝试手动编译"
    NV_SRC_VER="$(dkms status 2>/dev/null | awk -F'[/, ]' '/^nvidia\//{print $2; exit}')"
    [[ -z "$NV_SRC_VER" ]] && die "无法从 dkms status 解析 nvidia 源版本"
    dkms install "nvidia/${NV_SRC_VER}" -k "$RUNNING_KERNEL"
  fi
  depmod -a "$RUNNING_KERNEL"

  # 检查 nvidia-drm 是否被排除 (上次踩坑点)
  if ! [[ -f "/lib/modules/$RUNNING_KERNEL/updates/dkms/nvidia-drm.ko" ]]; then
    error "nvidia-drm.ko 缺失。检查 DKMS build log:"
    error "  /var/lib/dkms/nvidia/*/build/make.log"
    error "  关键字: NV_EXCLUDE_BUILD_MODULES"
    error "通常需补: sudo apt-get install -y linux-modules-extra-${RUNNING_KERNEL} 后重装"
    die "缺少 nvidia-drm 模块, 升级中止"
  fi

  # ── 在线切换模块 (规避问题: 强制 reboot) ───────────────────────────
  step "Phase 8: 在线卸载旧模块 + 加载新模块"
  if lsof /dev/nvidia* 2>/dev/null | grep -q .; then
    error "/dev/nvidia* 仍被进程占用:"
    lsof /dev/nvidia* 2>/dev/null
    die "请先停止占用进程, 或加 --reboot 跳过在线切换"
  fi

  if [[ "$DO_REBOOT" != "yes" ]]; then
    modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/dev/null || true
    modprobe nvidia
    modprobe nvidia_modeset
    modprobe nvidia_drm
    modprobe nvidia_uvm
  fi

  # ── 三处一致性校验 (核心护栏) ──────────────────────────────────────
  step "Phase 9: 三处版本一致性校验"
  if [[ "$DO_REBOOT" != "yes" ]]; then
    if ! verify_consistency "$TARGET_DRIVER_MAJOR"; then
      die "一致性校验失败 — 升级中止, 不要 reboot, 检查 /var/log/nvidia-upgrade.log 和备份 $BACKUP_DIR"
    fi
    info "三处一致性校验通过 ✓"
    nvidia-smi
  else
    warn "选择了 --reboot, 跳过在线切换和校验, reboot 后请运行 --phase2"
  fi

  # ── 安装 / 升级 CUDA Toolkit (与驱动解耦) ──────────────────────────
  step "Phase 10: 安装 cuda-toolkit-${TARGET_CUDA_APT}"
  apt-get install -y "cuda-toolkit-${TARGET_CUDA_APT}"
  apt-mark hold "cuda-toolkit-${TARGET_CUDA_APT}" 2>/dev/null || true

  # ── 写入 sentinel ────────────────────────────────────────
  cat > "$SENTINEL" <<EOF
phase1_completed=$(date -Iseconds)
target_driver_major=$TARGET_DRIVER_MAJOR
target_cuda_apt=$TARGET_CUDA_APT
running_kernel=$RUNNING_KERNEL
backup_dir=$BACKUP_DIR
do_reboot=$DO_REBOOT
EOF
  log "phase1 done"

  echo
  if [[ "$DO_REBOOT" == "yes" ]]; then
    warn "5 秒后 reboot. Ctrl-C 取消"; sleep 5
    systemctl reboot
  else
    info "Phase 1 完成, 已在线切换驱动."
    info "下一步: 唤醒 GPU Operator → sudo bash $0 --phase2"
  fi
  exit 0
fi

# =============================================================================
# MODE: phase2 — reboot 后(或在线切换后)唤醒 GPU 栈
# =============================================================================
if [[ "$MODE" == "phase2" ]]; then
  step "Phase 2.1: Post-upgrade 验证"
  detect_state
  print_state

  [[ -f "$SENTINEL" ]] && { info "Sentinel:"; cat "$SENTINEL" | sed 's/^/  /'; }

  if ! verify_consistency "$TARGET_DRIVER_MAJOR"; then
    die "一致性校验失败 — 不要继续, 修复后再跑 phase2 (或 --rollback)"
  fi
  info "驱动状态正常 ✓"
  nvidia-smi

  step "Phase 2.2: 重新配置 nvidia-container-toolkit"
  if command -v nvidia-ctk &>/dev/null; then
    nvidia-ctk runtime configure --runtime=containerd --set-as-default --cdi.enabled=true
    systemctl restart containerd
    sleep 3
  else
    warn "nvidia-ctk 未安装, 跳过 (如需 K8s GPU 支持请装 nvidia-container-toolkit)"
  fi

  step "Phase 2.3: 唤醒 GPU Operator"
  if [[ "$K8S_AVAILABLE" == yes ]] && kubectl -n "$GPU_OPERATOR_NS" get deploy/gpu-operator &>/dev/null; then
    kubectl -n "$GPU_OPERATOR_NS" scale deploy/gpu-operator --replicas=1
    kubectl -n "$GPU_OPERATOR_NS" rollout status deploy/gpu-operator --timeout=300s
    info "等待 device-plugin Ready..."
    for i in $(seq 1 60); do
      ready_gpu="$(kubectl get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}' 2>/dev/null | tr ' ' '\n' | grep -E '^[1-9]' | head -1 || echo '')"
      [[ -n "$ready_gpu" ]] && break
      sleep 5
    done
    kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.'nvidia\.com/gpu'
  else
    warn "K8s 或 GPU Operator 不可用, 跳过"
  fi

  rm -f "$SENTINEL"
  log "phase2 done"
  info "升级完成. 备份: $BACKUP_DIR"
  exit 0
fi
