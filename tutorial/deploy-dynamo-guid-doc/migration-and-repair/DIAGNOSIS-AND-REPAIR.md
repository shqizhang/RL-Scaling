# 集群诊断分析与修复方案

> **日期**：2026-04-07（更新 2026-04-10）  
> **环境**：单节点 K8s (gpu14) + Dynamo 0.7.1 + Prometheus & Grafana
> **执行方式**：使用 root 用户直接执行，无需 sudo

---

## 一、诊断分析

### 1.1 问题总览

从 `kubectl get pods --all-namespaces` 输出来看，集群中存在大量异常 Pod，涉及 3 个 namespace：

| Namespace | 异常 Pod 数 | 正常 Pod 数 | 主要异常状态 |
|-----------|-----------|-----------|------------|
| `monitoring` | 8 | 5 | Init:CrashLoopBackOff, Init:Error, ContainerStatusUnknown, Error, Completed |
| `dynamo-system` | 10 | 4 | CrashLoopBackOff, Error, ContainerStatusUnknown, UnexpectedAdmissionError, Completed |
| `local-path-storage` | 2 | 1 | Completed, ContainerStatusUnknown |

### 1.2 根因分析

#### 根因 1：节点多次非正常重启

**证据**：
- 大量 Pod 显示 `ContainerStatusUnknown` 状态 — 这通常意味着节点宕机或 kubelet 崩溃后，容器运行时丢失了对这些容器的追踪
- 多个 Deployment 存在「新旧 Pod 并存」现象（如 prometheus-grafana 有 4 个 Pod，说明每次重启后 K8s 尝试创建新副本但旧的无法被清理）
- `kube-apiserver` 重启 4 次、`kube-controller-manager` 重启 7 次（21 天内），说明节点确实经历了多次意外重启

**影响**：每次节点非正常重启后，K8s 的 garbage collector 无法立即清理 `ContainerStatusUnknown` 和 `Completed` 的 Pod，它们会残留但不占用资源。

#### 根因 2：Grafana Init Container 持续失败（关键问题）

**现象**：`prometheus-grafana-*-r6c5j` 处于 `Init:CrashLoopBackOff`（42 次重启）

**可能原因**：
1. **PVC 绑定问题**：Grafana 的 init container 需要写入持久卷，如果 PVC 所绑定的 PV 在节点重启后损坏或 local-path-provisioner 自身异常（确实有 Completed 状态的 Pod），init 阶段就会失败
2. **local-path-provisioner 异常**：provisioner 有 2 个异常 Pod，可能无法正确创建/挂载本地卷
3. **Grafana sidecar init container 依赖**：kube-prometheus-stack 的 Grafana 包含一个 init-sidecar 容器，负责从 ConfigMap 加载 dashboard，如果 Prometheus Operator 的 CRD 或 ConfigMap 状态不一致，也会导致 init 失败

#### 根因 3：Dynamo Worker CrashLoopBackOff

**现象**：
- `vllmdecodeworker` = CrashLoopBackOff（45 次重启）
- `vllmprefillworker` = CrashLoopBackOff（40 次重启）+ 多个 Error

**可能原因**：
1. **GPU 资源争抢**：节点重启后，残留的 `ContainerStatusUnknown` Pod 虽然不运行，但 K8s 的资源计数可能出现不一致，导致新 Pod 无法分配到 GPU
2. **etcd/NATS 暂时不可用**：Worker 启动时需要连接 Dynamo 的 etcd 进行服务注册，如果 etcd 在节点重启后还未恢复，Worker 会启动失败进入 CrashLoop
3. **模型下载中断**：Worker 首次启动需要从 HuggingFace 下载模型权重，节点重启会中断下载，再次启动可能遇到损坏的缓存文件

#### 根因 4：UnexpectedAdmissionError

**现象**：`vllmprefillworker-*-tfzmq` 显示 `UnexpectedAdmissionError`

**原因**：Kubernetes admission 阶段（调度之前的准入控制）出错，通常是 GPU device plugin 在节点重启后短暂不可用期间，Pod 被调度但无法通过 device 分配准入检查。

### 1.3 诊断推荐命令（用于进一步确认）

```bash
# 1. 查看 Grafana init container 的具体失败原因
kubectl describe pod prometheus-grafana-6897d9847f-r6c5j -n monitoring
kubectl logs prometheus-grafana-6897d9847f-r6c5j -n monitoring -c init-sc-datasources

# 2. 查看 Decode Worker 的崩溃日志
kubectl logs vllm-v1-disagg-router-vllmdecodeworker-5dd95887bd-4sqm2 \
  -n dynamo-system --previous

# 3. 查看 Prefill Worker 的崩溃日志
kubectl logs vllm-v1-disagg-router-vllmprefillworker-76c9d48c64-x2nbm \
  -n dynamo-system --previous

# 4. 查看节点事件（是否有 OOM、磁盘压力等）
kubectl describe node gpu14 | grep -A20 "Conditions:"

# 5. 查看 PVC 状态
kubectl get pvc -A

# 6. 查看 GPU 资源分配
kubectl describe node gpu14 | grep -A10 "Allocated resources:"
```

---

## 二、修复方案

### 2.1 方案选择：全量重建（推荐）

**为什么选择全量重建而非逐个修复？**

| 方案 | 优点 | 缺点 | 推荐场景 |
|------|------|------|---------|
| **逐个删除异常 Pod** | 不影响运行中的服务 | 可能遗漏问题，PVC/CRD 可能有残留状态 | 生产环境，需要保留数据 |
| **删除并重建 namespace** | 彻底清理所有资源（Pod/PVC/Secret/ConfigMap） | 丢失所有数据（Prometheus 历史指标、Grafana 自定义 Dashboard） | 开发/测试环境 |
| **Helm uninstall + 删 namespace + 重新部署** ✅ | 最干净，避免 CRD/PVC 残留问题 | 需要重新配置 | 当前场景（不需要保留数据） |

**推荐方案**：Helm uninstall → 删除 namespace → 重新部署。

**关键注意**：
- **不要直接 `kubectl delete namespace`**，因为 Helm release 的元数据存在 namespace 内的 Secret 中，直接删 namespace 会导致 Helm 认为 release 仍存在但无法操作
- **正确顺序**：先 `helm uninstall` 卸载 release，再删 namespace
- **Dynamo CRDs 不要删**（它们是集群级共享资源，删除后需要重新安装）

### 2.2 修复步骤

#### Step 1：清理 Dynamo namespace

```bash
export NAMESPACE=dynamo-system

# 1. 先删除 DGD（让 Operator 清理推理 Pod 和关联的 Service）
kubectl delete dynamographdeployment vllm-v1-disagg-router -n ${NAMESPACE} --wait --timeout=120s

# 2. 删除 HPA 和 Ingress
kubectl delete hpa --all -n ${NAMESPACE}
kubectl delete ingress --all -n ${NAMESPACE}

# 3. Helm 卸载 dynamo-platform
helm uninstall dynamo-platform -n ${NAMESPACE}

# 4. 删除残留 PVC
kubectl delete pvc --all -n ${NAMESPACE}

# 5. 删除 namespace
kubectl delete namespace ${NAMESPACE} --wait --timeout=180s
```

#### Step 2：清理 Monitoring namespace

```bash
# 1. Helm 卸载 prometheus-adapter
helm uninstall prometheus-adapter -n monitoring

# 2. Helm 卸载 kube-prometheus-stack
helm uninstall prometheus -n monitoring

# 3. 删除残留 PVC
kubectl delete pvc --all -n monitoring

# 4. 删除 namespace
kubectl delete namespace monitoring --wait --timeout=120s

# 5.（可选）清理 Prometheus Operator CRDs
kubectl delete crd alertmanagerconfigs.monitoring.coreos.com
kubectl delete crd alertmanagers.monitoring.coreos.com
kubectl delete crd podmonitors.monitoring.coreos.com
kubectl delete crd probes.monitoring.coreos.com
kubectl delete crd prometheusagents.monitoring.coreos.com
kubectl delete crd prometheuses.monitoring.coreos.com
kubectl delete crd prometheusrules.monitoring.coreos.com
kubectl delete crd scrapeconfigs.monitoring.coreos.com
kubectl delete crd servicemonitors.monitoring.coreos.com
kubectl delete crd thanosrulers.monitoring.coreos.com
```

#### Step 3：清理 Ingress（如果需要）

```bash
helm uninstall ingress-nginx -n ingress-nginx
kubectl delete namespace ingress-nginx
```

#### Step 4：清理 local-path-storage 的异常 Pod

```bash
kubectl delete pod -n local-path-storage \
  local-path-provisioner-567b5f79b9-9lgtt \
  local-path-provisioner-567b5f79b9-bbjlk
```

#### Step 5：验证集群干净状态

```bash
kubectl get pods -A | grep -v "Running\|kube-system\|gpu-operator\|kube-flannel"
# 期望：除了 kube-system、gpu-operator、kube-flannel 之外没有异常 Pod

kubectl get pvc -A
# 期望：无残留 PVC

kubectl get namespace
# 期望：没有 monitoring、dynamo-system、ingress-nginx
```

#### Step 6：使用脚本重新部署

```bash
cd ~/recover-script  # 或脚本所在目录

# 1. 部署 Prometheus & Grafana
bash 01-deploy-prometheus-grafana.sh

# 2. 部署 Dynamo
export MODEL_NAME="Qwen/Qwen3-0.6B"
export NAMESPACE="dynamo-system"
bash 02-deploy-dynamo.sh

# 3. 验证
bash 03-test-dynamo.sh health
bash 03-test-dynamo.sh api
```

---

## 三、脚本说明

### 3.0 如何将脚本上传到服务器

**从本地 Windows 电脑上传到 gpu14 服务器：**

```powershell
# 方法 1：用 scp 一次性上传整个 recover-script 目录
scp -r .\tutorial\deploy-dynamo\recover-script\ root@gpu14:~/recover-script/

# 方法 2：如果你用普通用户登录后 su 到 root
scp -r .\tutorial\deploy-dynamo\recover-script\ your_username@gpu14:~/recover-script/
# 然后 SSH 进去后：
ssh your_username@gpu14
su -
cp -r /home/your_username/recover-script ~/recover-script/

# 方法 3：如果用了跳板机或非标准端口
scp -P 22222 -r .\tutorial\deploy-dynamo\recover-script\ root@gpu14:~/recover-script/
```

**上传后在服务器上检查：**

```bash
# SSH 登录服务器
ssh root@gpu14

# 确认文件已上传
ls -la ~/recover-script/
# 预期看到：
#   00-migrate-k8s-to-ssd.sh
#   01-deploy-prometheus-grafana.sh
#   02-deploy-dynamo.sh
#   03-test-dynamo.sh
#   DIAGNOSIS-AND-REPAIR.md
#   MIGRATION-GUIDE.md

# 赋予脚本执行权限
chmod +x ~/recover-script/*.sh
```

> **建议放在 `~/recover-script/` 目录**（即 `/root/recover-script/`），方便执行。

### 3.1 脚本清单

| 文件 | 用途 | 预计执行时间 |
|------|------|------------|
| `00-migrate-k8s-to-ssd.sh` | 迁移 K8s 数据到 SSD，释放根分区空间 | 5~15 分钟 |
| `01-deploy-prometheus-grafana.sh` | 清理 + 重装 Prometheus & Grafana | 5~10 分钟 |
| `02-deploy-dynamo.sh` | 清理 + 重装 Dynamo Platform + 推理服务 + Ingress + HPA | 10~20 分钟（含模型下载） |
| `03-test-dynamo.sh` | 功能测试、路由验证、指标验证、负载测试 | 按需 |

### 3.2 完整执行流程（一步一步按顺序执行）

```bash
# ====== 准备工作 ======
# SSH 登录服务器（使用 root）
ssh root@gpu14
cd ~/recover-script

# 设置必要的环境变量（一次性设好，后面脚本共用）

# ====== Step 1: 迁移 K8s 数据到 SSD ======
bash 00-migrate-k8s-to-ssd.sh
# → 按提示确认即可，脚本有交互确认
# → 完成后验证 K8s 集群恢复：kubectl get nodes

# ====== Step 2: 部署 Prometheus & Grafana ======
bash 01-deploy-prometheus-grafana.sh
# → 等待所有 monitoring Pod 变为 Running
# → 完成后验证：kubectl get pods -n monitoring

# ====== Step 3: 部署 Dynamo 推理服务 ======
bash 02-deploy-dynamo.sh
# → 等待 DGD Ready=True（模型首次下载可能需要 10+ 分钟）
# → 完成后验证：kubectl get pods -n dynamo-system

# ====== Step 4: 运行测试 ======
bash 03-test-dynamo.sh all
# → 验证所有功能链路正常
```

### 3.3 脚本使用前置条件

> ⚠️ **以下环境变量必须在执行脚本前通过安全渠道（如密钥管理系统）获取并设置，不要在文档或代码中硬编码。**

| 变量名 | 用于脚本 | 说明 |
|--------|---------|------|
| **`HF_TOKEN`** | `02` `03` | Hugging Face 访问令牌，用于下载模型 |
| **`NGC_API_KEY`** | `02` | NVIDIA NGC API Key，用于拉取容器镜像 |
| **`GRAFANA_ADMIN_PASSWORD`** | `01` | Grafana 管理员密码 |

```bash
# 可选环境变量（有默认值，一般不需要修改）
export NAMESPACE="dynamo-system"
export MODEL_NAME="Qwen/Qwen3-0.6B"
export RELEASE_VERSION="0.7.1"
export PREFILL_REPLICAS=1
export DECODE_REPLICAS=1
```

### 3.4 测试脚本用法

```bash
# 运行所有测试
bash 03-test-dynamo.sh all

# 仅健康检查
bash 03-test-dynamo.sh health

# 仅 API 测试
bash 03-test-dynamo.sh api

# 负载测试（自定义参数）
CONCURRENCY=20 TOTAL_REQUESTS=300 MAX_TOKENS=200 bash 03-test-dynamo.sh load

# HPA 扩容验证
bash 03-test-dynamo.sh hpa
```

---

## 四、从本地电脑访问 Grafana 监控面板

部署完成后，Grafana 运行在 K8s 集群内部，不直接对外暴露。需要通过 **SSH 隧道 + kubectl port-forward** 的方式从本地电脑的浏览器访问。

### 4.1 方法一：SSH 隧道 + port-forward（推荐）

这种方法需要两步：先建立 SSH 隧道到 gpu14，再在 gpu14 上做 port-forward。

#### 第一步：在本地电脑打开一个终端，建立 SSH 隧道

```powershell
# Windows PowerShell 或 CMD
# 将 gpu14 上的 localhost:3000 映射到本地的 localhost:3000
ssh -L 3000:localhost:3000 root@gpu14

# 如果 gpu14 需要跳板机
ssh -L 3000:localhost:3000 -J user@jumphost root@gpu14

# 如果使用非标准 SSH 端口
ssh -L 3000:localhost:3000 -p 22222 root@gpu14
```

#### 第二步：在 SSH 会话中执行 port-forward

```bash
# 在刚才的 SSH 终端中执行（或者另开一个 SSH 窗口）
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring
# 保持这个命令运行状态，不要关闭
```

#### 第三步：浏览器访问

```
打开浏览器访问: http://localhost:3000

登录信息:
  用户名: admin
  密码:   <你设置的 GRAFANA_ADMIN_PASSWORD>
```

### 4.2 方法二：NodePort（长期使用推荐）

如果不想每次都做 port-forward，可以将 Grafana Service 改为 NodePort 类型：

```bash
# 在 gpu14 上执行
kubectl patch svc prometheus-grafana -n monitoring \
  -p '{"spec": {"type": "NodePort", "ports": [{"port": 80, "targetPort": 3000, "nodePort": 30300}]}}'
```

---

## 五、SSD 迁移后 GPU 调度失败的完整复盘（2026-04-10）

### 5.1 问题时间线

| 时间 | 事件 |
|------|------|
| 04-07 | 根分区 94% 满 → K8s 各种 Pod 异常（PVC 绑定失败、CrashLoop） |
| 04-08 | 执行 `00-migrate-k8s-to-ssd.sh`，K8s 数据迁移到 SSD |
| 04-08 | 执行 `01-deploy-prometheus-grafana.sh`，Prometheus 恢复正常 |
| 04-08 | 执行 `02-deploy-dynamo.sh`，Platform 正常但 Worker CrashLoopBackOff |
| 04-09 | 排查 Worker 日志：`libcuda.so.1: cannot open shared object file` |
| 04-09 | 尝试修复 1：添加 `runtimeClassName: nvidia` → GPU 驱动有了但 8 张全可见 → OOM |
| 04-09 | 尝试修复 2：GPU release delay（60s wait）→ 无效，不是时序问题 |
| 04-09 | 尝试修复 3：staggered deploy → 无效，每次都 OOM |
| 04-09 | 尝试修复 4：移除 `runtimeClassName` → 回到 libcuda 缺失 |
| 04-10 | **最终定位**：3 个 containerd 配置项同时出了问题 |
| 04-10 | 修复：toolkit env + enable_cdi + device plugin restart → **成功** |

### 5.2 根本原因：3 个配置项的联锁故障

SSD 迁移需要**停止并重启 containerd**。重启触发了 GPU Operator 的 `nvidia-container-toolkit-daemonset` 自动覆写 containerd 配置。最终有 3 个配置项偏离了正确状态：

```
  迁移前（正常工作）            迁移后（故障状态）
  ┌──────────────────┐         ┌──────────────────┐
  │ defaultRuntime:  │         │ defaultRuntime:  │
  │   nvidia ✓       │  ──→   │   runc ✗         │ ① toolkit 覆写时未保留
  ├──────────────────┤         ├──────────────────┤
  │ enable_cdi:      │         │ enable_cdi:      │
  │   true ✓         │  ──→   │   false ✗        │ ② 主 config.toml 被覆写
  ├──────────────────┤         ├──────────────────┤
  │ Device Plugin:   │         │ Device Plugin:   │
  │   CDI 注入正常 ✓  │  ──→   │   未重启，状态旧 ✗│ ③ 20天前启动，未感知变更
  └──────────────────┘         └──────────────────┘
```

### 5.3 因果链详解

```
[00-migrate-k8s-to-ssd.sh]
    │
    ├── systemctl stop containerd    ← 必须停止才能安全迁移数据
    ├── rsync + symlink              ← 数据迁移本身无问题
    ├── systemctl start containerd   ← ★ 触发配置覆写链 ★
    │       │
    │       ▼
    │   nvidia-container-toolkit-daemonset 检测到 containerd 重启
    │       │
    │       ├── 读取自身环境变量 NVIDIA_RUNTIME_SET_AS_DEFAULT=false
    │       │   （GPU Operator 安装时默认值就是 false）
    │       │
    │       ├── 覆写 /etc/containerd/config.toml
    │       │   → default_runtime_name = "runc"     ← ① 关键故障点
    │       │   → enable_cdi = false                ← ② 关键故障点
    │       │
    │       └── 重启 containerd（使新配置生效）
    │
    └── 脚本检查 "containerd config 包含 nvidia handler ✓"
        → 但这只检查了 handler 存在，没检查 default_runtime_name 和 CDI
          （handler 存在 ≠ 默认使用，也 ≠ CDI 隔离生效）

[02-deploy-dynamo.sh 重新部署 DGD]
    │
    ├── 旧版 recover-script manifest: 带 runtimeClassName: nvidia
    │   → 容器用 nvidia runtime ✓ → 但走 RuntimeClass handler 路径
    │   → 绕过 CDI 设备隔离 → 每个容器看到全部 8 张 GPU
    │   → Prefill 和 Decode 都用 cuda:0（= 物理 GPU 0）→ OOM
    │
    ├── tutorial manifest: 不带 runtimeClassName
    │   → containerd 使用 runc（因为 default=runc）→ 无 GPU 驱动
    │   → libcuda.so.1 缺失 → CrashLoopBackOff
    │
    └── 两条路都是死路（见 5.4 表格）
```

### 5.4 为什么中间的修复尝试全都失败

| 尝试 | 做了什么 | 结果 | 失败原因 |
|------|---------|------|---------|
| 修复 1 | 加 `runtimeClassName: nvidia` | GPU 驱动有了但 OOM | 绕过 CDI → 8 卡全可见 → 两 Worker 竞争 GPU 0 |
| 修复 2 | 加 60s GPU 释放等待 | 仍 OOM | 不是时序问题，是隔离问题 |
| 修复 3 | staggered deploy（先启动一个） | 仍 OOM | 即使先后启动，两个都用 cuda:0 |
| 修复 4 | 移除 `runtimeClassName` | libcuda 缺失 | containerd 默认 runtime=runc，无 GPU |
| 修复 5 | `nvidia-ctk --set-as-default` | 仍 libcuda 缺失 | toolkit daemonset 自动覆盖回 runc |
| **最终修复** | **3 项同时修** | **成功 ✓** | 见 5.5 |

### 5.5 正确的修复（3 步缺一不可）

```bash
# ① 让 toolkit daemonset 把 nvidia 设为默认 runtime（防止被覆盖回 runc）
kubectl set env daemonset/nvidia-container-toolkit-daemonset \
  -n gpu-operator \
  NVIDIA_RUNTIME_SET_AS_DEFAULT=true
kubectl rollout status ds/nvidia-container-toolkit-daemonset \
  -n gpu-operator --timeout=120s

# ② 在主 config.toml 中启用 CDI（containerd 1.7 默认关闭）
sudo sed -i 's/enable_cdi = false/enable_cdi = true/' /etc/containerd/config.toml
sudo systemctl restart containerd

# ③ 重启 device plugin（使其重新注册 CDI 设备规格）
kubectl rollout restart daemonset/nvidia-device-plugin-daemonset -n gpu-operator
kubectl rollout status ds/nvidia-device-plugin-daemonset -n gpu-operator --timeout=120s
```

### 5.6 验证修复成功

```bash
# 1. containerd 配置正确
sudo crictl info 2>/dev/null | python3 -c "
import json, sys
info = json.load(sys.stdin)
cfg = info.get('config', {})
print(f'defaultRuntimeName: {cfg.get(\"containerd\", {}).get(\"defaultRuntimeName\", \"?\")}')" 
print(f'enableCDI: {cfg.get(\"enableCDI\", \"?\")}')"
# 期望: defaultRuntimeName: nvidia, enableCDI: True

# 2. 不加 runtimeClassName，请求 1 GPU → 只看到 1 张
kubectl run gpu-test --image=nvidia/cuda:12.0.0-base-ubuntu22.04 \
  --rm -it --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"gpu-test","image":"nvidia/cuda:12.0.0-base-ubuntu22.04","command":["nvidia-smi"],"resources":{"limits":{"nvidia.com/gpu":"1"}}}]}}' \
  -- nvidia-smi
# 期望: 只显示 1 张 RTX 3090（CDI 隔离生效）
```

### 5.7 经验总结

1. **SSD 迁移本质上是安全的**，但 containerd 重启是不可避免的副作用
2. **GPU Operator 的 toolkit daemonset 是 containerd GPU 配置的"真正管理者"**，手动改 config.toml 会被它覆盖
3. **`NVIDIA_RUNTIME_SET_AS_DEFAULT` 默认值是 `false`**，这是 GPU Operator 的设计选择（让用户通过 runtimeClassName 显式选择 runtime），但 Dynamo DGD 的 CDI 隔离机制要求 nvidia 必须是默认 runtime
4. **检查 containerd 配置必须用 `crictl info`**，不能只 grep config.toml，因为 toolkit 可能通过 drop-in config（`/etc/containerd/conf.d/99-nvidia.toml`）覆盖主配置
5. **CDI 是 containerd 1.7+ 的特性**，默认关闭（`enable_cdi = false`），必须显式开启才能实现 GPU 设备隔离
6. **device plugin 需要重启才能感知 CDI 配置变更**，如果它在配置变更前启动，CDI annotation 不会被注入到 Pod

# 验证
kubectl get svc prometheus-grafana -n monitoring
# 应该显示 TYPE=NodePort, 端口包含 30300
```

然后从本地电脑直接访问（需要 gpu14 的 IP 可达）：
```
http://<gpu14-IP>:30300
```

如果本地和 gpu14 不在同一网段，需要通过 SSH 隧道：
```powershell
# 本地终端
ssh -L 30300:<gpu14-IP>:30300 root@gpu14
# 然后浏览器访问 http://localhost:30300
```

### 4.3 同时访问 Prometheus UI

```bash
# 方法 A：port-forward（临时）
# 在 gpu14 上执行
kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n monitoring

# 本地需要额外的 SSH 隧道（不同终端窗口）
ssh -L 9090:localhost:9090 root@gpu14

# 浏览器访问: http://localhost:9090
```

```bash
# 方法 B：NodePort（长期）
kubectl patch svc prometheus-kube-prometheus-prometheus -n monitoring \
  -p '{"spec": {"type": "NodePort", "ports": [{"port": 9090, "targetPort": 9090, "nodePort": 30090}]}}'

# 浏览器访问: http://<gpu14-IP>:30090 或通过 SSH 隧道
```

### 4.4 端口映射汇总表

| 服务 | 集群内地址 | port-forward 命令 | SSH 隧道命令（本地端） | 浏览器 URL |
|------|-----------|------------------|---------------------|-----------|
| **Grafana** | `prometheus-grafana.monitoring:80` | `kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring` | `ssh -L 3000:localhost:3000 root@gpu14` | `http://localhost:3000` |
| **Prometheus** | `prometheus-kube-prometheus-prometheus.monitoring:9090` | `kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n monitoring` | `ssh -L 9090:localhost:9090 root@gpu14` | `http://localhost:9090` |
| **Dynamo API** | `vllm-v1-disagg-router-frontend.dynamo-system:8000` | `kubectl port-forward svc/vllm-v1-disagg-router-frontend 8000:8000 -n dynamo-system` | `ssh -L 8000:localhost:8000 root@gpu14` | `http://localhost:8000/v1/models` |

> **提示**：可以同时开多个 SSH 隧道窗口，每个映射不同的端口。或者合并到一条命令：
> ```powershell
> ssh -L 3000:localhost:3000 -L 9090:localhost:9090 -L 8000:localhost:8000 root@gpu14
> ```

---

## 五、预防措施（避免再次出现类似问题）

1. **节点稳定性**：排查节点频繁重启的原因（硬件故障？内核 panic？OOM killer？）
   ```bash
   journalctl -b -1 --priority=err  # 查看上次重启前的错误日志
   dmesg | grep -iE "oom|panic|error|gpu"
   ```

2. **Pod Disruption Budget**：单节点环境下 PDB 应禁用（脚本已处理）

3. **定期清理残留 Pod**：可设置 cron 任务定期清理 `Completed`/`Error` 状态的 Pod
   ```bash
   kubectl delete pods --field-selector=status.phase==Failed -A
   kubectl delete pods --field-selector=status.phase==Succeeded -A
   ```

4. **GPU Operator 健康监控**：定期验证 GPU 资源可用
   ```bash
   kubectl describe node gpu14 | grep nvidia.com/gpu
   ```
