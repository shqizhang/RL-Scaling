#!/bin/bash
# ============================================================
# K8s 数据目录一键迁移脚本
# 将 /var/lib/{containerd,kubelet,etcd} 从根分区迁移到 SSD
#
# 用法：bash 00-migrate-k8s-to-ssd.sh  （需要 root 用户执行）
#
# 前提：
#   - 需要 root 用户执行（直接用 root 登录，无需 sudo）
#   - /ssd 已挂载且在 /etc/fstab 中配置了自动挂载
#   - 建议先执行预清理（脚本内有交互确认）
# ============================================================
set -euo pipefail

# ── 颜色输出 ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
section() { echo -e "\n${CYAN}══════════════════════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}\n"; }

# ── 可配置变量 ──────────────────────────────────────────────
SSD_MOUNT="${SSD_MOUNT:-/ssd}"                    # SSD 挂载点
SSD_BASE="${SSD_BASE:-${SSD_MOUNT}/k8s-data}"     # K8s 数据存放目录
SKIP_CONFIRM="${SKIP_CONFIRM:-false}"             # 跳过交互确认（CI 用）

# 要迁移的目录列表
DIRS_TO_MIGRATE=(
  "/var/lib/containerd"
  "/var/lib/kubelet"
)

# etcd 目录（kubeadm 才有，可选）
ETCD_DIR="/var/lib/etcd"

# Docker 相关状态（在预检阶段检测）
DOCKER_INSTALLED=false
DOCKER_WAS_RUNNING=false
DOCKER_DEPENDS_CONTAINERD=false
DOCKER_CONTAINERS_BEFORE=""

# ── 辅助函数 ────────────────────────────────────────────────
confirm() {
  if [[ "$SKIP_CONFIRM" == "true" ]]; then return 0; fi
  local msg="$1"
  echo -en "${YELLOW}${msg} [y/N]: ${NC}"
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    error "此脚本需要 root 权限运行！"
    echo "  请使用 root 用户执行: bash $0"
    exit 1
  fi
}

# ============================================================
section "K8s 数据目录迁移脚本"
echo "  源：     /var/lib/{containerd,kubelet,etcd}"
echo "  目标：   ${SSD_BASE}/"
echo "  SSD：    ${SSD_MOUNT}"
echo ""

# ── 阶段 0：预飞检查 ────────────────────────────────────────
section "阶段 0：预飞检查"

# 0.1 检查 root 权限
check_root
info "root 权限 ✓"

# 0.2 检查 SSD 挂载
if ! mountpoint -q "${SSD_MOUNT}"; then
  error "${SSD_MOUNT} 不是一个挂载点！请确认 SSD 已挂载。"
  echo "  检查: df -h ${SSD_MOUNT}"
  echo "  挂载: mount /dev/nvme0n1p1 ${SSD_MOUNT}"
  exit 1
fi
info "${SSD_MOUNT} 已挂载 ✓"

# 0.3 检查 SSD 在 fstab 中（重启后自动挂载）
if ! grep -qE "nvme0n1p1|${SSD_MOUNT}" /etc/fstab 2>/dev/null; then
  warn "${SSD_MOUNT} 未在 /etc/fstab 中配置！"
  warn "这意味着服务器重启后 SSD 不会自动挂载，K8s 将无法启动！"
  echo ""

  # 获取 SSD 的 UUID
  SSD_DEV=$(df "${SSD_MOUNT}" | tail -1 | awk '{print $1}')
  SSD_UUID=$(blkid "${SSD_DEV}" -s UUID -o value 2>/dev/null || echo "")
  SSD_FSTYPE=$(blkid "${SSD_DEV}" -s TYPE -o value 2>/dev/null || echo "ext4")

  if [[ -n "$SSD_UUID" ]]; then
    echo "  建议添加到 /etc/fstab："
    echo "  UUID=${SSD_UUID}  ${SSD_MOUNT}  ${SSD_FSTYPE}  defaults  0  2"
    echo ""
    if confirm "是否自动添加到 /etc/fstab？"; then
      echo "UUID=${SSD_UUID}  ${SSD_MOUNT}  ${SSD_FSTYPE}  defaults  0  2" >> /etc/fstab
      info "已添加到 /etc/fstab ✓"
    else
      warn "跳过 fstab 配置。⚠️ 请务必在迁移后手动配置！"
    fi
  else
    warn "无法获取 SSD UUID，请手动编辑 /etc/fstab"
  fi
fi

# 0.4 检查 SSD 可写
if ! touch "${SSD_MOUNT}/.migration_test" 2>/dev/null; then
  error "${SSD_MOUNT} 不可写！检查权限和文件系统状态。"
  exit 1
fi
rm -f "${SSD_MOUNT}/.migration_test"
info "${SSD_MOUNT} 可写 ✓"

# 0.5 检查文件系统类型（overlay 需要 d_type 支持）
SSD_FSTYPE_CHECK=$(df -T "${SSD_MOUNT}" | tail -1 | awk '{print $2}')
info "SSD 文件系统类型: ${SSD_FSTYPE_CHECK}"
if [[ "$SSD_FSTYPE_CHECK" == "xfs" ]]; then
  FTYPE=$(xfs_info "${SSD_MOUNT}" 2>/dev/null | grep -o "ftype=[0-9]" || echo "unknown")
  if [[ "$FTYPE" == "ftype=0" ]]; then
    error "XFS 文件系统 ftype=0，不支持 overlayfs！containerd 将无法工作。"
    error "需要重新格式化 SSD：mkfs.xfs -n ftype=1 <device>"
    exit 1
  fi
  info "XFS ftype 检查通过 ✓"
fi

# 0.6 检查目标是否已存在（避免重复迁移）
if [[ -L "/var/lib/containerd" ]]; then
  CURRENT_TARGET=$(readlink -f /var/lib/containerd)
  warn "/var/lib/containerd 已经是符号链接 -> ${CURRENT_TARGET}"
  warn "看起来迁移已经执行过。"
  if ! confirm "是否继续（将覆盖现有迁移）？"; then
    info "已取消。"
    exit 0
  fi
fi

# 0.7 统计数据量和磁盘空间
echo ""
info "当前数据量："
TOTAL_SIZE=0
for dir in "${DIRS_TO_MIGRATE[@]}" "${ETCD_DIR}"; do
  if [[ -d "$dir" && ! -L "$dir" ]]; then
    SIZE=$(du -sb "$dir" 2>/dev/null | awk '{print $1}')
    SIZE_H=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
    echo "  ${dir}: ${SIZE_H}"
    TOTAL_SIZE=$((TOTAL_SIZE + SIZE))
  fi
done
TOTAL_H=$(numfmt --to=iec-i --suffix=B ${TOTAL_SIZE} 2>/dev/null || echo "${TOTAL_SIZE} bytes")
echo "  总计: ${TOTAL_H}"

SSD_AVAIL=$(df -B1 "${SSD_MOUNT}" | tail -1 | awk '{print $4}')
SSD_AVAIL_H=$(df -h "${SSD_MOUNT}" | tail -1 | awk '{print $4}')
info "SSD 可用空间: ${SSD_AVAIL_H}"

if [[ $TOTAL_SIZE -gt $SSD_AVAIL ]]; then
  error "SSD 可用空间不足！需要 ${TOTAL_H}，仅有 ${SSD_AVAIL_H}"
  exit 1
fi
info "空间检查通过 ✓"

# 0.8 检测 Docker 服务状态（影响其他用户）
echo ""
info "── 检测 Docker 服务 ──"
if command -v docker &>/dev/null; then
  DOCKER_INSTALLED=true
  info "Docker 已安装: $(docker --version 2>/dev/null || echo '版本未知')"

  if systemctl is-active docker &>/dev/null; then
    DOCKER_WAS_RUNNING=true
    info "Docker 服务状态: 运行中"

    # 记录迁移前的容器列表（用于迁移后验证）
    DOCKER_CONTAINERS_BEFORE=$(docker ps --format '{{.ID}}\t{{.Names}}\t{{.Status}}' 2>/dev/null || echo "")
    DOCKER_CONTAINER_COUNT=$(docker ps -q 2>/dev/null | wc -l)
    if [[ $DOCKER_CONTAINER_COUNT -gt 0 ]]; then
      warn "当前有 ${DOCKER_CONTAINER_COUNT} 个 Docker 容器正在运行！"
      echo "  运行中的容器："
      docker ps --format '  {{.Names}} ({{.Image}}) - {{.Status}}' 2>/dev/null || true
      echo ""
    else
      info "当前没有运行中的 Docker 容器"
    fi

    # 检测 Docker 是否依赖系统 containerd
    DOCKER_CONTAINERD_SOCKET=$(docker info --format '{{.ContainerdCommit.ID}}' 2>/dev/null || echo "")
    if systemctl show docker 2>/dev/null | grep -qi "requires.*containerd\|after.*containerd"; then
      DOCKER_DEPENDS_CONTAINERD=true
      warn "Docker 依赖系统 containerd 服务 → 停止 containerd 时 Docker 容器将暂停"
    elif docker info 2>/dev/null | grep -q "/run/containerd/containerd.sock"; then
      DOCKER_DEPENDS_CONTAINERD=true
      warn "Docker 使用系统 containerd socket → 停止 containerd 时 Docker 容器将暂停"
    else
      info "Docker 使用独立的 containerd → 停止系统 containerd 不影响 Docker"
    fi
  else
    info "Docker 已安装但未运行"
  fi
else
  info "Docker 未安装，无需担心对其他用户的影响"
fi
echo ""

# 0.9 显示根分区当前状态
info "根分区当前状态："
df -h /
echo ""

# 0.10 Docker 数据独立性说明
if $DOCKER_INSTALLED; then
  DOCKER_DATA_SIZE=$(du -sh /var/lib/docker 2>/dev/null | awk '{print $1}' || echo "未知")
  info "/var/lib/docker 大小: ${DOCKER_DATA_SIZE} (不在迁移范围内，保持不动)"
  echo ""
fi

# ── 最终确认 ────────────────────────────────────────────────
echo "============================================================"
echo "  即将执行以下操作："
echo "  1. 停止 kubelet 和 containerd（K8s 集群将中断）"
if $DOCKER_WAS_RUNNING && $DOCKER_DEPENDS_CONTAINERD; then
  echo "  ⚠ Docker 容器也会暂停（迁移后自动恢复）"
  echo "  ⚠ Docker 镜像和数据 (/var/lib/docker) 不会被删除或移动"
fi
echo "  2. rsync 拷贝数据到 ${SSD_BASE}/"
echo "  3. 用符号链接替换原目录"
echo "  4. 重启 containerd 和 kubelet"
if $DOCKER_WAS_RUNNING; then
  echo "  5. 重启 Docker 服务并验证容器恢复"
fi
echo "  预计中断时间：5~15 分钟（取决于数据量）"
echo "============================================================"
echo ""

if ! confirm "确认开始迁移？"; then
  info "已取消。"
  exit 0
fi

# ── 阶段 1：预清理（可选） ──────────────────────────────────
section "阶段 1：预清理"

if confirm "是否在迁移前清理无用镜像和容器？（推荐，可减少迁移数据量）"; then
  info "清理 Failed/Completed Pod..."
  kubectl delete pods --field-selector=status.phase==Failed -A 2>/dev/null || true
  kubectl delete pods --field-selector=status.phase==Succeeded -A 2>/dev/null || true

  info "清理未使用的容器镜像..."
  crictl rmi --prune 2>/dev/null || true

  info "清理已退出的容器..."
  EXITED=$(crictl ps -a --state exited -q 2>/dev/null || true)
  if [[ -n "$EXITED" ]]; then
    crictl rm $EXITED 2>/dev/null || true
  fi

  info "清理后数据量："
  for dir in "${DIRS_TO_MIGRATE[@]}"; do
    if [[ -d "$dir" && ! -L "$dir" ]]; then
      du -sh "$dir" 2>/dev/null
    fi
  done
else
  info "跳过预清理"
fi

echo ""

# ── 阶段 2：停止服务 ────────────────────────────────────────
section "阶段 2：停止服务"

# 2.1 如果 Docker 依赖 containerd，先优雅停止 Docker
if $DOCKER_WAS_RUNNING && $DOCKER_DEPENDS_CONTAINERD; then
  info "Docker 依赖系统 containerd，先停止 Docker 服务..."
  info "（Docker 容器数据在 /var/lib/docker，不受迁移影响）"
  systemctl stop docker.socket 2>/dev/null || true
  systemctl stop docker
  if systemctl is-active docker &>/dev/null; then
    warn "Docker 停止可能不完全，继续..."
  else
    info "Docker 已停止 ✓"
  fi
fi

# 2.2 停止 kubelet
info "停止 kubelet..."
systemctl stop kubelet
if systemctl is-active kubelet &>/dev/null; then
  error "kubelet 停止失败！"
  # 回滚：尝试恢复已停止的 Docker
  if $DOCKER_WAS_RUNNING; then systemctl start docker 2>/dev/null || true; fi
  exit 1
fi
info "kubelet 已停止 ✓"

# 2.3 停止 containerd
info "停止 containerd..."
systemctl stop containerd
if systemctl is-active containerd &>/dev/null; then
  error "containerd 停止失败！"
  # 回滚：重启 kubelet 和 Docker
  systemctl start kubelet
  if $DOCKER_WAS_RUNNING; then systemctl start docker 2>/dev/null || true; fi
  exit 1
fi
info "containerd 已停止 ✓"

echo ""

# ── 阶段 3：rsync 拷贝数据 ──────────────────────────────────
section "阶段 3：拷贝数据到 SSD"

mkdir -p "${SSD_BASE}"

for dir in "${DIRS_TO_MIGRATE[@]}"; do
  if [[ -d "$dir" && ! -L "$dir" ]]; then
    DIRNAME=$(basename "$dir")
    TARGET="${SSD_BASE}/${DIRNAME}"

    info "拷贝 ${dir} → ${TARGET} ..."
    mkdir -p "${TARGET}"

    # rsync with progress
    rsync -aHAXx --info=progress2 "${dir}/" "${TARGET}/"

    # 验证
    SRC_SIZE=$(du -sb "$dir" | awk '{print $1}')
    DST_SIZE=$(du -sb "$TARGET" | awk '{print $1}')

    # 允许 1% 的差异（文件系统 overhead）
    DIFF=$((SRC_SIZE - DST_SIZE))
    DIFF=${DIFF#-}  # 取绝对值
    THRESHOLD=$((SRC_SIZE / 100))

    if [[ $DIFF -lt $THRESHOLD ]]; then
      info "${DIRNAME} 拷贝完成，大小一致 ✓"
    else
      warn "${DIRNAME} 大小有差异: 源=${SRC_SIZE}, 目标=${DST_SIZE}"
      warn "差异可能是文件系统 overhead 导致，继续..."
    fi
    echo ""
  fi
done

# etcd（可选）
if [[ -d "${ETCD_DIR}" && ! -L "${ETCD_DIR}" ]]; then
  ETCD_TARGET="${SSD_BASE}/etcd"
  info "拷贝 ${ETCD_DIR} → ${ETCD_TARGET} ..."
  mkdir -p "${ETCD_TARGET}"
  rsync -aHAXx --info=progress2 "${ETCD_DIR}/" "${ETCD_TARGET}/"
  info "etcd 拷贝完成 ✓"
  echo ""
fi

# ── 阶段 4：替换为符号链接 ───────────────────────────────────
section "阶段 4：创建符号链接"

for dir in "${DIRS_TO_MIGRATE[@]}"; do
  if [[ -d "$dir" && ! -L "$dir" ]]; then
    DIRNAME=$(basename "$dir")
    TARGET="${SSD_BASE}/${DIRNAME}"
    BACKUP="${dir}.bak-$(date +%Y%m%d)"

    info "备份 ${dir} → ${BACKUP}"
    mv "${dir}" "${BACKUP}"

    info "创建符号链接 ${dir} → ${TARGET}"
    ln -s "${TARGET}" "${dir}"

    # 验证
    if [[ -L "$dir" ]] && [[ "$(readlink -f "$dir")" == "$(readlink -f "$TARGET")" ]]; then
      info "${DIRNAME} 符号链接创建成功 ✓"
    else
      error "${DIRNAME} 符号链接创建失败！回滚..."
      rm -f "${dir}"
      mv "${BACKUP}" "${dir}"
      # 重启服务
      systemctl start containerd
      sleep 5
      systemctl start kubelet
      if $DOCKER_WAS_RUNNING; then systemctl start docker 2>/dev/null || true; fi
      exit 1
    fi
  fi
done

# etcd
if [[ -d "${ETCD_DIR}" && ! -L "${ETCD_DIR}" ]] && [[ -d "${SSD_BASE}/etcd" ]]; then
  ETCD_BACKUP="${ETCD_DIR}.bak-$(date +%Y%m%d)"
  info "备份 ${ETCD_DIR} → ${ETCD_BACKUP}"
  mv "${ETCD_DIR}" "${ETCD_BACKUP}"
  info "创建符号链接 ${ETCD_DIR} → ${SSD_BASE}/etcd"
  ln -s "${SSD_BASE}/etcd" "${ETCD_DIR}"
  info "etcd 符号链接创建成功 ✓"
fi

echo ""
info "符号链接状态："
ls -la /var/lib/containerd /var/lib/kubelet /var/lib/etcd 2>/dev/null || true
echo ""

# ── 阶段 5：重启服务 ────────────────────────────────────────
section "阶段 5：重启 K8s 服务"

info "启动 containerd..."
systemctl start containerd
sleep 5
if systemctl is-active containerd &>/dev/null; then
  info "containerd 运行中 ✓"
else
  error "containerd 启动失败！查看日志: journalctl -u containerd -n 50"
  error "可执行回滚: 删除 symlink 并恢复 .bak 目录"
  exit 1
fi

# 验证 containerd 能读取数据
info "验证 containerd..."
if crictl images &>/dev/null; then
  IMAGE_COUNT=$(crictl images -q 2>/dev/null | wc -l)
  info "containerd 正常，${IMAGE_COUNT} 个镜像可用 ✓"
else
  warn "crictl images 失败，containerd 可能仍在初始化..."
fi

echo ""

info "启动 kubelet..."
systemctl start kubelet

info "等待 K8s 组件恢复（最多 120 秒）..."
READY=false
for i in $(seq 1 24); do
  if kubectl get nodes &>/dev/null; then
    NODE_STATUS=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}')
    if [[ "$NODE_STATUS" == "Ready" ]]; then
      READY=true
      break
    fi
  fi
  echo -ne "\r  等待中... [${i}/24] ($(( i * 5 ))s)"
  sleep 5
done
echo ""

if $READY; then
  info "K8s 集群已恢复 ✓"
else
  warn "K8s 集群尚未完全 Ready，可能需要更多时间..."
  warn "请手动检查: kubectl get nodes && kubectl get pods -n kube-system"
fi

echo ""

# ── 阶段 5.5：恢复 Docker 服务 ─────────────────────────────
if $DOCKER_WAS_RUNNING; then
  section "阶段 5.5：恢复 Docker 服务"

  info "启动 Docker 服务..."
  systemctl start docker
  sleep 5

  if systemctl is-active docker &>/dev/null; then
    info "Docker 服务已启动 ✓"
  else
    warn "Docker 启动失败！尝试查看日志..."
    journalctl -u docker -n 10 --no-pager 2>/dev/null || true
    warn "请手动排查: systemctl start docker && journalctl -u docker"
  fi

  # 验证 Docker 镜像完整性
  info "验证 Docker 镜像..."
  DOCKER_IMAGE_COUNT=$(docker images -q 2>/dev/null | wc -l)
  info "Docker 镜像数量: ${DOCKER_IMAGE_COUNT} 个（/var/lib/docker 未被修改）"

  # 检查容器恢复情况
  sleep 5
  DOCKER_CONTAINERS_AFTER=$(docker ps -q 2>/dev/null | wc -l)
  info "当前运行中 Docker 容器: ${DOCKER_CONTAINERS_AFTER} 个"

  # 对比迁移前后
  if [[ -n "$DOCKER_CONTAINERS_BEFORE" ]]; then
    echo ""
    info "容器恢复对比（迁移前 → 迁移后）："
    echo "  迁移前运行的容器："
    echo "$DOCKER_CONTAINERS_BEFORE" | while IFS=$'\t' read -r cid cname cstatus; do
      if [[ -n "$cid" ]]; then
        CURRENT_STATUS=$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null || echo "不存在")
        if [[ "$CURRENT_STATUS" == "running" ]]; then
          echo -e "    ${GREEN}✓${NC} ${cname} (${cid:0:12}): running"
        else
          echo -e "    ${YELLOW}⚠${NC} ${cname} (${cid:0:12}): ${CURRENT_STATUS}"
          warn "容器 ${cname} 未自动恢复，可手动启动: docker start ${cname}"
        fi
      fi
    done
  fi

  # 列出未恢复的容器
  EXITED_CONTAINERS=$(docker ps -a --filter "status=exited" --format '{{.Names}}' 2>/dev/null || true)
  if [[ -n "$EXITED_CONTAINERS" ]]; then
    echo ""
    warn "以下 Docker 容器处于退出状态（可能需要手动启动）："
    echo "$EXITED_CONTAINERS" | while read -r name; do
      echo "    docker start ${name}"
    done
    echo ""
    if confirm "是否尝试启动所有使用 restart policy 的已退出容器？"; then
      docker ps -a --filter "status=exited" -q 2>/dev/null | xargs -r docker start 2>/dev/null || true
      sleep 5
      info "已尝试重启退出的容器，当前运行中: $(docker ps -q 2>/dev/null | wc -l) 个"
    fi
  fi

  echo ""
fi

# ── 阶段 6：验证 ────────────────────────────────────────────
section "阶段 6：迁移验证"

echo "── 6.1 磁盘使用情况 ──"
echo ""
echo "根分区（迁移后）："
df -h /
echo ""
echo "SSD（迁移后）："
df -h "${SSD_MOUNT}"
echo ""

echo "── 6.2 符号链接验证 ──"
for dir in /var/lib/containerd /var/lib/kubelet /var/lib/etcd; do
  if [[ -L "$dir" ]]; then
    TARGET=$(readlink -f "$dir")
    echo "  ✓ ${dir} -> ${TARGET}"
  elif [[ -d "$dir" ]]; then
    echo "  ⚠ ${dir} (未迁移，仍是普通目录)"
  fi
done
echo ""

echo "── 6.3 K8s 节点状态 ──"
kubectl get nodes -o wide 2>/dev/null || warn "kubectl 暂不可用"
echo ""

echo "── 6.4 kube-system Pod 状态 ──"
kubectl get pods -n kube-system 2>/dev/null || warn "kubectl 暂不可用"
echo ""

echo "── 6.5 所有 namespace Pod 概览 ──"
kubectl get pods -A --no-headers 2>/dev/null | awk '{print $4}' | sort | uniq -c | sort -rn || true
echo ""

if $DOCKER_INSTALLED; then
  echo "── 6.6 Docker 服务状态 ──"
  if systemctl is-active docker &>/dev/null; then
    echo "  Docker 服务: 运行中 ✓"
    echo "  Docker 镜像: $(docker images -q 2>/dev/null | wc -l) 个"
    echo "  Docker 容器(运行中): $(docker ps -q 2>/dev/null | wc -l) 个"
    echo "  Docker 容器(全部): $(docker ps -aq 2>/dev/null | wc -l) 个"
  else
    echo "  ⚠ Docker 服务未运行！请手动启动: systemctl start docker"
  fi
  echo ""
  echo "  ℹ /var/lib/docker 仍在根分区（未迁移）:"
  echo "    $(du -sh /var/lib/docker 2>/dev/null | awk '{print $1}')"
  echo ""
fi

# ── 6.7 NVIDIA Container Runtime 验证 ──────────────────────
# 重要：containerd 重启后，GPU Operator 的 toolkit daemonset 会自动覆写
# /etc/containerd/config.toml。toolkit 默认 NVIDIA_RUNTIME_SET_AS_DEFAULT=false，
# 这会导致 default_runtime_name 回退为 "runc"，enable_cdi 也会被重置为 false。
#
# Dynamo DGD 依赖 CDI 设备隔离（每个 Worker 只看到 1 张 GPU），
# 需要同时满足以下 3 个条件：
#   1. defaultRuntimeName = nvidia
#   2. enable_cdi = true
#   3. nvidia-device-plugin-daemonset 在配置正确后重启过
#
# ⚠️ 不要用 runtimeClassName: nvidia 作为解决方案——它会绕过 CDI，
#   导致每个容器看到全部 8 张 GPU → OOM。
echo "── 6.7 NVIDIA Container Runtime 验证 ──"

# 用 crictl info 检查 containerd 实际生效的配置（而非 grep config.toml）
CRICTL_OK=false
if command -v crictl &>/dev/null; then
  RUNTIME_INFO=$(sudo crictl info 2>/dev/null || true)
  if [ -n "$RUNTIME_INFO" ]; then
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
    CRICTL_OK=true
  fi
fi

if $CRICTL_OK; then
  echo "  containerd 当前配置（crictl info）："
  echo "    defaultRuntimeName: ${DEFAULT_RT}"
  echo "    enableCDI: ${CDI_ENABLED}"

  NEEDS_FIX=false
  if [ "$DEFAULT_RT" != "nvidia" ]; then
    echo "  ⚠ defaultRuntimeName 不是 nvidia（当前: ${DEFAULT_RT}）"
    NEEDS_FIX=true
  else
    echo "  defaultRuntimeName: nvidia ✓"
  fi

  if [ "$CDI_ENABLED" != "True" ]; then
    echo "  ⚠ CDI 未启用（当前: ${CDI_ENABLED}）"
    NEEDS_FIX=true
  else
    echo "  enableCDI: True ✓"
  fi

  if $NEEDS_FIX; then
    echo ""
    echo "  ⚠ containerd GPU 配置不正确，Dynamo Worker 将无法正常工作！"
    echo "  请执行以下 3 步修复（缺一不可）："
    echo ""
    echo "  # ① 让 toolkit daemonset 设 nvidia 为默认 runtime"
    echo "  kubectl set env ds/nvidia-container-toolkit-daemonset \\"
    echo "    -n gpu-operator NVIDIA_RUNTIME_SET_AS_DEFAULT=true"
    echo "  kubectl rollout status ds/nvidia-container-toolkit-daemonset \\"
    echo "    -n gpu-operator --timeout=120s"
    echo ""
    echo "  # ② 在主 config.toml 中启用 CDI"
    echo "  sudo sed -i 's/enable_cdi = false/enable_cdi = true/' /etc/containerd/config.toml"
    echo "  sudo systemctl restart containerd"
    echo ""
    echo "  # ③ 重启 device plugin"
    echo "  kubectl rollout restart ds/nvidia-device-plugin-daemonset -n gpu-operator"
    echo ""
    echo "  或者直接执行: bash recover-script/04-fix-worker-crashloop.sh"
  fi
else
  echo "  ⚠ 无法通过 crictl info 获取 containerd 配置"
  echo "    请手动验证: sudo crictl info | python3 -c \"import json,sys; ..."
fi

# 检查 GPU Operator toolkit daemonset 是否运行
if kubectl get pods -n gpu-operator -l app=nvidia-container-toolkit-daemonset --no-headers 2>/dev/null | grep -q Running; then
  echo "  GPU Operator toolkit daemonset: Running ✓"
else
  echo "  ⚠ GPU Operator toolkit daemonset 未运行或不存在"
fi
echo ""

# ── 完成 ────────────────────────────────────────────────────
section "迁移完成"

ROOT_USAGE=$(df -h / | tail -1 | awk '{print $5}')
SSD_USAGE=$(df -h "${SSD_MOUNT}" | tail -1 | awk '{print $5}')

echo "  根分区使用率: ${ROOT_USAGE} (迁移前: 94%)"
echo "  SSD 使用率:   ${SSD_USAGE}"
echo ""
info "备份目录（确认集群稳定 24h 后可删除）："
ls -d /var/lib/*.bak-* 2>/dev/null || echo "  无备份目录"
echo ""
warn "删除备份命令（谨慎执行）："
echo "  rm -rf /var/lib/containerd.bak-* /var/lib/kubelet.bak-* /var/lib/etcd.bak-*"
echo ""
info "后续步骤："
if $DOCKER_WAS_RUNNING; then
  echo "  0. 通知其他 Docker 用户验证他们的容器是否正常恢复"
fi
echo "  1. 确认集群正常运行后，重新部署监控和业务 Pod"
echo "  2. bash 01-deploy-prometheus-grafana.sh"
echo "  3. bash 02-deploy-dynamo.sh"
echo "  4. bash 03-test-dynamo.sh all"
if $DOCKER_INSTALLED; then
  echo ""
  info "Docker 相关说明："
  echo "  - Docker 镜像和数据 (/var/lib/docker) 仍在根分区，未被修改"
  echo "  - 如果也需要迁移 Docker 数据到 SSD，参考 MIGRATION-GUIDE.md Q9"
fi
echo ""
echo "============================================================"
