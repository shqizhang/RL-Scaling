# Dynamo on Kubernetes — 深度部署学习指南

> **适用版本**：Dynamo 0.7.1 · Kubernetes 1.30 · Ubuntu 22.04 · 8× RTX 3090

---

## 目录

1. [全栈架构总览](#1-全栈架构总览)
2. [K8s 基础层：从裸机到集群](#2-k8s-基础层从裸机到集群)
3. [GPU 接入路径：从驱动到 Pod](#3-gpu-接入路径从驱动到-pod)
4. [Dynamo 平台层架构](#4-dynamo-平台层架构)
5. [Disaggregated Inference 推理架构](#5-disaggregated-inference-推理架构)
6. [部署脚本逐阶段说明](#6-部署脚本逐阶段说明)
7. [可观测性：Prometheus + Grafana 数据流](#7-可观测性prometheus--grafana-数据流)
8. [HPA 自动扩缩容工作原理](#8-hpa-自动扩缩容工作原理)
9. [常见问题排查](#9-常见问题排查)
10. [开发迭代工作流](#10-开发迭代工作流)

---

## 1. 全栈架构总览

```
┌──────────────────────────────────────────────────────────────────────┐
│  外部流量                                                             │
│  curl http://<NODE_IP>/v1/chat/completions                           │
└───────────────────────────┬──────────────────────────────────────────┘
                            │ HTTP/80
                            ▼
┌──────────────────────────────────────────────────────────────────────┐
│  ingress-nginx (DaemonSet, hostPort 80/443)                          │
│  路由规则：/v1 → dynamo-frontend:8000                                │
└───────────────────────────┬──────────────────────────────────────────┘
                            │ ClusterIP
                            ▼
┌──────────────────────────────────────────────────────────────────────┐
│  Dynamo Frontend Pod（KV Router）                                    │
│  - 接收请求，解析 prompt                                             │
│  - 查询 NATS 获取 Worker 负载状态                                    │
│  - 根据 KV Cache 亲和性选择 Prefill Worker                           │
└──────┬────────────────────────────────────────┬───────────────────────┘
       │ gRPC/NATS（prefill 任务派发）           │ gRPC（decode 任务派发）
       ▼                                         ▼
┌─────────────────────┐               ┌──────────────────────┐
│  Prefill Worker Pod │               │  Decode Worker Pod   │
│  - vLLM engine      │               │  - vLLM engine       │
│  - 1× RTX 3090      │  ──KV传输──▶  │  - 1× RTX 3090       │
│  - 预填充 prompt    │               │  - 自回归生成 token  │
│  - 写 KV Cache 块   │               │  - 读 KV Cache 块    │
└─────────────────────┘               └──────────────────────┘
       │                                         │
       └────────────────┬────────────────────────┘
                        │ gRPC（token 流）
                        ▼
              Frontend 组装 SSE 响应 → 客户端

─────── 控制面 ──────────────────────────────────────────────────────────

┌──────────────────────────────────────────────────────────────────────┐
│  Dynamo Operator（Deployment）                                        │
│  - 监听 DynamoGraphDeployment CRD                                    │
│  - 创建/更新 Frontend + Worker Deployments                           │
└──────────────────────────────────────────────────────────────────────┘
┌──────────────────────────────────────────────────────────────────────┐
│  etcd（Dynamo 内置，StatefulSet）                                     │
│  - 存储 Worker 注册信息、路由表                                       │
└──────────────────────────────────────────────────────────────────────┘
┌──────────────────────────────────────────────────────────────────────┐
│  NATS（Dynamo 内置，StatefulSet）                                     │
│  - Worker 心跳、KV Cache 状态广播                                    │
│  - 消息队列（任务派发）                                               │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 2. K8s 基础层：从裸机到集群

### 2.1 组件栈

```
物理机
  └── Ubuntu 22.04 + NVIDIA Driver 560+
        └── containerd（CRI）
              ├── runc（默认，非 GPU）
              └── nvidia-container-runtime（GPU 容器）
                    └── kubeadm 集群
                          ├── kube-apiserver
                          ├── kube-controller-manager
                          ├── kube-scheduler
                          ├── kubelet（每节点）
                          ├── Flannel CNI（Pod 网络）
                          └── NVIDIA GPU Operator
                                ├── Device Plugin（nvidia.com/gpu 资源）
                                └── RuntimeClass nvidia
```

### 2.2 关键配置决策

**为何用 `SystemdCgroup = true`？**

kubelet 使用 systemd cgroup driver，containerd 必须匹配，否则 Pod OOM 后 cgroup 清理不一致，导致 kubelet 反复重启。

**为何显式创建 RuntimeClass `nvidia`？**

containerd 重启后默认运行时可能重置回 `runc`。解决方案有两种：

1. **推荐**：将 nvidia 设为 containerd 默认运行时（`default_runtime_name = "nvidia"`），Pod 无需指定 `runtimeClassName`。此方式下 CDI 设备隔离机制正常工作，每个容器仅见被 Device Plugin 分配的 GPU。
2. **备选**：保持默认 `runc`，每个 GPU Pod 指定 `runtimeClassName: nvidia`。**注意**：此方式走 RuntimeClass handler 代码路径，可能绕过 CDI 设备隔离，导致容器看到所有 GPU。

```bash
# 推荐方式：设置 nvidia 为默认运行时
sudo nvidia-ctk runtime configure --runtime=containerd --set-as-default
sudo systemctl restart containerd
```

```yaml
# 备选方式（不推荐用于 Dynamo DGD）：手动指定 runtimeClassName
spec:
  runtimeClassName: nvidia
  containers:
    - resources:
        limits:
          nvidia.com/gpu: "1"
```

**`install-k8s.sh` 中 GPU Operator 安装参数：**

```bash
helm install gpu-operator nvidia/gpu-operator \
  --set driver.enabled=false \   # 驱动已在宿主机安装，不让 Operator 重装
  --set toolkit.enabled=true \   # 安装 nvidia-container-toolkit
  --set devicePlugin.enabled=true
```

---

## 3. GPU 接入路径：从驱动到 Pod

### 3.1 完整调用链

```
NVIDIA Driver (host)
    ↓ /dev/nvidiaX
nvidia-container-toolkit
    ↓ 注入 /dev/nvidiaX + 库 到容器 namespace
nvidia-container-runtime (containerd shim)
    ↓ OCI hook
容器内 CUDA 应用（vLLM）
    ↓ cudaMalloc
GPU 显存（RTX 3090 24 GiB）
```

### 3.2 Device Plugin 如何分配 GPU

1. kubelet 向 Device Plugin（`nvidia.com/gpu`）注册
2. Pod spec 声明 `resources.limits: nvidia.com/gpu: "1"`
3. kube-scheduler 找到有空闲 GPU 的 Node
4. kubelet 调用 Device Plugin `Allocate()`，Device Plugin 返回对应 `/dev/nvidiaX` 环境变量
5. containerd 用 nvidia-container-runtime 创建容器，挂载 GPU 设备

### 3.3 GPU_MEMORY_UTIL 设置原则

| GPU 数量 | GPU Ram | 推荐 UTIL | 说明 |
|---------|---------|-----------|------|
| 8× RTX 3090 | 24 GiB each | 0.90 | 保留 2.4 GiB 给 CUDA context overhead |
| 更大显卡 | ≥40 GiB | 0.95 | CUDA overhead 比例更小 |

在 `dgd-vllm-disagg-router.yaml` 中：
```yaml
args:
  - "--gpu-memory-utilization"
  - "${GPU_MEMORY_UTIL}"   # 默认 0.90，通过 envsubst 渲染
```

---

## 4. Dynamo 平台层架构

### 4.1 DynamoGraphDeployment（DGD）CRD

DGD 是 Dynamo 的核心自定义资源，描述一个完整的推理图（Inference Graph）：

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: vllm-v1-disagg-router
spec:
  services:
    Frontend:
      replicas: 1
      # ...
    VllmDecodeWorker:
      replicas: 1
      # ...
    VllmPrefillWorker:
      replicas: 1
      # ...
```

**Operator 行为**：监听 DGD，为每个 service 创建对应的 `Deployment` + `Service`，命名规则为 `{dgd-name}-{service-name-lowercase}`。

### 4.2 Platform 组件（dynamo-platform Helm chart）

| 组件 | 类型 | 用途 |
|------|------|------|
| dynamo-operator | Deployment | 协调 DGD CRD |
| etcd | StatefulSet | Worker 注册 / 路由表持久化 |
| NATS | StatefulSet | 实时消息总线（KV 状态广播、任务队列） |
| kube-rbac-proxy | Sidecar | Operator metrics 端点鉴权 |

**单副本设计理由**：etcd/NATS 单副本足够单节点场景，多副本需要配置 raft/clustering，引入不必要复杂性。

### 4.3 Worker 注册流程

```
Worker Pod 启动
    ↓
vLLM engine 初始化（加载模型 → GPU 显存分配）
    ↓
Dynamo runtime 向 etcd 注册 Worker endpoint + 能力信息
    ↓
NATS 订阅 KV Cache 状态 topic
    ↓
Frontend（KV Router）发现新 Worker，加入路由池
    ↓
Worker Ready → Pod 变为 Running（readinessProbe 通过）
```

---

## 5. Disaggregated Inference 推理架构

### 5.1 为什么要 Disaggregated？

传统推理：Prefill + Decode 在**同一进程/GPU**中串行执行。

问题：
- Prefill（全 prompt 并行计算）是 **compute-bound**，吞吐量受算力限制
- Decode（逐 token 自回归）是 **memory-bandwidth-bound**，吞吐量受 HBM/VRAM 带宽限制
- 两者共用 GPU 导致互相干扰，长 prompt + 长 decode 场景 GPU 利用率低

Disaggregated 方案：
- **Prefill Worker**：专门做 prefill，GPU 满载计算，生成 KV Cache
- **Decode Worker**：专门做 decode，高效流水线自回归，读取 KV Cache
- **KV Transfer**：通过 NVLink / PCIe / RDMA 在 Prefill → Decode 之间传输 KV Cache 块

### 5.2 请求路由流程

```
客户端 POST /v1/chat/completions
    ↓
Frontend（KV Router）
    ├── 1. 计算 prompt hash / prefix hash
    ├── 2. 查询各 Prefill Worker 的 KV Cache 状态（via NATS）
    ├── 3. 选择 prefix cache hit 最高的 Prefill Worker（减少重复计算）
    └── 4. 派发 prefill 任务
                ↓
        Prefill Worker
            ├── 执行 prefill forward pass
            ├── 生成 KV Cache 块（每层 Attention 的 K/V 矩阵）
            └── 通过 KV Transfer 协议发送到 Decode Worker
                        ↓
                Decode Worker
                    ├── 接收 KV Cache 块
                    ├── 开始自回归 decode（每步生成一个 token）
                    └── 通过 NATS/gRPC 将 token 流返回 Frontend
                                ↓
                        Frontend 组装 SSE 响应流 → 客户端
```

### 5.3 KV Cache 亲和性路由的收益

当相同或相似 prompt 重复出现时（如系统 prompt 共享）：
- Prefill Worker 中的 prefix KV 块已缓存
- Router 将新请求路由到**同一个** Prefill Worker
- 跳过已缓存部分的前向计算 → TTFT 显著降低

用 `bash 03-test-router.sh` 中的 T5 测试可验证：12 次相同 prompt 后 `gpu_prefix_cache_hit_rate` 上升。

---

## 6. 部署脚本逐阶段说明

### 6.1 `k8s/install-k8s.sh`

| Stage | 内容 | 关键原因 |
|-------|------|---------|
| 禁用 swap | `swapoff -a` + 注释 /etc/fstab | kubelet 要求 swap=0，否则拒绝启动 |
| 加载内核模块 | `overlay`, `br_netfilter` | containerd 要求；网络策略桥接 |
| sysctl 网络转发 | `net.ipv4.ip_forward=1` | Pod 跨网络通信 |
| 安装 containerd | 配置 `SystemdCgroup = true` | 与 kubelet cgroup driver 一致 |
| kubeadm init | `--pod-network-cidr=10.244.0.0/16` | Flannel 默认网段 |
| 安装 Flannel CNI | 应用 `kube-flannel.yml` | Pod 间 overlay 网络 |
| 去除 master taint | `NoSchedule taint` 删除 | 单节点允许工作负载调度到 master |
| 安装 nvidia-ctk | `nvidia-ctk runtime configure` | 注册 nvidia runtime 到 containerd |
| 安装 GPU Operator | driver.enabled=false | 驱动已在宿主机，只装 toolkit |

### 6.2 `0.7.1/deploy-dynamo-0.7.1.sh`

| Stage | 内容 | 关键原因 |
|-------|------|---------|
| 0: 前置检查 | kubectl/helm/envsubst 可用 | 避免中途失败 |
| 0.5: RuntimeClass | 检查/创建 nvidia RuntimeClass | containerd 重启后可能丢失 |
| 0.7: GPU 探针 | 启动探针 Pod 验证 nvidia handler | 确认 GPU 可调度，早发现问题 |
| 1: 清理 | **GPU 竞争保护**：等待 Worker Pod 完全终止 + 30s | GPU 显存释放需要时间，过早创建新 DGD 导致 OOM |
| 2: 安装 CRDs | `kubectl apply -f crds/` | Operator 依赖 CRD 先存在 |
| 3: Namespace + Secrets | 创建 namespace，配置 HuggingFace token | Worker 拉取模型需要 HF_TOKEN |
| 4: Platform | Helm 安装 dynamo-platform（Operator+etcd+NATS） | 控制面先于数据面 |
| 5: DGD | `envsubst` 渲染 YAML → `kubectl apply` | 创建推理图 |
| 6: 等待就绪 | 轮询所有 Worker Pod Running | 模型加载耗时 5-15 分钟 |
| 7: Ingress | 安装 ingress-nginx | 外部 HTTP 入口 |
| 8: Prometheus Adapter | 桥接自定义指标到 K8s API | HPA 所需 |
| 9: HPA | 创建 3 个 HPA | 自动扩缩容 |
| 10: E2E 验证 | curl /v1/models + chat | 完整通路验证 |

### 6.3 GPU 竞争保护（Stage 1 核心逻辑）

```bash
# 删除旧 DGD
kubectl delete dgd vllm-v1-disagg-router -n "${NAMESPACE}" --ignore-not-found

# 等待所有 Worker Pod（有 label nvidia.com/dynamo-component-type=worker）完全消失
while kubectl get pods -n "${NAMESPACE}" \
  -l "nvidia.com/dynamo-component-type=worker" \
  --no-headers 2>/dev/null | grep -q .; do
  sleep 5
done

# 额外等待 30s，确保 GPU 显存完全释放（vLLM CUDA context 析构需要时间）
sleep 30
```

**背景**：vLLM 在进程退出后，CUDA context 和 GPU 显存并不立即被 OS 回收，实测需要 10-30 秒。若立即创建新 Worker，两者的显存会同时存在，导致 `cudaMalloc` 失败（OOM）。这是最常见的重新部署失败原因。

---

## 7. 可观测性：Prometheus + Grafana 数据流

### 7.1 指标采集路径

```
Dynamo Pod（vLLM + Dynamo runtime）
    ↓ /metrics 端点（HTTP :9000）
Prometheus（kube-prometheus-stack）
    ↓ ServiceMonitor 自动发现（label: app.kubernetes.io/part-of=dynamo）
Prometheus TSDB（存储 15 天）
    ↓ PromQL 查询
    ├── Grafana Dashboard（可视化）
    └── prometheus-adapter（桥接为 K8s Custom Metrics API）
              ↓ /apis/custom.metrics.k8s.io/v1beta1
              HPA Controller（读取指标，计算目标副本数）
```

### 7.2 关键 Dynamo 指标说明

| 指标名 | 类型 | 含义 | HPA 使用？ |
|--------|------|------|-----------|
| `dynamo_component_inflight_requests` | Gauge | 当前处理中请求数（per pod） | ✅ 是 |
| `dynamo_component_kvstats_gpu_cache_usage_percent` | Gauge | GPU KV Cache 占用率 | ✅ 是 |
| `dynamo_component_kvstats_gpu_prefix_cache_hit_rate` | Gauge | KV 前缀缓存命中率 | 否 |
| `dynamo_component_kvstats_active_blocks` | Gauge | 活跃 KV Cache 块数 | 否 |
| `dynamo_component_nats_client_connection_state` | Gauge | NATS 连接状态（1=连接） | 否 |
| `dynamo_frontend_inflight_requests` | Gauge | Frontend 正在排队/处理的请求 | 否 |
| `dynamo_frontend_time_to_first_token_seconds` | Histogram | TTFT 分布 | 否 |

### 7.3 prometheus-adapter 配置原理

`prometheus-adapter-values.yaml` 中的规则将 Prometheus 指标映射为 K8s Pod 级别的自定义指标：

```yaml
rules:
  custom:
    - seriesQuery: 'dynamo_component_inflight_requests{namespace!="",pod!=""}'
      resources:
        overrides:
          namespace: {resource: "namespace"}
          pod:       {resource: "pod"}
      name:
        matches: "dynamo_component_inflight_requests"
        as: "dynamo_inflight_requests"
      metricsQuery: 'avg_over_time(<<.Series>>{<<.LabelMatchers>>}[2m])'
```

HPA 的 `metrics` 字段引用 `pods/dynamo_inflight_requests`，controller-manager 每 15s 调用一次 Custom Metrics API 获取当前值。

---

## 8. HPA 自动扩缩容工作原理

### 8.1 HPA 决策算法

```
desiredReplicas = ceil(currentReplicas × (currentMetricValue / desiredMetricValue))
```

示例：
- DecodeWorker 当前 1 副本，inflight = 8，阈值 = 5
- desiredReplicas = ceil(1 × 8/5) = ceil(1.6) = **2**

### 8.2 扩缩容冷却机制

在 `hpa-decode-worker.yaml` 中：

```yaml
behavior:
  scaleUp:
    stabilizationWindowSeconds: 30    # 扩容决策：30s 内最大值生效
    policies:
      - type: Pods
        value: 1
        periodSeconds: 60             # 每分钟最多增加 1 个 Pod
  scaleDown:
    stabilizationWindowSeconds: 300   # 缩容决策：5 分钟最小值生效（防止 GPU 抖动）
```

**scaleDown 设置为 300s 的原因**：GPU Worker Pod 启动需要 5-10 分钟（模型加载），频繁缩容后立即扩容会导致服务中断。300s 窗口确保确实不再需要额外副本时才缩容。

### 8.3 GPU 资源限制下的 HPA 行为

单节点 8× GPU，每个 Worker 使用 1 GPU：
- Frontend: no GPU，可自由扩缩
- DecodeWorker: 1 GPU，最多扩到 min(maxReplicas, available_GPUs)
- PrefillWorker: 1 GPU，同上

当 GPU 全部被占用时，HPA 计算出 desiredReplicas > currentReplicas，但 Pod Pending（GPU 不足），HPA 不会无限尝试，调度保持 Pending 状态直到 GPU 释放。

---

## 9. 常见问题排查

### 9.1 Worker Pod CrashLoopBackOff / OOMKilled

**症状**：Worker Pod 反复重启，日志中出现 `CUDA out of memory` 或 `torch.cuda.OutOfMemoryError`

**原因**：
1. 旧 Worker 的 GPU 显存未完全释放就创建了新 Worker（竞争）
2. `GPU_MEMORY_UTIL` 过高（如 0.98），无剩余空间给 CUDA context

**排查**：
```bash
# 查看 Pod 日志
kubectl logs -n <ns> <worker-pod> --previous

# 检查节点 GPU 使用
kubectl exec -it <any-pod> -- nvidia-smi

# 查看事件
kubectl describe pod -n <ns> <worker-pod>
```

**修复**：
```bash
# 删除 DGD，等待 GPU 释放，再重建
kubectl delete dgd vllm-v1-disagg-router -n <ns>
sleep 60
kubectl apply -f manifests/dgd-vllm-disagg-router.yaml -n <ns>
```

### 9.2 GPU 驱动 / runtimeClassName 问题

**症状 A**：Worker Pod 日志 `libcuda.so.1: cannot open shared object file`

**原因**：containerd 默认运行时是 `runc`（而非 `nvidia`），容器内无 GPU 驱动

**修复（推荐）**：
```bash
# 将 nvidia 设为 containerd 默认运行时
sudo nvidia-ctk runtime configure --runtime=containerd --set-as-default
sudo systemctl restart containerd

# 验证
grep 'default_runtime_name' /etc/containerd/config.toml
# 应输出: default_runtime_name = "nvidia"
```

**症状 B**：Worker Pod 日志 `Free memory on device (X.XX/23.57 GiB)` — GPU OOM

**原因**：多个 Worker 被分配到同一物理 GPU。如果 DGD manifest 中设了 `runtimeClassName: nvidia`，containerd 走 RuntimeClass handler 路径，绕过 CDI 设备隔离，容器看到所有 GPU

**修复**：
1. 确保 DGD manifest 中 **不要** 设置 `runtimeClassName: nvidia`
2. 确保 containerd `default_runtime_name = "nvidia"`（见症状 A 的修复方法）
3. 删除旧 DGD 部署，等待 Pod 完全终止后重新部署

### 9.3 Namespace Terminating 卡死

**症状**：`kubectl delete namespace <ns>` 后，namespace 永久处于 Terminating 状态

**原因**：Custom Resources（DGD）有 finalizer，但 Operator 已删除，无法处理 finalizer

**修复**：
```bash
# 强制清除 namespace finalizers
kubectl get namespace <ns> -o json | \
  python3 -c "import sys,json; d=json.load(sys.stdin); \
    d['spec']['finalizers']=[]; print(json.dumps(d))" | \
  kubectl replace --raw "/api/v1/namespaces/<ns>/finalize" -f -
```

### 9.4 Custom Metrics APIService `<unknown>`

**症状**：`kubectl get hpa -n <ns>` 显示 TARGETS = `<unknown>/5`

**排查链**：
```bash
# 1. 检查 APIService 状态
kubectl get apiservice v1beta1.custom.metrics.k8s.io

# 2. 检查 prometheus-adapter Pod
kubectl get pods -n monitoring | grep adapter
kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus-adapter

# 3. 检查 Prometheus 是否已有该指标
# 先运行几个推理请求生成指标
curl http://localhost/v1/chat/completions ...

# 4. 直接查询 Custom Metrics API
kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/<ns>/pods/*/dynamo_inflight_requests"
```

### 9.5 Prometheus 采集不到 Dynamo Pod 指标

**症状**：Prometheus Targets 页面中 Dynamo Pod 的 State 为 `DOWN`

**原因**：ServiceMonitor label selector 不匹配，或 Dynamo Pod 的 `/metrics` 端口配置错误

**验证**：
```bash
# 检查 Dynamo Pod 是否暴露 /metrics
kubectl exec -n <ns> <dynamo-pod> -- curl -s localhost:9000/metrics | head -5

# 检查 ServiceMonitor
kubectl get servicemonitor -n <ns>
kubectl describe servicemonitor -n <ns> <name>
```

---

## 10. 开发迭代工作流

### 10.1 修改 Dynamo 代码 → 重新部署

```bash
# 1. 修改代码（本地 dynamo 仓库）
cd ~/dynamo
vim dynamo/components/frontend/router.py

# 2. 构建 Docker 镜像
# （registry 是你的镜像仓库地址，如 nvcr.io/your-org 或 localhost:5000）
docker build \
  -f container/Dockerfile \
  -t <registry>/dynamo:dev-$(git rev-parse --short HEAD) \
  .

# 3. 推送到镜像仓库
docker push <registry>/dynamo:dev-$(git rev-parse --short HEAD)

# 4. 若无镜像仓库（单节点），直接导入 containerd
docker save <registry>/dynamo:dev-<hash> | \
  sudo ctr images import -

# 5. 更新 DGD YAML 中的镜像版本
# 在 dgd-vllm-disagg-router.yaml 中修改：
#   image: <registry>/dynamo:dev-<hash>

# 6. 重新部署
bash 0.7.1/deploy-dynamo-0.7.1.sh
```

### 10.2 仅修改 YAML（如 replicas / 资源配置）

```bash
# 直接 apply，Operator 会 reconcile
export NAMESPACE=dynamo-system
export MODEL_NAME=Qwen/Qwen3-0.6B
export GPU_MEMORY_UTIL=0.90
export PREFILL_REPLICAS=1
export DECODE_REPLICAS=2   # 改为 2

envsubst < manifests/dgd-vllm-disagg-router.yaml | kubectl apply -f -

# 等待新 Pod 就绪
kubectl rollout status deployment/<dgd-name>-vllmdecodeworker -n $NAMESPACE
```

### 10.3 修改 manifests YAML（版本管理）

`manifests/` 目录下的所有文件均为模板，包含 `${VAR}` 占位符，应纳入 Git 版本管理。

```
tutorial/dynamo/
├── 0.7.1/
│   ├── manifests/       ← Git 跟踪，任何修改应 commit
│   │   ├── dgd-vllm-disagg-router.yaml
│   │   ├── dynamo-platform-values.yaml
│   │   ├── hpa-*.yaml
│   │   ├── ingress-*.yaml
│   │   └── prometheus-adapter-values.yaml
│   └── deploy-dynamo-0.7.1.sh   ← 部署入口，偶尔修改
└── k8s/
    ├── install-k8s.sh            ← 一次性，极少修改
    └── deploy-Prometheus-Grafana.sh
```

**修改 manifests 的工作流**：
```bash
# 修改 YAML
vim manifests/hpa-decode-worker.yaml

# 测试渲染结果（不实际 apply）
NAMESPACE=test envsubst < manifests/hpa-decode-worker.yaml

# 确认无误后 apply
NAMESPACE=dynamo-system envsubst < manifests/hpa-decode-worker.yaml | kubectl apply -f -

# Commit 变更
git add manifests/hpa-decode-worker.yaml
git commit -m "hpa: increase decode worker max replicas to 4"
```

### 10.4 调试推理问题

```bash
# 实时查看 Frontend 日志（路由决策）
kubectl logs -f -n $NAMESPACE -l nvidia.com/dynamo-component-type=frontend

# 实时查看 Prefill Worker 日志
kubectl logs -f -n $NAMESPACE \
  $(kubectl get pods -n $NAMESPACE -l nvidia.com/dynamo-component-type=worker \
    --no-headers | grep prefill | head -1 | awk '{print $1}')

# 进入 Worker Pod 检查 GPU 状态
kubectl exec -it -n $NAMESPACE <worker-pod> -- nvidia-smi

# 查看 NATS 消息流（需要 nats-cli）
kubectl exec -it -n $NAMESPACE \
  $(kubectl get pods -n $NAMESPACE -l app=nats --no-headers | head -1 | awk '{print $1}') \
  -- nats sub ">"
```

### 10.5 性能基线测试

```bash
# 精确测量 TTFT / E2E / ITL
bash test-dynamo/0.7.1/04-test-load.sh \
  --mode python \
  --concurrency 10 \
  --total 100 \
  --max-tokens 200 \
  --stream

# 结果示例：
# QPS:    2.4
# TTFT P50: 0.312s    P99: 1.203s
# E2E  P50: 4.521s    P99: 12.1s
# ITL  均值: 42ms
```

---

## 附录：脚本依赖关系图

```
空白 Ubuntu 服务器
    │
    ▼
k8s/install-k8s.sh              ← 一次性，需要 NODE_IP
    │
    ▼
k8s/deploy-Prometheus-Grafana.sh  ← 一次性，部署监控栈
    │
    ▼
0.7.1/deploy-dynamo-0.7.1.sh    ← 每次重新部署 Dynamo 时运行
    │
    ▼
test-dynamo/0.7.1/00-setup-env.sh  ← 部署 Ingress + HPA + prometheus-adapter
    │
    ├── 01-start-monitoring.sh   ← 开一个终端持续运行（端口转发）
    │
    ├── 02-test-hpa.sh           ← 验证 HPA 配置
    │
    ├── 03-test-router.sh        ← 验证 KV Router 路由
    │
    └── 04-test-load.sh          ← 压测 + 性能基线
```
