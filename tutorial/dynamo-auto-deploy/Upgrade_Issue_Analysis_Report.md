# Dynamo 1.0.1 升级事故分析报告

> **环境**: gpu14 (Ubuntu 22.04, 8× RTX 3090, single-node K8s, helm gpu-operator v25.10.1)
> **时间**: 2026-04-25 02:00 — 03:30 UTC
> **执行者**: shengqizhang
> **影响范围**: GPU Operator 全部驱动栈被拆除,`nvidia-smi` 不可用,所有 GPU 工作负载暂停 ~90 min
> **是否影响他人**: 否 (`yixunzhu-dynamo-system` 未被触动)

---

## 1. 时间线

| Time     | 事件                                                              |
| -------- | ----------------------------------------------------------------- |
| 02:02:10 | `cleanup-old.sh --apply` 启动                                     |
| 02:02:11 | Step 1: 删除 2 个 DGD CR — OK                                     |
| 02:02:12 | Step 2: `helm uninstall dynamo-crds` (default ns) — OK,4 个 CRD 因 keep-policy 残留 |
| 02:02:14 | Step 3: 用 `grep -E '(dynamo\|nvidia\.com)'` 删 CRD               |
| 02:02:15 | **误删 `clusterpolicies.nvidia.com`**                             |
| 02:02:16 | **误删 `nvidiadrivers.nvidia.com`**                               |
| 02:02:16 | gpu-operator 收到 CRD-deleted 事件, 拆 DaemonSet (`nvidia-dcgm-exporter`, `nvidia-operator-validator` → Terminating; `nvidia-device-plugin-daemonset` → Completed) |
| 02:02:17 | cleanup 结束,nvidia-smi 已不可用                                  |
| 02:05    | `00-upgrade-cuda.sh` 执行,Stage 0 检测 NVIDIA 失败 → `[ERROR] 未检测到 NVIDIA GPU` |
| 02:15    | 尝试 `helm upgrade gpu-operator --reuse-values` → `kataSandboxDevicePlugin nil pointer` |
| 02:25    | `--reset-then-reuse-values` → `no matches for kind "ClusterPolicy"` (CRD 已删) |
| 02:35    | `helm template ... | awk` 提取 CRD → 缺 `apiVersion`,kubectl 拒绝 |
| 02:45    | `sudo kubectl apply` → `dial localhost:8080 connection refused` (root 无 kubeconfig) |
| 02:55    | **正确做法**: `helm pull --untar` 拿原始 CRD,普通用户 `kubectl apply --server-side -f gpu-operator/crds/` → 成功 |
| 03:00    | `helm upgrade gpu-operator --reuse-values --set kataSandboxDevicePlugin.enabled=false ...` → 成功 |
| 03:10    | gpu-operator 重建 DaemonSet,nvidia-smi 恢复                       |
| 03:30    | Phase 1-3: `apt-mark hold gpu-operator`, `.run --silent --dkms` 安装 595, apt 升 cuda-toolkit-13-2 |
| 03:50    | reboot                                                            |
| 04:05    | reboot 后 `nvidia-smi` 报 `Driver/library version mismatch NVML 595.58` |
| 04:20    | 诊断: 当前内核 `5.15.0-176-generic`, 但 595 只编译到 `5.15.0-168-generic`; apt `nvidia-driver-570` 仍在 hold 状态导致 DKMS 在 176 上重建了 570 |
| 05:00    | 一条命令修复: `apt purge nvidia-*-570` + `dkms install nvidia/595.58.03 -k $(uname -r)` + 在线 `modprobe -r/modprobe` |
| 05:30    | `nvidia-smi` 恢复, 显示 595.58.03 + CUDA 13.2 (详见 §8)            |

---

## 2. 根因 (Root Cause)

### 2.1 主因: `cleanup-old.sh` Step 3 grep 模式过宽

```bash
# 错误代码
DYNAMO_CRDS=$(kubectl get crd -o name | grep -E '(dynamo|nvidia\.com)' || true)
```

`nvidia.com` 是 **API group**, GPU Operator 自己的 CRD (`clusterpolicies.nvidia.com`, `nvidiadrivers.nvidia.com`) 也属于这个 group → 被误删。

### 2.2 二级因果链

```
cleanup 删 CRD
    ↓
gpu-operator controller 监听到 CRD 不在 → reconcile 失败 → 拆 DaemonSet
    ↓
nvidia-driver / device-plugin / dcgm / validator DaemonSet 全部消失
    ↓
nvidia-smi binary (由 driver-daemonset 注入到 host) 也消失
    ↓
00-upgrade-cuda.sh 预检 lspci|grep NVIDIA 失败 (依赖 pci.ids 数据库)
```

### 2.3 三个次级问题

1. **helm `--reuse-values` 跨小版本不安全**: chart 里新增 `kataSandboxDevicePlugin.enabled` 字段, 旧 release values 没有 → nil pointer
2. **`helm template ... | awk` 提取 CRD 缺 `apiVersion`**: 因为 `apiVersion:` 通常排在 `kind:` 之前, awk 截取 `kind:` 起始范围会丢字段
3. **`sudo kubectl` 误以为可用**: root 没有 `~/.kube/config`, kubectl 退化到 `localhost:8080` → connection refused (报错文本却是 "validation failed",有迷惑性)

---

## 3. 影响

| 资源                                       | 状态       |
| ------------------------------------------ | ---------- |
| `clusterpolicies.nvidia.com` CRD           | 已恢复     |
| `nvidiadrivers.nvidia.com` CRD             | 已恢复     |
| gpu-operator DaemonSets                    | 已恢复     |
| `nvidia-smi` / `/dev/nvidia*`              | 已恢复     |
| `yixunzhu-dynamo-system`                   | 未受影响   |
| `monitoring` ns (Prometheus / Grafana)     | 未受影响   |
| 物理驱动模块 (`lsmod | grep nvidia`)       | 未受影响 (内核驱动一直在,只是用户空间工具被拆) |

---

## 4. 修复 (已完成)

### 4.1 [`cleanup-old.sh`](../1.0.1/cleanup-old.sh) Step 3

```bash
# 修复后
DYNAMO_CRDS=$(kubectl get crd -o name 2>/dev/null \
  | grep -iE 'dynamo' \
  | grep -v -E 'clusterpolicies\.nvidia|nvidiadrivers\.nvidia|nvidiadriver|gpuoperator' \
  || true)
```

- 只匹配 `dynamo` 字样
- 显式黑名单 GPU Operator CRD
- 命中 GPU Operator CRD 时打印保留日志, 让用户看到

### 4.2 [`cleanup-old.sh`](../1.0.1/cleanup-old.sh) Step 5

`namespace` 删除从默认行为改为**必须显式 `--delete-namespace`**:

- 共享 ns 场景下避免删掉别人 / 自己的 etcd-nats
- 与默认 dry-run 配合, 给操作者两次确认机会

### 4.3 [`00-upgrade-cuda.sh`](../1.0.1/00-upgrade-cuda.sh) Stage 0 GPU 检测

```bash
# 修复后: 双路检测 + 失败时排查指引
if ! { lspci | grep -qi "NVIDIA" || lspci -nn 2>/dev/null | grep -qiE '\[10de:'; }; then
  error "未检测到 NVIDIA GPU 硬件"
  error "  排查:"
  error "    1) lspci | grep -i 'vga\|3d'"
  error "    2) lspci -nn | grep -i '10de:'"
  error "    3) 若 PCI 能看到但驱动模块未加载: 请先重建 gpu-operator"
```

---

## 5. 预防 (Process)

### 5.1 任何"清理" CRD 的脚本必须遵守

- 用**精确名称白名单**, 不用 group 通配
- 默认 dry-run, 必须 `--apply` 才执行
- 删除前打印将受影响的 CRD 列表
- 显式排除其他 controller 拥有的 CRD (gpu-operator / nfd / cert-manager / istio…)

### 5.2 helm gpu-operator 升级规范

| 不要                         | 推荐                                             |
| ---------------------------- | ------------------------------------------------ |
| `--reuse-values` 跨版本      | `--reset-then-reuse-values` (helm ≥ 3.14)        |
| 只升级模板不动 CRD           | 先 `helm pull --untar` apply `crds/`,再 upgrade |
| `awk` 切 helm template 输出  | 直接用 chart 的 `crds/*.yaml`                    |

### 5.3 kubectl 多用户/多 ns 操作规范

- `sudo kubectl ...` **几乎总是错的**, 除非显式 `KUBECONFIG=/etc/kubernetes/admin.conf`
- 关键操作前打印 `kubectl config current-context` + `kubectl get ns` 确认范围
- 部署脚本所有 `kubectl` / `helm -n` 都从 `${NAMESPACE}` 取值, 禁止硬编码

### 5.4 驱动升级规程

升级 NVIDIA 驱动**必须**先暂停 GPU Operator:
```bash
kubectl -n gpu-operator scale deploy/gpu-operator --replicas=0
kubectl -n gpu-operator delete ds -l app.kubernetes.io/managed-by=gpu-operator
```
否则 reboot 后 Operator 会以**老驱动版本**重建 DaemonSet, 与 host 上新驱动冲突。

---

## 6. 后续任务 (Action Items)

- [x] cleanup-old.sh CRD grep 修复
- [x] cleanup-old.sh namespace 改为 opt-in
- [x] 00-upgrade-cuda.sh GPU 检测增加 vendor-ID 兜底
- [x] 记录 `Driver/library version mismatch` 二次事故 (§8)
- [x] 记录 `apt purge` 后 `nvidia-drm` + `nvidia-smi` 双双消失 三次事故 (§9)
- [x] 沉淀服务器 NVIDIA 升级最佳实践 (§10)
- [ ] 在 README 中添加 "gpu-operator 升级 / 驱动升级 SOP"
- [ ] 在 cleanup 启动时主动 `kubectl get crd -l app.kubernetes.io/managed-by=gpu-operator` 列出受保护 CRD
- [ ] 部署脚本顶部增加 `kubectl config current-context` 显示 + 5s 倒计时确认
- [ ] `00-upgrade-cuda.sh` Phase 1 增加: 升级前 `apt purge` 所有 `nvidia-*-NNN` 包 + `apt-mark hold linux-image-*`
- [ ] `00-upgrade-cuda.sh` 新增 Phase 4.5 (post-reboot 校验): 跑 `dkms status` 验证目标版本已编到 `$(uname -r)`,否则自动 `dkms install`
- [ ] `00-upgrade-cuda.sh` 新增"三处版本一致性"校验函数 (`/proc/driver/nvidia/version` + `modinfo nvidia` + `libnvidia-ml.so`)

---

## 7. 经验小结 (Lessons Learned)

1. **API group ≠ application owner** — `nvidia.com` 是公共 group, 多个 operator 共享。grep 必须用具体 CRD 名 / labels (如 `app.kubernetes.io/managed-by=gpu-operator`)
2. **错误信息可能撒谎** — kubectl validation 错误的真因常常是 `localhost:8080` 连不上
3. **helm `--reuse-values` 是兼容性陷阱** — 跨版本必用 `--reset-then-reuse-values`
4. **共享集群上的"清理脚本"风险极高** — 默认必须 dry-run + namespace 白名单 + CRD 黑名单
5. **驱动升级与 K8s GPU 栈是两个独立维护周期** — 升级一方时另一方必须 freeze
6. **`set -o pipefail` + `grep -q` = 隐形坑** — `grep -q` 命中后立即退出,上游(`lspci` 等)写入触发 SIGPIPE,管道整体退出码 141。任何依赖管道返回值的 if 判断都会被误导。改用先抓输出再 grep 的写法,或在该段临时 `set +o pipefail`
7. **驱动升级 = `apt 包` × `.run installer` × `DKMS` × `当前内核`** 四维联立方程,任一变量错位都会导致 `Driver/library version mismatch`(详见 §8)
8. **`apt-mark hold` 不是隔离** — hold 只阻止"被升级/降级",不阻止 DKMS trigger 在新内核出现时为 hold 住的旧版本重建模块。要真隔离必须 `apt purge`

---

## 8. 二次事故: NVIDIA 驱动 `Driver/library version mismatch` (post-reboot)

> **时间**: 2026-04-25 04:00 — 05:30 UTC (gpu-operator 恢复后,继续 Phase 4 升级驱动)
> **症状**: reboot 后 `nvidia-smi` 报 `Failed to initialize NVML: Driver/library version mismatch. NVML library version: 595.58`
> **影响**: 所有 GPU 不可用,gpu-operator DaemonSet CrashLoop

### 8.1 根因 — 四个组件互相打架

诊断快照(`dkms status` + `find /lib/modules` + `dpkg -l`)显示:

| 维度 | 实际状态 |
| --- | --- |
| 当前运行内核 | `5.15.0-176-generic` (reboot 后内核被 apt 顺带升级) |
| `/lib/modules/5.15.0-176-generic/.../nvidia.ko` | **570.211.01** (apt 的 nvidia-dkms-570 自动重建) |
| `/lib/modules/5.15.0-168-generic/.../nvidia.ko` | **595.58.03** (`.run` installer 当时编译) |
| `/lib/modules/5.15.0-168-generic/.../nvidia-drm.ko` | **570.211.01** (混合! 部分被 570 覆盖) |
| 用户空间 `libnvidia-ml.so` (NVML) | **595.58** (`.run` 安装到 `/usr/lib/x86_64-linux-gnu/`) |
| `dpkg -l \| grep ^hi.*nvidia` | nvidia-driver-570, nvidia-dkms-570, libnvidia-*-570, … 全在 hold |

**因果链**:

```
. .run installer 在内核 168 下执行 → DKMS 编译 595 到 168
                                  → 用户空间库 (libnvidia-ml.so) 装 595
                                  → 但 nvidia-drm 被 apt 的 570 在某个时刻覆盖
. apt-mark hold 不阻断 DKMS trigger → apt 顺带升级了 kernel-image 到 176
. 内核 176 出现 → DKMS 自动为 hold 住的 nvidia-dkms-570 编译 570 到 176
. reboot → 内核 176 + 570 模块加载,但用户空间是 595 NVML
. nvidia-smi (用 595 NVML) ↔ /dev/nvidia* (570 模块) → version mismatch
```

### 8.2 修复 — 一条命令重建对齐

```bash
sudo apt-get install -y linux-headers-$(uname -r) build-essential && \
sudo apt-mark unhold $(dpkg -l | awk '/^hi.*nvidia/{print $2}') 2>/dev/null ; \
sudo apt-get purge -y '^nvidia-.*-570.*' '^libnvidia-.*-570.*' '^xserver-xorg-video-nvidia-570.*' && \
sudo apt-get autoremove -y --purge && \
sudo dkms install nvidia/595.58.03 -k $(uname -r) && \
sudo modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/dev/null ; \
sudo depmod -a && \
sudo modprobe nvidia && sudo modprobe nvidia_modeset && \
sudo modprobe nvidia_drm && sudo modprobe nvidia_uvm && \
nvidia-smi
```

| 步骤 | 解决的问题 |
| --- | --- |
| `linux-headers-$(uname -r)` | DKMS 编译 595 缺当前内核头 |
| `apt-mark unhold` + `apt purge nvidia-*-570` | 拔掉自动重建 570 的根源 |
| `dkms install nvidia/595.58.03 -k $(uname -r)` | 把现有 595 源码编到当前 (而不是旧) 内核 |
| `modprobe -r ... ; modprobe ...` | 不 reboot,在线切换模块 |

### 8.3 预防规则 (写进 SOP)

1. **驱动升级前必须做**:
   ```bash
   sudo apt-mark hold linux-image-generic linux-headers-generic linux-image-$(uname -r) linux-headers-$(uname -r)
   sudo apt purge -y '^nvidia-.*-[0-9]+.*' '^libnvidia-.*-[0-9]+.*' '^xserver-xorg-video-nvidia-[0-9]+.*'
   sudo apt-get autoremove -y --purge
   ```
   即 **先冻结内核,再清空 apt 装的旧驱动**,然后再 `.run --silent --dkms`。
2. **`.run` installer 必须带 `--dkms`**: 让任何后续 kernel 升级自动重编同版本驱动,而不是退回 apt 的旧版本。
3. **升级后立即验证三处一致**:
   ```bash
   cat /proc/driver/nvidia/version           # 内核模块版本
   modinfo nvidia | grep ^version            # 当前内核的 .ko 版本
   strings /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 | grep -m1 ' 5[0-9][0-9]\.'  # NVML 用户库版本
   ```
   三者必须完全一致(主+次+patch)。任一不一致,**禁止 reboot**,先修。
4. **kernel + driver 升级不要混做**: 
   - 升驱动时:`apt-mark hold linux-image-*`
   - 升内核时:`apt-mark hold nvidia-*` 或确保 DKMS 源是目标驱动版本
5. **运行 `00-upgrade-cuda.sh` 后增加 sentinel 校验阶段** (待补丁):
   - reboot 后第一件事跑 `dkms status | grep $TARGET_VERSION.*$(uname -r).*installed`
   - 不通过 → 自动重新 `dkms install` 到当前内核
   - 仍不通过 → 提示用户回退或手工介入,不让继续 Phase 5

### 8.4 根因索引 (Quick Lookup)

| 症状 | 第一时间查 |
| --- | --- |
| `Driver/library version mismatch` | `dkms status` + `uname -r` 看是否当前内核漏编译 |
| `nvidia-smi: command not found` | gpu-operator 是否被卸 (CRD 是否还在); 或 `nvidia-utils-NNN` 被 apt purge 了 (§9) |
| reboot 后驱动版本回退 | `dpkg -l \| grep ^hi.*nvidia` 是否有 hold 住的旧版本 |
| `dkms install` 报 `module not found in /usr/src` | `.run` 是否带 `--dkms` 重跑 |
| `modprobe nvidia` 报 `Module already in use` | `lsof /dev/nvidia*`; persistenced / dcgm 还在 |
| `modprobe: FATAL: Module nvidia_drm not found` | DKMS build 日志里 `NV_EXCLUDE_BUILD_MODULES='nvidia-drm '` (§9) |

---

## 9. 三次事故: `apt purge` 后用户空间 + nvidia-drm 双双消失

> **时间**: 2026-04-25 06:00 — UTC (执行 §8.2 一键修复脚本之后)
> **症状**:
> - `modprobe: FATAL: Module nvidia_drm not found in directory /lib/modules/5.15.0-176-generic`
> - `nvidia-smi: command not found`
> **影响**: 驱动栈彻底空白,内核模块缺一个,用户空间全无

### 9.1 根因 — 一键修复脚本的两个隐藏假设没成立

| 失败点 | 现象 | 真因 |
| --- | --- | --- |
| **A. `nvidia-drm` 没编出来** | `'make' ... NV_EXCLUDE_BUILD_MODULES='nvidia-drm '` | `/usr/src/nvidia-595.58.03/dkms.conf` 里把 `nvidia-drm` 写在了 `BUILD_EXCLUSIVE_*` 之外的排除项。`.run` installer 注册到 DKMS 时,如果当时检测内核 DRM 头不全,会把 nvidia-drm 排除掉。**仅靠 `dkms install` 不能补回**,必须重跑 `.run` installer 让它重新探测+注册。 |
| **B. `nvidia-smi` 消失** | `/usr/bin/nvidia-smi: No such file or directory` | `nvidia-smi` 二进制原由 apt 包 `nvidia-utils-570` 提供 (`/usr/bin/nvidia-smi → /etc/alternatives/...`)。`.run` installer 之前装的 595 版本 `nvidia-smi` 在某次 apt 操作里被 alternative 切走 / 被 apt 包覆盖。我们 `apt purge nvidia-utils-570` 时把这条路径连根拔了 → 用户空间全无。 |

**核心教训**: `apt purge nvidia-*` 之后,**必须紧接着重跑 `.run` installer** 才能补回 (a) 完整 kernel modules (含 nvidia-drm) 和 (b) 用户空间 (nvidia-smi / libnvidia-ml.so / libnvidia-cfg.so / firmware)。`dkms install` **只重建已注册模块**,既不补 nvidia-drm,也不装任何用户空间二进制。

### 9.2 修复 — 重跑 .run installer

```bash
# 1. 找 .run 文件
find / -name 'NVIDIA-Linux-x86_64-595.58.03.run' 2>/dev/null

# 2. 重新安装 (含 DKMS 注册 + 用户空间)
sudo bash /path/to/NVIDIA-Linux-x86_64-595.58.03.run \
    --silent --dkms --no-questions --accept-license --install-libglvnd

# 3. 如果仍排除 nvidia-drm, 补 DRM 内核组件后再装
sudo apt-get install -y linux-modules-extra-$(uname -r)
sudo bash /path/to/NVIDIA-Linux-x86_64-595.58.03.run \
    --silent --dkms --no-questions --accept-license --install-libglvnd

# 4. 加载 + 验证
sudo depmod -a
sudo modprobe nvidia nvidia_modeset nvidia_drm nvidia_uvm
nvidia-smi
```

### 9.3 把 §8.2 脚本升级为安全版

```bash
# === 安全版: purge 之前先备份 .run, purge 之后立即 .run reinstall ===
RUN_FILE="${RUN_FILE:-$(find / -name 'NVIDIA-Linux-x86_64-*.run' 2>/dev/null | head -1)}"
[[ -z "$RUN_FILE" || ! -f "$RUN_FILE" ]] && { echo "FATAL: 找不到 .run 文件"; exit 1; }

sudo apt-get install -y linux-headers-$(uname -r) linux-modules-extra-$(uname -r) build-essential
sudo apt-mark unhold $(dpkg -l | awk '/^hi.*nvidia/{print $2}') 2>/dev/null
sudo apt-get purge -y '^nvidia-.*-[0-9]+.*' '^libnvidia-.*-[0-9]+.*' '^xserver-xorg-video-nvidia-[0-9]+.*'
sudo apt-get autoremove -y --purge

# 关键: 立即重装,不要依赖 dkms install
sudo bash "$RUN_FILE" --silent --dkms --no-questions --accept-license --install-libglvnd

sudo modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/dev/null
sudo depmod -a
sudo modprobe nvidia nvidia_modeset nvidia_drm nvidia_uvm
nvidia-smi
```

---

## 10. 服务器 NVIDIA 驱动升级最佳实践 (Knowledge Base)

> 经过本次三连击事故 (CRD 误删 / 内核漂移 / 用户空间消失) 提炼的 SOP。**任何驱动 / CUDA / kernel 升级都遵循此章。**

### 10.1 黄金原则

| # | 原则 | 反例 |
| --- | --- | --- |
| 1 | **单源驱动管理**: apt 装的驱动 与 `.run` installer **互不混用**, 选一种 | 同时存在 `nvidia-driver-570` (apt) + `.run 595` → DKMS 在每个内核上各编一份,reboot 抓阄 |
| 2 | **冻结内核**: 升驱动期间禁止内核升级 | apt update 升 kernel 后 reboot,新内核没有目标驱动模块 |
| 3 | **GPU Operator 与主机驱动是两个维度**: 先 freeze Operator (`replicas=0` + 删 driver-DaemonSet),再动主机驱动 | Operator 还在,会按老 ClusterPolicy 重建驱动 DaemonSet,与主机新驱动冲突 |
| 4 | **每一步后立即三处校验** (kernel module / NVML / nvidia-smi 输出) | 一直推进到 reboot 才发现版本对不上,排查面 ×10 |
| 5 | **purge 必跟 reinstall**: `apt purge nvidia-*` 后 **同一会话内** `.run --dkms` 重装 | purge 完高兴一下重启 → 主机彻底无驱动,SSH 还能上但 GPU 没了 |
| 6 | **不要在共享集群上 `kubectl delete crd | grep nvidia`** | 误删 GPU Operator CRD → 所有 GPU 工作负载下线 |
| 7 | **保留 .run 文件至少到下次升级完成** | 出问题想 reinstall,文件没了只能重新下载几个 GB |
| 8 | **Kernel headers 跟着内核走**: `linux-headers-$(uname -r)` 必装且与运行内核同版本 | DKMS 编译失败原因 #1 |

### 10.2 推荐的标准升级流程 (8 步)

```bash
# ===== Phase 0: 前置检查 =====
uname -r
nvidia-smi
dkms status
dpkg -l | grep -iE 'nvidia|cuda' | wc -l
kubectl get pods -n gpu-operator
df -h /usr /var /boot   # 至少各 5GB 空闲

# ===== Phase 1: Freeze 一切会动的东西 =====
# 1.1 暂停 GPU Operator
kubectl -n gpu-operator scale deploy/gpu-operator --replicas=0
kubectl -n gpu-operator delete ds -l app.kubernetes.io/managed-by=gpu-operator

# 1.2 冻结当前内核
sudo apt-mark hold linux-image-generic linux-headers-generic \
                   linux-image-$(uname -r) linux-headers-$(uname -r)

# 1.3 装编译依赖
sudo apt-get install -y build-essential dkms \
    linux-headers-$(uname -r) linux-modules-extra-$(uname -r)

# ===== Phase 2: 备份 + 下载 =====
sudo install -d /opt/nvidia-installers
cd /opt/nvidia-installers
[[ -f NVIDIA-Linux-x86_64-${TARGET}.run ]] || \
  wget https://us.download.nvidia.com/XFree86/Linux-x86_64/${TARGET}/NVIDIA-Linux-x86_64-${TARGET}.run
chmod +x NVIDIA-Linux-x86_64-${TARGET}.run

# 备份当前驱动版本号 + 关键文件
echo "BEFORE_VERSION=$(cat /proc/driver/nvidia/version | head -1)" | sudo tee /var/log/nvidia-upgrade.log
sudo cp -a /lib/modules/$(uname -r)/updates/dkms /var/backup/dkms-$(date +%s) 2>/dev/null || true

# ===== Phase 3: 清理旧 apt 驱动包 =====
sudo systemctl stop nvidia-persistenced 2>/dev/null
sudo apt-mark unhold $(dpkg -l | awk '/^hi.*nvidia/{print $2}') 2>/dev/null
sudo apt-get purge -y '^nvidia-.*-[0-9]+.*' '^libnvidia-.*-[0-9]+.*' \
                      '^xserver-xorg-video-nvidia-[0-9]+.*'
sudo apt-get autoremove -y --purge
# 注意: cuda-toolkit-* / nvidia-container-toolkit 不动

# ===== Phase 4: 安装 .run + DKMS =====
sudo bash /opt/nvidia-installers/NVIDIA-Linux-x86_64-${TARGET}.run \
     --silent --dkms --no-questions --accept-license --install-libglvnd

# ===== Phase 5: 立即三处校验 (不要 reboot!) =====
KMOD_VER=$(modinfo nvidia 2>/dev/null | awk '/^version:/{print $2}')
PROC_VER=$(awk '/NVRM version/{print $8}' /proc/driver/nvidia/version 2>/dev/null)
NVML_VER=$(strings /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 2>/dev/null | grep -oE ' [5-9][0-9]{2}\.[0-9]+\.[0-9]+' | head -1 | tr -d ' ')
echo "kmod=$KMOD_VER proc=$PROC_VER nvml=$NVML_VER target=$TARGET"
[[ "$KMOD_VER" == "$TARGET" && "$NVML_VER" == "$TARGET" ]] || { echo "FATAL: 版本不一致, 不要 reboot"; exit 1; }

# ===== Phase 6: 在线切换模块 (避免 reboot 风险) =====
sudo modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia
sudo depmod -a
sudo modprobe nvidia nvidia_modeset nvidia_drm nvidia_uvm
nvidia-smi   # 必须显示 TARGET 版本

# ===== Phase 7: 升 CUDA toolkit (可选, 与驱动解耦) =====
sudo apt-get install -y cuda-toolkit-13-2
nvcc --version

# ===== Phase 8: 唤醒 GPU Operator =====
kubectl -n gpu-operator scale deploy/gpu-operator --replicas=1
kubectl -n gpu-operator rollout status deploy/gpu-operator --timeout=300s
kubectl get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}'
```

### 10.3 当前 `00-upgrade-cuda.sh` 的问题清单

按本次三连事故的暴露程度排序:

| # | 问题 | 严重 | 修复方向 |
| --- | --- | --- | --- |
| 1 | **Phase 1 没 purge 旧 apt 驱动** → 留下 `nvidia-driver-570` 与 `.run 595` 共存,DKMS 在新内核上编出 570 | P0 | 在 `.run` 安装前插入 `apt purge '^nvidia-.*-[0-9]+.*'` |
| 2 | **没 hold 内核** → reboot 时 apt 顺带升级 kernel-image,新内核没有 595 | P0 | Phase 1 增加 `apt-mark hold linux-image-* linux-headers-*` |
| 3 | **没有 post-install 三处一致性校验** → 推进到 reboot 才发现版本错位 | P0 | 新增 `verify_driver_consistency()` 函数,失败立即 abort |
| 4 | **依赖 reboot 才生效** → reboot 是不可逆动作,出错只能进 recovery | P1 | 在线 `modprobe -r/modprobe` 切换,reboot 改为可选 |
| 5 | **`.run` 后没保存到 `/opt/nvidia-installers/`** → 下次需要 reinstall 找不到 | P1 | 下载到固定路径并 `chmod 755`,记录到 `/var/log/nvidia-upgrade.log` |
| 6 | **没检测 nvidia-drm 是否被排除** → DKMS build 静默成功但缺一个模块 | P1 | 解析 DKMS build log,grep `NV_EXCLUDE_BUILD_MODULES` 非空就报警 |
| 7 | **GPU Operator freeze 不彻底** → 只 scale 了 deploy,没删 driver-daemonset | P1 | Phase 1 增加 `kubectl delete ds -l app.kubernetes.io/managed-by=gpu-operator` |
| 8 | **Stage 0 GPU 检测依赖 `nvidia-smi`** → 主机驱动被拆后永远过不去 | P2 | 已修复 (用 `lspci -nn \| grep 10de:`), 但脚本其它地方还有 `nvidia-smi` 依赖需扫一遍 |
| 9 | **没有 dry-run / 倒计时确认** → 共享集群上误执行成本极高 | P2 | 顶部增加 `kubectl config current-context` 显示 + 5s 倒计时 |
| 10 | **Phase 4.5 缺失** (post-reboot DKMS 自动重建) | P2 | 新增独立 `04.5-post-reboot-verify.sh`,reboot 后必跑 |

### 10.4 与 `cleanup-old.sh` / `01-deploy-dynamo-1.0.1.sh` 的协同问题

- `cleanup-old.sh` 必须**永远不碰** `*.nvidia.com` CRD (已修但需写进 README)
- `01-deploy-*.sh` 启动前应主动校验:
  ```bash
  kubectl -n gpu-operator get clusterpolicy >/dev/null || { echo "GPU Operator 未就绪"; exit 1; }
  kubectl get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}' | grep -q '[1-9]'
  ```
- 任何脚本不假设 `nvidia-smi` 一定存在;遇到缺失时输出排查指引而非沉默失败

### 10.5 一页速查 (打印贴墙)

```
┌──────────────────────────────────────────────────────────────────┐
│  NVIDIA 驱动升级 5 不要                                          │
├──────────────────────────────────────────────────────────────────┤
│  1. 不要 apt + .run 混装                                         │
│  2. 不要不 hold 内核就升驱动                                     │
│  3. 不要 purge 完不立即 reinstall .run                            │
│  4. 不要省略三处校验 (kmod / NVML / nvidia-smi)                   │
│  5. 不要在 GPU Operator 未 freeze 时改主机驱动                    │
└──────────────────────────────────────────────────────────────────┘
```

### 10.6 安装方式选型 — 生产环境为何选 apt

| 维度 | apt (`cuda-drivers-NNN`) | `.run` installer | GPU Operator 容器化驱动 |
| --- | --- | --- | --- |
| 依赖管理 | ✅ 元包原子化 | ❌ 自维护 30+ 子包 | ✅ 镜像即依赖 |
| kernel 升级自适应 | ✅ DKMS trigger 自动重编 | ⚠️ 必须 `--dkms` + .run 文件还在 | ✅ Pod 重建 |
| 版本锁定 | ✅ `apt-mark hold` | ⚠️ 与任何 apt nvidia 包冲突 | ✅ helm values 锁定 |
| 回滚 | ✅ 一行 apt install | ❌ 重装 + 手清残留 | ✅ helm rollback |
| patch 粒度 | ⚠️ 只到主版本 | ✅ 精确到 .NN.NN | ⚠️ 跟 NGC 镜像 tag |
| 审计可见 | ✅ `dpkg -l` | ❌ 散落多处 | ✅ `kubectl describe` |
| **三连击事故触发概率** | **低** | **高** (本次踩到 3 次) | **极低** (主机零驱动) |

**结论 (按推荐度)**:
1. **(最优) GPU Operator 容器化驱动** (`driver.enabled=true`): 主机零驱动, 升级仅需改 helm values。**长期推荐切换方向。**
2. **(当前最佳实践) apt 元包 `cuda-drivers-NNN`**: 共享集群 / 主机驱动模式下的标准选择。**新脚本采用此方式。**
3. **(避免) `.run` installer**: 仅在需要 NVIDIA 临时 hotfix 且 apt repo 还没更新时使用,且必须保证机器上没有任何 apt nvidia-* 包。

### 10.7 新升级脚本 — `00-upgrade-driver-apt.sh`

> 路径: [`1.0.1/00-upgrade-driver-apt.sh`](1.0.1/00-upgrade-driver-apt.sh)
> 替代旧的 `00-upgrade-cuda.sh` (.run 版,保留作历史参考)

**内置安全护栏**(对应历史踩坑):

| 历史问题 | 新脚本对策 |
| --- | --- |
| §2.1 cleanup 误删 CRD | 不动任何 K8s CRD, 只 `scale deploy/gpu-operator --replicas=0` + 删 driver-DaemonSet |
| §2.3-3 `helm template` awk 切 | 不再生成 / 切割 chart YAML |
| §8.1 内核漂移 (168→176) | Phase 3: `apt-mark hold linux-image-$(uname -r)` 强制冻结 |
| §8.1 apt 570 + .run 595 共存 | Phase 5: `apt purge '^nvidia-driver-[0-9]+$'` 等正则一次清空所有版本 |
| §8.1 NVML 与 .ko 版本错位 | Phase 9: `verify_consistency()` 校验 kmod/proc/nvml/smi 四源主版本一致 |
| §9.1 nvidia-drm 被 DKMS 排除 | Phase 4: 强制装 `linux-modules-extra-$(uname -r)`; Phase 7: 显式检查 `nvidia-drm.ko` 存在 |
| §9.1 `apt purge` 后用户空间消失 | 单源策略 — 用 `cuda-drivers-NNN` 元包,不出现 purge 后无 .run 可补的窗口 |
| 强制 reboot 高风险 | 默认 in-place: `modprobe -r/modprobe` 在线切换;`--reboot` 改为可选 |
| 无 dry-run | `--check` 模式: 打印当前/目标/将 purge 的包列表, 不动任何东西 |
| 无回滚 | `--rollback` 读 `/var/backup/nvidia-upgrade-*/dpkg-nvidia.list` 自动恢复旧主版本 |
| 无审计 | 所有阶段写 `/var/log/nvidia-upgrade.log` + `/var/lib/nvidia-upgrade.sentinel` |

**用法**:
```bash
# 1. 干跑 (强烈推荐升级前先跑)
sudo bash 00-upgrade-driver-apt.sh --check

# 2. 升级 (in-place, 默认不 reboot)
sudo bash 00-upgrade-driver-apt.sh --phase1

# 3. 唤醒 GPU Operator + 校验
sudo bash 00-upgrade-driver-apt.sh --phase2

# 可选: 强制 reboot (在线切换失败时)
sudo bash 00-upgrade-driver-apt.sh --phase1 --reboot
sudo bash 00-upgrade-driver-apt.sh --phase2   # reboot 后

# 紧急回滚
sudo bash 00-upgrade-driver-apt.sh --rollback

# 自定义版本
TARGET_DRIVER_MAJOR=595 TARGET_CUDA_APT=13-2 sudo -E bash 00-upgrade-driver-apt.sh --phase1
```

**关键流程图**:
```
[--check]  探测 → 打印计划 → 退出
[--phase1] 备份 → freeze Operator → hold kernel → 装 keyring/headers
              ↓
           apt purge 所有 nvidia-driver-*
              ↓
           apt install cuda-drivers-${TARGET}  ← 单源, 元包
              ↓
           DKMS 校验 + nvidia-drm 存在性检查
              ↓
           [in-place] modprobe -r → modprobe
           [--reboot] systemctl reboot
              ↓
           verify_consistency() ← 四源版本必须完全一致
              ↓
           apt install cuda-toolkit-${X}
              ↓
           写 sentinel
[--phase2] 再次 verify_consistency() → 重配 containerd → 唤醒 Operator
[--rollback] 读最近备份 → 解析旧主版本 → apt install cuda-drivers-${OLD}
```
