# NVIDIA Dynamo 源代码架构深度分析：从 v0.7.1 到 v1.0.x

> 分析日期：2026年7月
> 项目地址：https://github.com/ai-dynamo/dynamo
> 前置文档：`Dynamo_Version_Comparison.md`（v0.7.1 / v0.8.1 / v0.9.1 功能对比）

---

## 目录

**第一部分：架构与版本分析**

1. [核心问题解答：为什么源代码有 Router/Mocker/Planner，部署只需 3 个组件？](#一核心问题解答)
2. [源代码仓库全景架构](#二源代码仓库全景架构)
3. [组件深度解析](#三组件深度解析)
4. [部署脚本使用指南](#四部署脚本使用指南)
5. [v0.7.1 vs v1.0.x 部署对比](#五v071-vs-v10x-部署对比)
6. [版本演进路线图 v0.7.0 → v1.1.0](#六版本演进路线图)
7. [Breaking Changes 完整清单](#七breaking-changes-完整清单)
8. [技术选型与学习路线](#八技术选型与学习路线)

**第二部分：Planner 深度分析与模型加载架构**

9. [HPA vs Planner：到底该用哪个？](#九hpa-vs-planner到底该用哪个)
10. [Planner v0.7.1 vs v1.0.x 详细功能对比](#十planner-v071-vs-v10x-详细功能对比)
11. [Scaling 实现原理：从源码深度分析](#十一scaling-实现原理从源码深度分析)
12. [Planner 下一步改进方向](#十二planner-下一步改进方向)
13. [模型加载架构：为什么每个 Pod 需要自己的模型？](#十三模型加载架构为什么每个-pod-需要自己的模型)
14. [Dynamo Snapshot：解决模型加载慢的官方方案](#十四dynamo-snapshot解决模型加载慢的官方方案)

---

## 一、核心问题解答

### 1.1 "为什么源代码有 Router/Mocker/Planner，部署只需 Frontend + Prefill + Decode？"

这是理解 Dynamo 架构的关键问题。答案是 **组件关系不是并列的，而是嵌套/可选/工具性质的**：

```
源代码组件                              部署时的实际角色
────────────────────────────────────────────────────────────────
Frontend  ─────────────────────────→  部署为 Frontend Pod
  ├── HTTP Server (OpenAI API)          （公开 :8000 端口）
  ├── Pre-processor                     （请求预处理）
  ├── Router ◀── 嵌入在 Frontend 内     （路由决策，非独立部署）
  └── Auto-discovery                    （自动发现 Worker）

Router    ─────────────────────────→  ⚠️ 不独立部署！嵌入在 Frontend 中
  └── KV-Aware Routing                  通过 DYN_ROUTER_MODE=kv 启用

Planner   ─────────────────────────→  ⚡ 可选组件，仅 SLA 驱动场景需要
  ├── SLA-Based Planning                （需要预先 Profiling 数据）
  └── Load-Based Planning               （运行时负载感知）

Mocker    ─────────────────────────→  🔧 纯工具组件，不参与生产部署
  └── Mock Worker                       （模拟推理负载，用于 Profiling/测试）

VllmDecodeWorker ──────────────────→  部署为 Decode Worker Pod
VllmPrefillWorker ─────────────────→  部署为 Prefill Worker Pod
```

**三个关键结论：**

| 组件 | 源代码位置 | 部署角色 | 说明 |
|------|-----------|---------|------|
| **Router** | `components/src/dynamo/router/` | **嵌入在 Frontend** | Router不是独立进程，而是 Frontend 的内部模块。启动 Frontend 时通过 `--router-mode kv` 激活 KV 感知路由 |
| **Mocker** | `components/src/dynamo/mocker/` | **不参与生产部署** | Mock Worker 用于模拟推理负载，供 Profiler 采集性能数据、供 Planner 离线测试调度逻辑。是开发/测试工具 |
| **Planner** | `components/src/dynamo/planner/` | **可选的第 4 个组件** | 仅 SLA 驱动的自动扩缩场景需要。基础部署用 K8s HPA 即可替代。需要预先运行 Profiler 采集性能曲线数据 |

### 1.2 Dynamo 部署架构全家福

```
┌──────────────────────────────────────────────────────────────────────┐
│                     Dynamo 完整组件关系图                              │
│                                                                      │
│  ┌─────────────┐    ┌──────────────────────────────────────────────┐ │
│  │   Client     │───→│  Frontend Pod                                │ │
│  │ (curl/SDK)   │    │  ┌──────────┐ ┌────────┐ ┌──────────────┐  │ │
│  └─────────────┘    │  │HTTP Server│→│Pre-proc│→│   Router     │  │ │
│                      │  │ :8000     │ │        │ │(KV-Aware/RR) │  │ │
│                      │  └──────────┘ └────────┘ └──────┬───────┘  │ │
│                      └──────────────────────────────────┼──────────┘ │
│                                                         │            │
│                        ┌────────────────────────────────┤            │
│                        ▼                                ▼            │
│  ┌─────────────────────────┐    ┌──────────────────────────────┐    │
│  │  Prefill Worker Pod     │    │    Decode Worker Pod          │    │
│  │  python -m dynamo.vllm  │───→│    python -m dynamo.vllm     │    │
│  │  --is-prefill-worker    │NIXL│    (or --is-decode-worker)   │    │
│  │  (v0.7.1)               │    │                              │    │
│  │  --disaggregation-mode  │    │    --disaggregation-mode     │    │
│  │  prefill (v1.0.x)       │    │    decode (v1.0.x)           │    │
│  └─────────────────────────┘    └──────────────────────────────┘    │
│                                                                      │
│  ┌─ 可选组件 ────────────────────────────────────────────────────┐   │
│  │                                                                │   │
│  │  ┌──────────────┐    ┌──────────────┐    ┌────────────────┐   │   │
│  │  │  Planner     │    │  Profiler     │    │  Mocker        │   │   │
│  │  │  (SLA 调度)   │◀───│  (性能采集)   │◀───│  (模拟负载)    │   │   │
│  │  │  componentType│    │  独立运行     │    │  Mock Worker   │   │   │
│  │  │  : planner    │    │  生成曲线数据  │    │  不需要 GPU    │   │   │
│  │  └──────────────┘    └──────────────┘    └────────────────┘   │   │
│  │                                                                │   │
│  │  v1.0.0+ 新增:                                                 │   │
│  │  ┌──────────────────┐    ┌────────────────────┐                │   │
│  │  │  GlobalPlanner   │    │  GlobalRouter       │                │   │
│  │  │  跨 DGD 调度      │    │  多模型请求路由      │                │   │
│  │  └──────────────────┘    └────────────────────┘                │   │
│  └────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 二、源代码仓库全景架构

### 2.1 v0.7.1 目录结构

```
dynamo/                           # 仓库根目录
├── components/                    # ★ 核心组件（Python + Rust）
│   └── src/dynamo/
│       ├── common/               # 共享工具：日志、配置、通信
│       ├── frontend/             # Frontend = HTTP + Router + Pre-processor + Auto-discovery
│       ├── router/               # Router 算法实现（被 Frontend 调用，非独立进程）
│       ├── planner/              # Planner: SLA 驱动调度（可选组件）
│       ├── mocker/               # Mocker: 模拟 Worker（开发工具）
│       ├── vllm/                 # vLLM 后端集成
│       ├── sglang/               # SGLang 后端集成
│       └── trtllm/               # TensorRT-LLM 后端集成
│
├── lib/                           # ★ Rust 核心库
│   ├── runtime/                  # Dynamo 运行时（服务发现、RPC、生命周期）
│   ├── llm/                      # LLM 抽象层（含 mocker crate）
│   ├── config/                   # 配置管理
│   ├── kvbm/                     # KV Block Manager（KV 缓存管理）
│   ├── memory/                   # 内存管理
│   ├── tokens/                   # Tokenizer 封装
│   ├── parsers/                  # 请求解析
│   ├── bindings/                 # Python ↔ Rust FFI 绑定
│   └── async-openai/             # OpenAI API 异步客户端
│
├── deploy/                        # ★ 平台级部署
│   ├── helm/                     # Helm Charts（Operator + CRD）
│   ├── cloud/                    # 云服务部署脚本（v1.0+ 已移除）
│   ├── discovery/                # 服务发现组件（v1.0+ 已移除）
│   ├── inference-gateway/        # API Gateway
│   ├── observability/            # Prometheus + Grafana
│   └── utils/                    # 部署工具
│
├── examples/                      # ★ 示例与部署模板
│   ├── backends/
│   │   ├── vllm/
│   │   │   ├── deploy/           # K8s DGD YAML 模板 ← 主要部署文件
│   │   │   └── launch/           # 本地启动脚本 ← 开发调试用
│   │   ├── sglang/
│   │   │   ├── deploy/
│   │   │   └── launch/
│   │   └── trtllm/
│   │       ├── deploy/
│   │       └── launch/
│   ├── basics/                   # 快速入门示例
│   │   ├── quickstart/
│   │   ├── disaggregated_serving/
│   │   └── multinode/
│   ├── deployments/              # 各云平台部署
│   │   ├── EKS/
│   │   ├── AKS/
│   │   ├── ECS/
│   │   └── router_standalone/
│   └── multimodal/               # 多模态示例
│
├── container/                     # Docker 构建
│   └── build.sh                  # 构建命令: ./container/build.sh --framework VLLM
│
├── benchmarks/                    # 性能基准测试
├── recipes/                       # 模型特定配置
└── tests/                         # 测试套件
```

### 2.2 v1.0.x (main) 目录变化

```diff
 components/src/dynamo/
   common/
   frontend/
+  global_planner/               # ★ 新增：跨 DGD 全局调度器
+  global_router/                # ★ 新增：多模型请求路由
   mocker/
   planner/
+  profiler/                     # ★ 新增：独立 Profiler 组件
   router/
   sglang/
   trtllm/
   vllm/

 deploy/
-  cloud/                        # ✗ 已移除
-  discovery/                    # ✗ 已移除
   helm/
   inference-gateway/
   observability/
+  operator/                     # ★ 新增：独立 Operator 目录
+  pre-deployment/               # ★ 新增：预部署验证
+  snapshot/                     # ★ 新增：CRIU GPU Worker 快照恢复
   utils/

 examples/backends/vllm/deploy/
+  gaie/                         # ★ 新增：GAIE 网关集成
+  lora/                         # ★ 新增：Multi-LoRA 部署模板
   agg.yaml
   agg_router.yaml
+  agg_router_kv_approx.yaml    # ★ 新增：近似 KV 路由
+  agg_tracing.yaml             # ★ 新增：分布式追踪
+  agg_xpu_dra.yaml             # ★ 新增：Intel XPU 支持
   disagg.yaml
   disagg_router.yaml
   disagg_planner.yaml
+  disagg_tracing.yaml          # ★ 新增
+  disagg_xpu_dra.yaml          # ★ 新增

 examples/backends/vllm/launch/
+  lora/                         # ★ 新增：LoRA 启动脚本
+  stage_configs/                # ★ 新增：阶段配置
+  xpu/                          # ★ 新增：Intel XPU 脚本
+  agg_flexkv.sh                # ★ 新增：FlexKV 启动
+  agg_flexkv_router.sh
+  agg_omni.sh                  # ★ 新增：Omni 模型
+  agg_omni_audio.sh
+  agg_omni_image.sh
+  agg_omni_video.sh
+  agg_spec_decoding.sh         # ★ 新增：投机解码
+  disagg_flexkv.sh
+  disagg_multimodal_e_pd.sh    # ★ 新增：Encoder-PD 分离多模态
+  disagg_multimodal_p_d.sh
+  multi_node_tp.sh             # ★ 新增：多节点 TP/PP
+  launch_utils.sh              # ★ 新增：共享启动工具函数
```

---

## 三、组件深度解析

### 3.1 Frontend — 请求入口（必须部署）

**源代码位置**: `components/src/dynamo/frontend/`

**职责**: OpenAI 兼容 HTTP Server + 请求预处理 + 路由分发 + Worker 自动发现

**启动方式**:
```bash
# 本地启动
python -m dynamo.frontend \
    --router-mode kv \       # 启用 KV-aware 路由（可选 kv / round-robin）
    --http-port 8000 \
    --router-reset-states    # 重启时清除路由状态

# K8s DGD YAML 中
spec:
  services:
    Frontend:
      componentType: frontend
      replicas: 1
      envs:
        - name: DYN_ROUTER_MODE
          value: kv
```

**关键配置**:
| 参数 | 含义 | 默认值 |
|------|------|--------|
| `--router-mode` | 路由模式: `kv`(KV-cache感知) / `round-robin` | round-robin |
| `--http-port` | HTTP 端口 | 8000 |
| `--router-reset-states` | 启动时重置路由状态 | false |
| `DYN_ROUTER_MODE` | K8s 环境变量形式 | - |

### 3.2 Router — 路由算法（嵌入在 Frontend 中）

**源代码位置**: `components/src/dynamo/router/`

**本质**: Router 是 Frontend 内部模块，不需要独立部署。当 Frontend 以 `--router-mode kv` 启动时，会加载 Router 的 KV-Aware 路由算法。

**工作原理**:
```
Client Request → Frontend HTTP Server
                    │
                    ▼
              Pre-processor（Tokenize、转换格式）
                    │
                    ▼
              Router（选择最优 Worker）
              ├── Round-Robin: 轮询分发（默认）
              └── KV-Aware: 基于 KV Cache 匹配率选择 Worker
                    │
                    ▼
              分发到 PrefillWorker（disagg 模式）
              或直接到 DecodeWorker（agg 模式）
```

**v0.7.1 vs v1.0.x Router 变化**:
| 能力 | v0.7.1 | v1.0.x |
|------|--------|--------|
| Round-Robin | ✅ | ✅ |
| KV-Aware 基础路由 | ✅ | ✅ |
| 最大树大小裁剪 | ❌ | ✅ |
| 动态拒绝阈值 | ❌ | ✅ |
| 早期拒绝 | ❌ | ✅ |
| P→D 请求取消 | ❌ | ✅ |
| LoRA-Aware | ❌ | ✅ |
| 路由提示(Header) | ❌ | ✅ |
| 近似 KV 匹配 | ❌ | ✅ (kv_approx) |
| 独立远程 Indexer | ❌ | ✅ (v1.1.0-dev) |

### 3.3 Planner — SLA 驱动调度器（可选组件）

**源代码位置**: `components/src/dynamo/planner/`

**本质**: Planner 是一个 **可选的独立 Pod**，监控系统状态并动态调整 Prefill/Decode Worker 的副本数。如果不需要 SLA 驱动的自动扩缩容，使用 K8s HPA 即可替代。

**什么时候需要 Planner**:
| 场景 | 是否需要 Planner |
|------|-----------------|
| 开发测试 | ❌ 不需要，手动指定 replicas |
| 生产环境 + K8s HPA | ❌ 不需要，HPA 根据 CPU/GPU 指标扩缩 |
| 生产环境 + SLA 目标 (如 TTFT < 200ms) | ✅ 需要，Planner 根据性能曲线智能调度 |
| 多模型共享 GPU 池 | ✅ 需要 GlobalPlanner (v1.0.0+) |

**Planner 部署要求**:
1. **前置步骤**: 运行 Profiler 采集性能曲线数据（TTFT vs ISL, ITL vs KV用量）
2. **数据格式**: 通过 ConfigMap 挂载 `prefill_raw_data.json` + `decode_raw_data.json`
3. **独立 Pod**: `componentType: planner`, 运行 `python -m dynamo.planner`

**v0.7.1 Planner 启动命令**:
```bash
python3 -m planner_sla \
    --environment=kubernetes \
    --backend=vllm \
    --adjustment-interval=60 \
    --profile-results-dir=/workspace/profiling_results
```

**v1.0.x Planner 启动命令** (统一入口):
```bash
python3 -m dynamo.planner \
    --config '{"environment": "kubernetes", "backend": "vllm",
               "throughput_adjustment_interval": 60,
               "profile_results_dir": "/workspace/profiling_results"}'
```

### 3.4 Mocker — 模拟推理工具（仅开发/测试）

**源代码位置**: `components/src/dynamo/mocker/` + `lib/llm/` (mocker crate)

**本质**: Mocker 是一个 **开发工具**，模拟 GPU Worker 的推理行为（生成假的 token 输出和 KV 缓存指标），用于：
- **Profiler 采集性能基线**：不需要真实 GPU 就能生成性能曲线数据
- **Planner 离线调试**：验证调度逻辑是否正确，无需真实推理负载
- **基准测试**：模拟特定延迟/吞吐量场景

**v1.1.0-dev.1 新增**:
- `--decode-speedup-ratio`: 模拟投机解码的加速比

**Mocker 完全不参与生产部署流程。**

### 3.5 Profiler — 性能采集器（v1.0.x 独立组件）

**源代码位置**: `components/src/dynamo/profiler/` (v1.0.x)

**功能**: 运行基准测试，采集模型在特定 GPU 上的性能曲线，生成 Planner 所需的 Profiling 数据。

**工作流**:
```
Profiler → (可选) Mocker 或真实 Worker → 采集 TTFT/ITL 曲线 → 生成 JSON → 挂载到 Planner ConfigMap
```

### 3.6 GlobalPlanner / GlobalRouter — v1.0.0+ 新增

| 组件 | 用途 | 场景 |
|------|------|------|
| **GlobalPlanner** | 跨多个 DGD (DynamoGraphDeployment) 进行 GPU 预算分配 | 多模型共享 GPU 池，`--max-total-gpus N` 控制集群预算 |
| **GlobalRouter** | 在多个模型之间路由请求 | 单一入口点 → 根据请求分发到不同模型的 DGD |

---

## 四、部署脚本使用指南

### 4.1 两套脚本体系

Dynamo 源代码中有 **两套并行的部署脚本**，服务不同的使用场景：

| 脚本位置 | 格式 | 用途 | 适用环境 |
|---------|------|------|---------|
| `examples/backends/vllm/deploy/` | K8s DGD YAML | 生产 K8s 部署 | K8s 集群 + Dynamo Operator |
| `examples/backends/vllm/launch/` | Bash 脚本 | 本地开发调试 | 裸机 / Docker，有 GPU |

### 4.2 K8s 部署 YAML — `examples/backends/vllm/deploy/`

#### 可用模板一览

| 文件 | 架构模式 | 服务组件 | GPU 需求 | 适用场景 |
|------|---------|---------|---------|---------|
| `agg.yaml` | 聚合 | Frontend + Worker(1) | 1 GPU | 开发测试 |
| `agg_router.yaml` | 聚合+路由 | Frontend(KV-Router) + Worker(N) | N GPU | 生产负载均衡 |
| `disagg.yaml` | 分离 PD | Frontend + Prefill + Decode | 2+ GPU | 高性能推理 |
| `disagg_router.yaml` | 分离 PD+KV路由 | Frontend(KV-Router) + Prefill + Decode | 2+ GPU | 最高性能 |
| `disagg_planner.yaml` | 分离 PD+SLA调度 | Frontend + Planner + Prefill + Decode | 2+ GPU | SLA 驱动 |
| `agg_kvbm.yaml` | 聚合+KVBM | Frontend + Worker(KVBM) | 1+ GPU | KV 缓存管理 |
| `disagg_kvbm.yaml` | 分离+KVBM | Frontend + Prefill + Decode(KVBM) | 2+ GPU | KV 缓存对象存储 |
| `disagg-multinode.yaml` | 多节点分离 | 跨节点 Frontend + Prefill + Decode | 多节点 | 大模型多节点推理 |

**v1.0.x 新增模板**:

| 文件 | 说明 |
|------|------|
| `agg_router_kv_approx.yaml` | 近似 KV 匹配路由（更快的路由决策） |
| `agg_tracing.yaml` / `disagg_tracing.yaml` | OpenTelemetry 分布式追踪 |
| `agg_xpu_dra.yaml` / `disagg_xpu_dra.yaml` | Intel XPU (K8s DRA) |
| `gaie/` | Gateway API for Inference Extension 集成 |
| `lora/` | Multi-LoRA 部署 |

#### 使用流程

```bash
# 1. 创建 HuggingFace Token Secret
# 先通过安全渠道获取 HF_TOKEN 并设置环境变量
export HF_TOKEN=<从密钥管理工具获取>
kubectl create secret generic hf-token-secret \
    --from-literal=HF_TOKEN=${HF_TOKEN} \
    -n ${NAMESPACE}

# 2. 选择部署模板
cd <dynamo-source-root>/examples/backends/vllm/deploy

# 3. (可选) 替换镜像
export FRAMEWORK_RUNTIME_IMAGE=nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.1
yq '.spec.services.[].extraPodSpec.mainContainer.image = env(FRAMEWORK_RUNTIME_IMAGE)' \
    disagg_router.yaml > disagg_router.generated.yaml

# 4. 部署
kubectl apply -f disagg_router.yaml -n $NAMESPACE

# 5. 端口转发
kubectl port-forward deployment/vllm-v1-disagg-router-frontend-<uuid> 8000:8000

# 6. 测试
curl localhost:8000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model": "Qwen/Qwen3-0.6B", "messages": [{"role": "user", "content": "Hello"}], "max_tokens": 30}'
```

### 4.3 本地启动脚本 — `examples/backends/vllm/launch/`

#### 脚本类型

| 脚本 | 对应 YAML | GPU 需求 | 说明 |
|------|----------|---------|------|
| `agg.sh` | `agg.yaml` | 1 GPU | 单 Worker 聚合 |
| `agg_router.sh` | `agg_router.yaml` | 2+ GPU | 多 Worker + KV 路由 |
| `disagg.sh` | `disagg.yaml` | 2+ GPU | PD 分离 |
| `disagg_router.sh` | `disagg_router.yaml` | 4 GPU | PD 分离 + KV 路由 |
| `dep.sh` | - | 1 GPU | 仅 etcd + NATS 依赖服务 |
| `dsr1_dep.sh` | - | 1 GPU | DeepSeek R1 依赖服务 |

#### 本地启动示例（disagg_router.sh 解析）

**v0.7.1 版本**:
```bash
#!/bin/bash
set -e
trap 'echo Cleaning up...; kill 0' EXIT

export PYTHONHASHSEED=0
MODEL="Qwen/Qwen3-0.6B"
BLOCK_SIZE=64

# 1. 启动 Frontend（内含 Router）
python -m dynamo.frontend \
    --router-mode kv \
    --http-port 8000 \
    --router-reset-states &

# 2. 启动 2 个 Decode Worker
CUDA_VISIBLE_DEVICES=0 python3 -m dynamo.vllm \
    --model $MODEL --block-size $BLOCK_SIZE --enforce-eager \
    --kv-events-config '{"publisher":"zmq",...,"endpoint":"tcp://*:20080",...}' &

CUDA_VISIBLE_DEVICES=1 python3 -m dynamo.vllm \
    --model $MODEL --block-size $BLOCK_SIZE --enforce-eager \
    --kv-events-config '{"publisher":"zmq",...,"endpoint":"tcp://*:20081",...}' &

# 3. 启动 2 个 Prefill Worker（--is-prefill-worker 标志）
CUDA_VISIBLE_DEVICES=2 python3 -m dynamo.vllm \
    --model $MODEL --block-size $BLOCK_SIZE --enforce-eager \
    --is-prefill-worker \
    --kv-events-config '{"publisher":"zmq",...,"endpoint":"tcp://*:20082",...}' &

CUDA_VISIBLE_DEVICES=3 python3 -m dynamo.vllm \
    --model $MODEL --block-size $BLOCK_SIZE --enforce-eager \
    --is-prefill-worker \
    --kv-events-config '{"publisher":"zmq",...,"endpoint":"tcp://*:20083",...}' &

wait
```

**v1.0.x 版本的关键变化**:
```bash
#!/bin/bash
set -e
trap 'echo Cleaning up...; kill 0' EXIT

# ★ 新增：共享工具函数
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/../../../common/launch_utils.sh"

export PYTHONHASHSEED=0
MODEL="Qwen/Qwen3-0.6B"
BLOCK_SIZE=64

# ★ 新增：启动 banner
print_launch_banner "Launching Disaggregated + KV Routing (4 GPUs)" "$MODEL" "$HTTP_PORT"

# Frontend 启动（相同）
python -m dynamo.frontend --router-mode kv --router-reset-states &

# ★ 变化1: --is-prefill-worker → --disaggregation-mode prefill
# ★ 变化2: --is-decode-worker → --disaggregation-mode decode
# ★ 变化3: 新增 --kv-transfer-config NixlConnector

CUDA_VISIBLE_DEVICES=0 python3 -m dynamo.vllm \
    --model $MODEL --block-size $BLOCK_SIZE --enforce-eager \
    --disaggregation-mode decode \                    # ← 新 CLI 参数
    --kv-transfer-config '{"kv_connector":"NixlConnector","kv_role":"kv_both"}' &  # ← 显式 KV 传输

CUDA_VISIBLE_DEVICES=2 python3 -m dynamo.vllm \
    --model $MODEL --block-size $BLOCK_SIZE --enforce-eager \
    --disaggregation-mode prefill \                   # ← 新 CLI 参数
    --kv-transfer-config '{"kv_connector":"NixlConnector","kv_role":"kv_both"}' \
    --kv-events-config '{"publisher":"zmq",...}' &

wait_any_exit  # ★ 新增：任一进程退出则清理其余
```

### 4.4 Planner 部署脚本 — `disagg_planner.yaml`

Planner 是额外的第 4 个组件，需要 Profiling 数据。以下对比两个版本的 Planner YAML：

**v0.7.1 — `disagg_planner.yaml`**:
```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: vllm-disagg-planner
spec:
  services:
    Frontend:
      dynamoNamespace: vllm-disagg-planner
      componentType: frontend
      replicas: 1
      extraPodSpec:
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.1

    Planner:                                    # ← 独立组件
      dynamoNamespace: vllm-disagg-planner
      componentType: planner
      replicas: 1
      extraPodSpec:
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.1
          workingDir: /workspace/components/src/dynamo/planner    # ← 源码路径
          command: [python3, -m, planner_sla]                     # ← 模块名
          args:
            - --environment=kubernetes
            - --backend=vllm
            - --adjustment-interval=60
            - --profile-results-dir=/workspace/profiling_results
          volumeMounts:
            - name: planner-profile-data
              mountPath: /workspace/profiling_results
              readOnly: true
        volumes:
          - name: planner-profile-data
            configMap:
              name: planner-profile-data          # ← 必须预先创建

    VllmDecodeWorker:
      componentType: worker
      subComponentType: decode
      replicas: 1
      resources:
        limits: { gpu: "1" }
      # ... (标准 Worker 配置)

    VllmPrefillWorker:
      componentType: worker
      subComponentType: prefill
      replicas: 1
      resources:
        limits: { gpu: "1" }
      # ... (标准 Worker 配置，含 --is-prefill-worker)
```

**v1.0.x — `disagg_planner.yaml`** 的变化:
```yaml
# 关键差异:
Planner:
  componentType: planner
  replicas: 1
  extraPodSpec:
    mainContainer:
      image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:my-tag   # ← 通用 tag
      command: [python3, -m, dynamo.planner]                  # ← 统一入口
      args:
        - --config
        - '{"environment": "kubernetes", "backend": "vllm",
            "throughput_adjustment_interval": 60,
            "profile_results_dir": "/workspace/profiling_results"}'
      # ... 同样需要 ConfigMap 挂载

VllmPrefillWorker:
  # ...
  args:
    - --disaggregation-mode        # ← 替代 --is-prefill-worker
    - prefill
    - --kv-transfer-config         # ← 新增显式 KV 传输配置
    - '{"kv_connector":"NixlConnector","kv_role":"kv_both"}'
```

---

## 五、v0.7.1 vs v1.0.x 部署对比

### 5.1 容器镜像

| 维度 | v0.7.1 | v1.0.x (main) |
|------|--------|---------------|
| **镜像仓库** | `nvcr.io/nvidia/ai-dynamo/` | `nvcr.io/nvidia/ai-dynamo/` |
| **vLLM 镜像** | `vllm-runtime:0.7.1` | `vllm-runtime:my-tag` (需替换) |
| **SGLang 镜像** | `sglang-runtime:0.7.1` | `sglang-runtime:my-tag` |
| **TRT-LLM 镜像** | `trtllm-runtime:0.7.1` | `trtllm-runtime:my-tag` |
| **构建命令** | `./container/build.sh --framework VLLM` | `python container/render.py --framework=vllm --output-short-filename` + `docker build` |
| **NGC 公开镜像** | ✅ 可直接拉取 | ✅ CUDA 镜像公开可用 |

### 5.2 DGD YAML 配置差异

| 配置项 | v0.7.1 | v1.0.x |
|--------|--------|--------|
| **dynamoNamespace** | 必须手动指定 | 自动计算（可省略） |
| **Prefill 标志** | `--is-prefill-worker` | `--disaggregation-mode prefill` |
| **Decode 标志** | `--is-decode-worker` 或无 | `--disaggregation-mode decode` |
| **KV 传输配置** | 隐式（内置 NIXL） | 显式 `--kv-transfer-config '{"kv_connector":"NixlConnector",...}'` |
| **KV Events** | 通过 kv-events-config | 通过 kv-events-config（格式相同） |
| **Planner 入口** | `python -m planner_sla` | `python -m dynamo.planner` |
| **Planner 配置** | 独立 CLI args | 统一 `--config JSON` |
| **ephemeral-storage** | 无 | `requests.custom.ephemeral-storage: "2Gi"` |

### 5.3 基础设施依赖

| 依赖 | v0.7.1 | v1.0.x |
|------|--------|--------|
| **etcd** | 通常必需（K8s 模式可选） | 完全可选（K8s EndpointSlices 替代） |
| **NATS** | 通常必需 | 完全可选（TCP 请求传输替代） |
| **Dynamo Operator** | 必需（部署 DGD CRD） | 必需（增强版，含 Webhooks） |
| **Prometheus** | 推荐 | 推荐 |
| **Grafana** | 推荐 | 推荐（更多内置 Dashboard） |

### 5.4 HPA 策略对比

#### v0.7.1 — 手动 HPA

我们之前在 `setup.sh` 中实现的手动 HPA：

```yaml
# 通过 prometheus-adapter 暴露自定义指标
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: decode-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: vllm-decode-worker
  minReplicas: 1
  maxReplicas: 4
  metrics:
    - type: Pods
      pods:
        metric:
          name: dynamo_request_queue_size  # Prometheus 自定义指标
        target:
          type: AverageValue
          averageValue: "5"
```

**局限**: 手动配置、单维度指标、无法跨组件协调。

#### v1.0.x — 多层扩缩容选择

| 方式 | 适用场景 | 智能程度 |
|------|---------|---------|
| **K8s HPA** | 简单场景，CPU/GPU 指标 | ⭐ |
| **Planner (SLA)** | 单 DGD，SLA 目标驱动 | ⭐⭐⭐ |
| **GlobalPlanner** | 多 DGD，GPU 预算共享 | ⭐⭐⭐⭐ |
| **DGD Scaling Adapter** | Planner → DGD 副本同步 | ⭐⭐ (配合 Planner) |

**GlobalPlanner 示例 (v1.0.0+)**:
```yaml
# 多模型共享 GPU 池
GlobalPlanner:
  --max-total-gpus 8       # 集群 GPU 预算
  --target-model model-a   # 模型 A 的 DGD
  --target-model model-b   # 模型 B 的 DGD
  # GlobalPlanner 根据实时负载在模型间分配 GPU
```

### 5.5 完整部署对比表

| 维度 | v0.7.1 disagg_router | v1.0.x disagg_router |
|------|---------------------|---------------------|
| **Frontend Pod** | 1× Frontend (KV Router) | 1× Frontend (KV Router) |
| **Decode Pod** | N× `--is-decode-worker` 或无标志 | N× `--disaggregation-mode decode` |
| **Prefill Pod** | N× `--is-prefill-worker` | N× `--disaggregation-mode prefill` |
| **镜像 Tag** | `vllm-runtime:0.7.1` | `vllm-runtime:<版本>` |
| **etcd** | 需要 | 可选 |
| **NATS** | 需要 | 可选 |
| **KV 传输** | 隐式 NIXL | 显式 `--kv-transfer-config NixlConnector` |
| **KV Events** | ZMQ pub/sub | ZMQ pub/sub（相同） |
| **Planner** | 可选 (`planner_sla`) | 可选 (`dynamo.planner`) |
| **GlobalPlanner** | ❌ | ✅ 可选 |
| **GPU 需求** | 4 GPU (2P+2D) | 4 GPU (2P+2D) |
| **测试命令** | `curl localhost:8000/v1/chat/completions` | 相同 |

---

## 六、版本演进路线图

### 6.1 完整版本时间线

```
v0.7.0 (2025-11)  v0.8.0 (2026-01)  v0.9.0 (2026-02)  v1.0.0 (2026-03)  v1.1.0-dev
    │                   │                   │                   │                │
    ▼                   ▼                   ▼                   ▼                ▼
┌──────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌─────────┐
│ 基础架构  │    │ 去外部依赖    │    │ 完全解耦      │    │ 生产就绪      │    │ 前沿特性 │
│ etcd+NATS │    │ K8s原生发现   │    │ Event Plane  │    │ 统一API      │    │ FlexKV  │
│ 必需      │    │ TCP传输默认   │    │ ZMQ事件总线   │    │ 多模态       │    │ Velo    │
│ vLLM 0.9  │    │ Mocker       │    │ Kalman预测   │    │ Agents       │    │ 单独KV  │
│ 工具调用   │    │ Profiler     │    │ 路由提示      │    │ GlobalPlanner│    │ Indexer │
└──────────┘    └──────────────┘    └──────────────┘    └──────────────┘    └─────────┘
    │                   │                   │                   │
    ├── v0.7.0.post1    ├── v0.8.1          ├── v0.9.1          ├── v1.0.1
    └── v0.7.1          │                   │                   │
                        │                   │                   │
```

### 6.2 每个版本的核心突破

| 版本 | 发布日期 | 核心突破 | vLLM | 关键新特性 |
|------|---------|---------|------|----------|
| **v0.7.0** | 2025-11 | 首个公开版本 | 0.9.x | 基础 disagg serving, KV-aware routing |
| **v0.7.1** | 2025-12-16 | 文本功能补全 | 0.11.0 | 工具调用(DeepSeek V3/R1), NIXL 性能优化, 预处理器修复 |
| **v0.8.0** | 2026-01 | 去外部依赖 | 0.12.0 | K8s EndpointSlices替代etcd, TCP替代NATS, Mocker-Planner, 多模态, LoRA |
| **v0.8.1** | 2026-01-23 | 补丁 | 0.12.0 | CuDNN 修复, SGLang CUDA 13 修复 |
| **v0.9.0** | 2026-02 | 架构解耦 | 0.14.1 | Event Plane(ZMQ), 三平面完整, Kalman预测, Mooncake预热, 路由提示 |
| **v0.9.1** | 2026-03-06 | 补丁 | 0.14.1 | 稳定性修复 |
| **v1.0.0** | 2026-03 | 首个大版本 | 0.16.x | 多模态(图/视/音), Agents, 统一配置, K8s生产就绪, GlobalPlanner, 稳定公开API |
| **v1.0.1** | 2026-03 | 补丁 | 0.16.x | TRT-LLM CUDA 13.1 崩溃修复, Kimi K2.5 tokenizer, logprobs修复 |
| **v1.1.0-dev.1** | pre-release | 前沿预览 | 0.17.1 | 独立KV Indexer, Velo事件系统, FlexKV, 可插拔调度, 投机解码模拟 |

### 6.3 架构演进主线

```
v0.7.x: etcd (必须) + NATS (必须) + K8s Operator
         ↓ 问题：外部依赖过重，部署复杂

v0.8.x: K8s EndpointSlices (默认) + TCP (默认) + etcd/NATS (可选)
         ↓ 突破：去掉了 etcd/NATS 的强依赖

v0.9.x: Discovery Plane + Request Plane + Event Plane (ZMQ)
         ↓ 突破：三平面完全解耦，无需任何外部消息代理

v1.0.x: 统一配置 + GlobalPlanner + 稳定 API + 多模态/Agents
         ↓ 突破：首个生产就绪大版本，API 稳定

v1.1.x: FlexKV + Velo + 独立 KV Indexer + 可插拔调度
         ↓ 方向：高性能 KV 缓存管理，更灵活的架构
```

---

## 七、Breaking Changes 完整清单

### 7.1 v0.7.1 → v1.0.0 CLI 变更

| 旧参数 (v0.7.1) | 新参数 (v1.0.0) | 说明 |
|-----------------|----------------|------|
| `--is-prefill-worker` | `--disaggregation-mode prefill` | Prefill Worker 标志 |
| `--is-decode-worker` | `--disaggregation-mode decode` | Decode Worker 标志 |
| `--kv-events` | `--router-kv-events` | KV 事件开关 |
| `DYN_KV_EVENTS` | `DYN_ROUTER_USE_KV_EVENTS` | 对应环境变量 |
| `--enforce-disagg` | `--decode-fallback` | 语义反转！原为"强制分离"，现为"允许回退" |
| `--migration-limit` (Worker) | `--migration-limit` (Frontend) | 参数位置迁移 |
| `python -m planner_sla` | `python -m dynamo.planner` | Planner 启动入口统一 |
| 独立 CLI args | `--config JSON` | Planner 改用统一 JSON 配置 |
| `dynamoNamespace:` (手动) | 自动计算 | DGD YAML 中不再必须手动指定 |
| `--connector` flag | 移除 | vLLM 后端不再需要 connector 标志 |

### 7.2 v0.7.1 → v1.0.0 配置系统变更

| 维度 | v0.7.1 | v1.0.0 |
|------|--------|--------|
| **配置方式** | argparse CLI flags | 统一类型化配置系统 |
| **环境变量前缀** | `DYN_` 混用 | `DYN_` 统一规范化 |
| **YAML dynamoNamespace** | 手动写在每个 service 中 | 自动从 deployment name 计算 |

### 7.3 迁移检查清单

从 v0.7.1 迁移到 v1.0.x 时需要修改：

- [ ] Worker 启动参数: `--is-prefill-worker` → `--disaggregation-mode prefill`
- [ ] Worker 启动参数: 新增 `--kv-transfer-config '{"kv_connector":"NixlConnector","kv_role":"kv_both"}'`
- [ ] 环境变量: `DYN_KV_EVENTS` → `DYN_ROUTER_USE_KV_EVENTS`
- [ ] Planner 入口: `planner_sla` → `dynamo.planner`
- [ ] Planner 配置: 独立 args → `--config JSON`
- [ ] 如果使用 `--enforce-disagg`: 理解语义反转 → `--decode-fallback`
- [ ] 如果使用 `--migration-limit`: 改为在 Frontend 上配置
- [ ] DGD YAML: 可以移除 `dynamoNamespace` 字段
- [ ] DGD YAML: 添加 `ephemeral-storage` requests
- [ ] 构建脚本: `./container/build.sh` → `python container/render.py`
- [ ] 移除 etcd/NATS 依赖（可选，K8s 模式下已不需要）

---

## 八、技术选型与学习路线

### 8.1 版本选型决策树

```
你的目标是什么？
│
├── 学习 LLM Serving 架构原理
│   └── ✅ v0.7.1 — 骨架清晰，组件少，适合阅读源码
│
├── 自己动手实现 Router/Planner 增强
│   ├── 起点: v0.7.1 — 关键算法缺位，正好实现
│   └── 对比: v0.8.1 — 补齐后的官方实现
│
├── 部署生产集群（当前最佳实践）
│   └── ✅ v1.0.1 — 首个稳定大版本，API 稳定，功能完整
│
├── 需要多模态/Agents/GlobalPlanner
│   └── ✅ v1.0.x — 这些都是 v1.0 新增的核心特性
│
├── 需要 FlexKV/Velo/独立 KV Indexer
│   └── ⚠️ v1.1.0-dev — 预发布，不推荐生产
│
└── GPU 受限 / CUDA 版本低
    ├── CUDA 12.8 (SGLang only): v0.7.1
    ├── CUDA 12.9: v0.7.1 / v0.8.x / v0.9.x / v1.0.x
    └── CUDA 13.0 (TRT-LLM): 所有版本均需
```

### 8.2 学习路线图

#### 第一阶段：理解基础架构（v0.7.1）

```
1. 阅读 components/src/dynamo/frontend/ — 理解请求流水线
2. 阅读 components/src/dynamo/router/ — 理解 KV-Aware 路由算法
3. 用 launch/disagg_router.sh 本地跑通 4 GPU 分离服务
4. 用 deploy/disagg_router.yaml 在 K8s 上部署
5. 配置 HPA 实现基础自动扩缩容
```

**关键代码路径**:
```
HTTP Request
  → frontend/__init__.py (HTTP Handler)
  → frontend/preprocessor.py (Tokenize)
  → router/kv_router.py (选择 Worker)
  → runtime/rpc.py (发送到 Worker)
  → vllm/__init__.py (执行推理)
  → 返回 streaming tokens
```

#### 第二阶段：理解 Planner/Mocker 工作流

```
1. 阅读 components/src/dynamo/mocker/ — 理解 Mock Worker 模拟逻辑
2. 阅读 components/src/dynamo/planner/ — 理解 SLA 驱动调度
3. 用 Profiler 生成性能曲线数据
4. 部署 disagg_planner.yaml 观察 Planner 动态调度行为
```

#### 第三阶段：对比版本演进

```
1. diff v0.7.1 vs v0.8.1 的 Router 代码 — 学习裁剪/拒绝/取消三件套
2. diff v0.8.x vs v0.9.x 的通信层 — 理解 Event Plane 设计
3. 阅读 v1.0.0 的统一配置系统 — 理解大版本 API 稳定化
4. 关注 v1.1.0-dev 的 FlexKV — 了解前沿方向
```

#### 第四阶段：生产级实践

```
1. 在 K8s 上部署完整的: Frontend + Prefill + Decode + Planner
2. 配置 Prometheus + Grafana 监控
3. 实现 HPA 或集成 Planner 自动扩缩容
4. 压测并调优（使用 benchmarks/ 工具）
5. 模拟故障并验证 Request Migration
```

### 8.3 技术栈掌握清单

| 技术 | 重要度 | 涉及组件 | 学习资源 |
|------|--------|---------|---------|
| **Rust** | ⭐⭐⭐⭐⭐ | lib/ 全部核心库 | 仓库 56.1% 是 Rust |
| **Python** | ⭐⭐⭐⭐ | components/ 应用层 | Frontend/Planner/Worker |
| **K8s Operator** | ⭐⭐⭐⭐ | deploy/helm/, deploy/operator/ | CRD/DGD/Operator 开发 |
| **gRPC/TCP** | ⭐⭐⭐ | lib/runtime/ | 请求传输层 |
| **ZMQ** | ⭐⭐⭐ | Event Plane (v0.9+) | 事件发布/订阅 |
| **NIXL** | ⭐⭐⭐ | KV Cache 传输 | Prefill→Decode KV 搬运 |
| **Prometheus** | ⭐⭐⭐ | deploy/observability/ | 监控/HPA 指标 |
| **Go** | ⭐⭐ | Operator, Inference Gateway | K8s 控制面 |
| **CUDA** | ⭐⭐ | 底层 GPU 管理 | 驱动/容器兼容 |

### 8.4 关键点提炼

基于 Dynamo 项目经验，可以复盘的核心技术话题：

1. **Disaggregated Serving 架构**: Prefill/Decode 分离的工程理由与实现
2. **KV-Aware Routing**: 基于前缀树的 KV Cache 命中率路由算法
3. **SLA-Driven Autoscaling**: Profiling → Planner → 动态副本调整的闭环
4. **K8s Operator 模式**: CRD 定义 → Operator 协调 → DGD 生命周期管理
5. **零外部依赖演进**: etcd+NATS → K8s EndpointSlices + TCP → 无中间件
6. **Event-Driven Architecture**: Discovery + Request + Event 三平面解耦
7. **GPU 资源管理**: CDI 隔离、CRIU 快照恢复、GPU 池预算分配

---

## 附录 A：DGD YAML 完整示例

### A.1 v0.7.1 disagg_router.yaml（完整）

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: vllm-v1-disagg-router
spec:
  services:
    Frontend:
      dynamoNamespace: vllm-v1-disagg-router
      componentType: frontend
      replicas: 1
      extraPodSpec:
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.1
      envs:
        - name: DYN_ROUTER_MODE
          value: kv
    VllmDecodeWorker:
      dynamoNamespace: vllm-v1-disagg-router
      envFromSecret: hf-token-secret
      componentType: worker
      replicas: 2
      resources:
        limits:
          gpu: "1"
      extraPodSpec:
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.1
          workingDir: /workspace/examples/backends/vllm
          command: [python3, -m, dynamo.vllm]
          args:
            - --model
            - Qwen/Qwen3-0.6B
            - --is-decode-worker
    VllmPrefillWorker:
      dynamoNamespace: vllm-v1-disagg-router
      envFromSecret: hf-token-secret
      componentType: worker
      replicas: 2
      resources:
        limits:
          gpu: "1"
      extraPodSpec:
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.1
          workingDir: /workspace/examples/backends/vllm
          command: [python3, -m, dynamo.vllm]
          args:
            - --model
            - Qwen/Qwen3-0.6B
            - --is-prefill-worker
```

### A.2 v1.0.x disagg_router.yaml（完整）

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: vllm-v1-disagg-router
spec:
  services:
    Frontend:
      componentType: frontend
      replicas: 1
      extraPodSpec:
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:my-tag
      envs:
        - name: DYN_ROUTER_MODE
          value: kv
    VllmDecodeWorker:
      envFromSecret: hf-token-secret
      componentType: worker
      replicas: 2
      resources:
        limits:
          gpu: "1"
        requests:
          custom:
            ephemeral-storage: "2Gi"
      extraPodSpec:
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:my-tag
          workingDir: /workspace/examples/backends/vllm
          command: [python3, -m, dynamo.vllm]
          args:
            - --model
            - Qwen/Qwen3-0.6B
            - --disaggregation-mode
            - decode
    VllmPrefillWorker:
      envFromSecret: hf-token-secret
      componentType: worker
      replicas: 2
      resources:
        limits:
          gpu: "1"
        requests:
          custom:
            ephemeral-storage: "2Gi"
      extraPodSpec:
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:my-tag
          workingDir: /workspace/examples/backends/vllm
          command: [python3, -m, dynamo.vllm]
          args:
            - --model
            - Qwen/Qwen3-0.6B
            - --disaggregation-mode
            - prefill
            - --kv-transfer-config
            - '{"kv_connector":"NixlConnector","kv_role":"kv_both"}'
            - --kv-events-config
            - '{"publisher":"zmq","topic":"kv-events","endpoint":"tcp://*:20080","enable_kv_cache_events":true}'
```

---

## 附录 B：快速参考卡

### 本地启动（开发调试）

```bash
# v0.7.1 — 需要先启动 etcd + NATS
docker compose -f deploy/docker-compose.yml up -d
cd examples/backends/vllm/launch
bash disagg_router.sh    # 4 GPU: 2 Decode + 2 Prefill

# v1.0.x — 不需要 etcd/NATS
cd examples/backends/vllm/launch
bash disagg_router.sh    # 4 GPU: 2 Decode + 2 Prefill
```

### K8s 部署

```bash
# 两个版本流程相同
kubectl create secret generic hf-token-secret --from-literal=HF_TOKEN=$HF_TOKEN -n $NS
kubectl apply -f examples/backends/vllm/deploy/disagg_router.yaml -n $NS
kubectl port-forward deployment/vllm-v1-disagg-router-frontend-xxx 8000:8000
```

### 测试请求

```bash
curl localhost:8000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Hello"}],"max_tokens":30}'
```

---

# 第二部分：Planner 深度分析与模型加载架构

> 分析日期：2026年7月
> 基于 Dynamo v0.7.1 源代码 + v1.0.x main branch 源代码 + 官方设计文档

---

## 目录（第二部分）

9. [HPA vs Planner：到底该用哪个？](#九hpa-vs-planner到底该用哪个)
10. [Planner v0.7.1 vs v1.0.x 详细功能对比](#十planner-v071-vs-v10x-详细功能对比)
11. [Scaling 实现原理：从源码深度分析](#十一scaling-实现原理从源码深度分析)
12. [Planner 下一步改进方向](#十二planner-下一步改进方向)
13. [模型加载架构：为什么每个 Pod 需要自己的模型？](#十三模型加载架构为什么每个-pod-需要自己的模型)
14. [Dynamo Snapshot：解决模型加载慢的官方方案](#十四dynamo-snapshot解决模型加载慢的官方方案)

---

## 九、HPA vs Planner：到底该用哪个？

### 9.1 官方明确回答："为什么 LLM 推理需要不同的自动扩缩器"

Dynamo 官方文档（`docs/components/planner/README.md`）有一个专门章节 **"Why LLM Inference Needs a Different Autoscaler"**，直接回答了这个问题。

**核心论点：传统 HPA 的假设在 LLM 推理中全部失效。**

| HPA 的假设 | LLM 推理的现实 | 为什么失败 |
|-----------|--------------|-----------|
| 延迟取决于请求数量 | **延迟取决于请求内容** | 一个 32K token 的 prompt 和一个 10 token 的 prompt 对 GPU 的负载完全不同，但 HPA 用的是 request rate |
| 所有请求特征相似 | **Prefill 和 Decode 有完全不同的缩放特性** | Prefill 是计算密集型（compute-bound），Decode 是内存密集型（memory-bound），需要独立扩缩 |
| CPU/GPU 利用率能反映负载 | **关键指标不是标准指标** | TTFT（首个 Token 时间）和 ITL（Token 间延迟）才是 SLA 指标。HPA 无法设定"保持 P95 TTFT 在 500ms 以下" |
| 扩容成本低（秒级） | **GPU Worker 启动需要分钟级** | 加载模型到 GPU 需要 1-5 分钟，需要预测而非反应 |

### 9.2 推荐决策矩阵

```
┌───────────────────────────────────────────────────────────────────────────┐
│                         选择 HPA 还是 Planner？                            │
│                                                                           │
│  你的场景符合描述 ──→ 使用                                                  │
│  ─────────────────────────────────────────                                │
│                                                                           │
│  ✅ 刚接触 Dynamo，想快速跑起来       ──→  HPA（简单开始）                    │
│  ✅ 请求负载模式较固定（ISL/OSL 变化小）──→  HPA（足够用）                    │
│  ✅ 对 TTFT/ITL 没有严格 SLA 要求      ──→  HPA（成本低）                    │
│  ✅ 开发/测试环境                       ──→  HPA                            │
│                                                                           │
│  ⚡ 需要满足 SLA（TTFT < 500ms 等）     ──→  Planner（SLA 驱动）            │
│  ⚡ 请求长度分布变化大（2K-32K token）   ──→  Planner（内容感知）             │
│  ⚡ 需要 Prefill/Decode 独立扩缩         ──→  Planner（计算原理不同）         │
│  ⚡ 生产环境，需要预测式扩容             ──→  Planner（预测模型）             │
│  ⚡ 多模型、多集群共享 GPU 资源          ──→  GlobalPlanner                   │
│                                                                           │
│  📌 结论：HPA 是入门方案，Planner 是生产方案                                │
│  📌 两者不互斥！Planner 底层也是调整 DGD 的 replica 数                       │
└───────────────────────────────────────────────────────────────────────────┘
```

### 9.3 HPA 与 Planner 的本质区别

```
HPA 工作流程：
  Prometheus metrics (CPU/GPU/QPS) → HPA Controller → 直接调整 Pod replicas
  问题：指标是代理指标，与 SLA 无直接关系

Planner 工作流程：
  Prometheus metrics (TTFT/ITL/ISL/OSL/QPS) 
     → 修正因子计算 (actual vs expected)
     → 负载预测 (ARIMA/Kalman/Prophet)
     → 性能插值 (从 Profiling 数据查表)
     → 分别计算 Prefill/Decode 所需 replica
     → Connector 层调整 DGD replicas
  优势：直接用 SLA 指标驱动，有预测能力
```

---

## 十、Planner v0.7.1 vs v1.0.x 详细功能对比

### 10.1 源代码结构对比

**v0.7.1 — 简单扁平结构：**

```
components/src/dynamo/planner/
├── utils/                        # 工具函数
├── planner_sla.py               # 入口：30s 延迟 → start_sla_planner()
├── planner_connector.py         # ABC 基类接口
├── kubernetes_connector.py      # KubernetesConnector：+1/-1/set replicas
├── virtual_connector.py         # VirtualConnector（非 K8s 环境）
├── defaults.py                  # SubComponentType, 默认值
├── kube.py                      # 底层 K8s API 封装
└── README.md                    # 指向 docs/planner/planner_intro.rst
```

**v1.0.x — 完全重构为子包架构：**

```
components/src/dynamo/planner/
├── config/                      # ★ 配置管理子包
│   └── planner_config.py        #   PlannerConfig 全字段定义
├── connectors/                  # ★ 连接器子包
│   ├── kubernetes_connector.py  #   PATCH DGD 资源
│   ├── virtual_connector.py     #   分布式运行时
│   └── global_planner_connector.py  #   ★ 新增：上报给 GlobalPlanner
├── core/                        # ★ 核心算法子包
│   ├── planner_core.py          #   主循环 + 调度框架
│   ├── disagg_planner.py        #   Disagg 模式协调器
│   ├── agg_planner.py           #   Agg 模式协调器
│   ├── prefill_planner.py       #   Prefill replica 计算
│   ├── decode_planner.py        #   Decode replica 计算
│   ├── load_based_regression.py #   ★ 新增：基于负载的回归模型
│   ├── fpm_regression.py        #   ★ 新增：ForwardPassMetrics 回归
│   ├── perf_interpolation.py    #   性能插值（从 NPZ 数据查表）
│   └── load_predictor.py        #   负载预测器（ARIMA/Kalman/Prophet/Constant）
├── monitoring/                  # ★ 新增：诊断监控子包
│   ├── prometheus.py            #   Prometheus 指标导出 (dynamo_planner_*)
│   └── diagnostics.py           #   HTML 诊断报告生成器
├── offline/                     # ★ 新增：离线分析工具
├── tests/                       # 测试套件（单元测试 + 手动测试）
├── __main__.py                  # 统一入口：python -m dynamo.planner
├── __init__.py
├── errors.py                    # 自定义异常层次结构
└── README.md                    # 两种扩缩模式文档 + 功能矩阵
```

### 10.2 功能矩阵对比

| 功能维度 | v0.7.1 | v1.0.x | 变化说明 |
|---------|--------|--------|---------|
| **扩缩模式** | 仅吞吐量模式（Throughput-Based） | 吞吐量 + 负载模式（Load-Based） | 新增实时负载感知扩缩 |
| **入口方式** | `planner_sla.py` 脚本入口 | `python -m dynamo.planner` 模块入口 | 标准化启动方式 |
| **启动延迟** | 硬编码 30s (`INIT_PLANNER_START_DELAY`) | 仍有启动延迟（待改进） | 应改为就绪探测 |
| **数据来源** | 仅 Prometheus（TTFT/ITL/QPS） | Prometheus + ForwardPassMetrics (FPM) | FPM 提供引擎级粒度 |
| **负载预测** | 无（仅基于当前指标） | ARIMA / Kalman / Prophet / Constant | 支持多种预测模型 |
| **FPM 回归** | 无 | 3 个专用回归模型 | PrefillRegression / DecodeRegression / AggRegression |
| **Connector** | `KubernetesConnector` + `VirtualConnector` | + `GlobalPlannerConnector` | 新增上报给 GlobalPlanner |
| **诊断监控** | 无 | Prometheus 指标 + HTML 报告 | `dynamo_planner_*` 指标族 |
| **全局协调** | 不支持（单 DGD 范围） | GlobalPlanner 跨 DGD 协调 | `--max-total-gpus` GPU 预算 |
| **支持后端** | vLLM | vLLM + SGLang + TRTLLM | 全后端支持 |
| **部署模式** | 仅 Disagg | Disagg + Agg | 聚合和分离模式均支持 |
| **配置管理** | 分散在多个文件 | PlannerConfig 统一配置类 | 全字段类型安全 |

### 10.3 PlannerConfig 完整字段参考（v1.0.x）

```python
class PlannerConfig:
    # 扩缩模式选择
    enable_throughput_scaling: bool     # 启用吞吐量模式（需要 Profiling 数据）
    enable_load_scaling: bool           # 启用负载模式（需要 FPM 数据）

    # 吞吐量模式参数
    throughput_adjustment_interval: int  # 调整间隔，默认 180s
    pre_deployment_sweeping_mode: str    # rapid / thorough / none

    # 负载模式参数
    load_adjustment_interval: int        # 调整间隔，默认 5s
    load_predictor: str                  # arima / kalman / prophet / constant

    # Kalman 滤波器参数（默认值已调优）
    kalman_process_noise: float          # 过程噪声
    kalman_measurement_noise: float      # 测量噪声
    kalman_initial_estimate_error: float # 初始估计误差

    # SLA 目标
    target_ttft_ms: float               # 目标 TTFT（毫秒）
    target_itl_ms: float                # 目标 ITL（毫秒）

    # 诊断
    diagnostics_report_interval: int     # 诊断报告生成间隔
    diagnostics_report_format: str       # html / json
```

### 10.4 v0.7.1 KubernetesConnector 源码分析

v0.7.1 的 `kubernetes_connector.py` 是理解 Planner 如何控制 K8s 的关键：

```python
class KubernetesConnector(PlannerConnector):
    """通过 PATCH DGD 资源来调整 replica 数量"""

    def add_component(self, component_type: str):
        """单个组件 +1 replica"""
        current = self._get_current_replicas(component_type)
        self._patch_dgd_replicas(component_type, current + 1)

    def remove_component(self, component_type: str):
        """单个组件 -1 replica"""
        current = self._get_current_replicas(component_type)
        if current > 1:
            self._patch_dgd_replicas(component_type, current - 1)

    def set_component_replicas(self, component_replicas: dict):
        """批量设置多个组件的 replica 数量"""
        # 1. 检查部署就绪状态
        # 2. 构建 PATCH 请求
        # 3. PATCH DGD 的 spec.services.{Component}.replicas
        for component, replicas in component_replicas.items():
            self._patch_dgd_replicas(component, replicas)

    def validate_deployment(self):
        """验证 Prefill/Decode 服务存在于 DGD 中"""
        dgd = self._get_dgd()
        services = dgd['spec']['services']
        assert 'VllmPrefillWorker' in services or 'VllmDecodeWorker' in services

    def get_model_name(self):
        """从 DGD 获取模型名称并验证一致性"""
        dgd = self._get_dgd()
        # 读取 DYN_PARENT_DGD_K8S_NAME 环境变量确定目标 DGD
```

**关键实现细节：**
- 通过环境变量 `DYN_PARENT_DGD_K8S_NAME` 找到目标 DGD 资源
- 使用 K8s API 的 PATCH 操作修改 DGD 的 `spec.services.{Component}.replicas`
- DGD Operator 监听变更后自动调整实际 Pod 数量

---

## 十一、Scaling 实现原理：从源码深度分析

### 11.1 五步扩缩算法（官方设计文档）

Planner 的核心算法分为 5 个步骤，每个 `adjustment_interval` 执行一次：

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Planner 五步扩缩算法                               │
│                                                                     │
│  Step 1: Metric Collection (指标采集)                                │
│  ─────────────────────────────────                                  │
│  每 adjustment_interval 秒查询 Prometheus：                          │
│  • avg_ttft: 平均首 Token 时间                                       │
│  • avg_itl: 平均 Token 间延迟                                        │
│  • num_requests: 请求数量                                            │
│  • avg_isl / avg_osl: 平均输入/输出序列长度                            │
│         │                                                           │
│         ▼                                                           │
│  Step 2: Correction Factor (修正因子)                                │
│  ─────────────────────────────────                                  │
│  prefill_correction = actual_ttft / expected_ttft                   │
│  decode_correction  = actual_itl  / expected_itl                    │
│                                                                     │
│  补偿因素：排队延迟、Prefix Cache 命中、Chunked Prefill               │
│  expected 值来自 Profiling 数据的插值                                  │
│         │                                                           │
│         ▼                                                           │
│  Step 3: Load Prediction (负载预测)                                  │
│  ─────────────────────────────────                                  │
│  使用选定的预测器预测下一周期：                                         │
│  • next_num_req  (下一周期请求数)                                     │
│  • next_isl      (下一周期平均 ISL)                                   │
│  • next_osl      (下一周期平均 OSL)                                   │
│                                                                     │
│  可选预测器：                                                         │
│  ┌──────────┬─────────────────────────────────────┐                 │
│  │ Constant │ 假设下一周期与当前相同（最简单）          │                 │
│  │ ARIMA    │ 自回归滑动平均（时间序列经典方法）       │                 │
│  │ Kalman   │ 卡尔曼滤波器（默认，低延迟在线预测）     │                 │
│  │ Prophet  │ Facebook Prophet（季节性趋势分析）       │                 │
│  └──────────┴─────────────────────────────────────┘                 │
│         │                                                           │
│         ▼                                                           │
│  Step 4: Replica Calculation (副本数计算)                             │
│  ─────────────────────────────────────                               │
│  ┌─────────────────────────────────────────────────────────┐        │
│  │ Prefill:                                                 │        │
│  │ prefill_replicas = ⌈ predicted_load                      │        │
│  │                      / interpolated_throughput            │        │
│  │                      / gpus_per_engine ⌉                 │        │
│  │                                                           │        │
│  │ 其中 predicted_load = correction * next_num_req * f(isl) │        │
│  │ interpolated_throughput 从 NPZ Profiling 数据查表得到     │        │
│  └─────────────────────────────────────────────────────────┘        │
│  ┌─────────────────────────────────────────────────────────┐        │
│  │ Decode:                                                  │        │
│  │ decode_replicas = ⌈ next_num_req * next_osl              │        │
│  │                     / interval                           │        │
│  │                     / throughput_per_gpu                  │        │
│  │                     / gpus_per_engine ⌉                  │        │
│  └─────────────────────────────────────────────────────────┘        │
│         │                                                           │
│         ▼                                                           │
│  Step 5: Scaling Execution (扩缩执行)                                │
│  ─────────────────────────────────                                  │
│  connector.set_component_replicas({                                 │
│      "VllmPrefillWorker": prefill_replicas,                        │
│      "VllmDecodeWorker":  decode_replicas                          │
│  })                                                                 │
│  → KubernetesConnector: PATCH DGD 资源的 replicas 字段              │
│  → Operator 监听变更 → 调整实际 Pod 数量                              │
└─────────────────────────────────────────────────────────────────────┘
```

### 11.2 基于负载的扩缩（Load-Based Scaling，v1.0.x 新增）

v1.0.x 新增了基于 ForwardPassMetrics (FPM) 的实时负载扩缩，这是与吞吐量模式完全不同的方法：

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Load-Based Scaling 架构                           │
│                                                                     │
│  vLLM Engine ──→ ForwardPassMetrics (FPM)                          │
│  (每次 forward pass 发出指标)                                        │
│       │                                                             │
│       │ ZMQ                                                         │
│       ▼                                                             │
│  FpmEventRelay ──→ Event Plane                                     │
│       │                                                             │
│       ▼                                                             │
│  Planner (Load-Based 模式)                                          │
│       │                                                             │
│       ├── PrefillRegressionModel (1D回归)                           │
│       │   input: sum_prefill_tokens → output: wall_time             │
│       │   "多少 prefill tokens 需要多少时间"                          │
│       │                                                             │
│       ├── DecodeRegressionModel (1D回归)                            │
│       │   input: sum_decode_kv_tokens → output: wall_time           │
│       │   "多少 decode KV tokens 需要多少时间"                        │
│       │                                                             │
│       └── AggRegressionModel (2D回归)                               │
│           input: (prefill_tokens, decode_kv_tokens) → wall_time     │
│                                                                     │
│  扩缩判断逻辑：                                                      │
│  ─────────────                                                      │
│  • 扩容条件：所有引擎的 estimated TTFT/ITL > SLA 目标                 │
│  • 缩容条件：所有引擎的 estimated TTFT/ITL < SLA × 灵敏度            │
│  • 每个 interval 最多扩缩 ±1（防止振荡）                              │
│  • 有 pending-desired 守卫：扩缩进行中不发起新的扩缩                   │
│                                                                     │
│  FPM 关键字段：                                                      │
│  • wall_time: 单次 forward pass 耗时                                 │
│  • scheduled_requests.sum_prefill_tokens: 本次调度的总 prefill tokens │
│  • scheduled_requests.sum_decode_kv_tokens: 本次调度的 KV tokens      │
│  • queued_requests: 排队请求数                                       │
└─────────────────────────────────────────────────────────────────────┘
```

**两种模式对比：**

| 维度 | 吞吐量模式（Throughput-Based） | 负载模式（Load-Based） |
|------|------------------------------|----------------------|
| **数据依赖** | 需要预先 Profiling（NPZ 文件） | 不需要 Profiling |
| **调整间隔** | 默认 180s（3 分钟） | 默认 5s |
| **指标来源** | Prometheus（聚合指标） | FPM（引擎级实时指标） |
| **计算方法** | 查表插值 + 预测 | 回归模型拟合 |
| **扩缩幅度** | 直接计算目标副本数 | 每次 ±1 |
| **适用场景** | 有离线 Profiling 数据、长期规划 | 无 Profiling 数据、快速响应 |
| **可共存** | ✅ 可与负载模式同时启用 | ✅ 可与吞吐量模式同时启用 |

### 11.3 性能插值机制（Throughput 模式核心）

吞吐量模式依赖离线 Profiling 产生的 NPZ 文件进行性能查表：

```
Profiling 阶段（预先运行）：
  Mocker (模拟不同 ISL/OSL 的负载)
    → vLLM Worker (执行推理)
    → 采集 (throughput, ISL, OSL, context_length) → (TTFT, ITL) 的映射关系
    → 保存为 NPZ 文件

运行时插值：
  给定当前的 (avg_isl, avg_osl, num_requests)
    → 在 NPZ 数据中查找最近的点
    → 插值得到 expected_ttft 和 expected_itl
    → 插值得到 interpolated_throughput

  已知局限：使用平均值插值
    → 如果请求长度呈双峰分布（大量短请求 + 少量长请求），
      平均值不能准确反映实际负载
```

### 11.4 Connector 分层设计

```
┌──────────────────────────────────────────────────────────────────┐
│                    Connector 分层架构                              │
│                                                                  │
│  Planner (算法层)                                                 │
│      │                                                           │
│      │ set_component_replicas({                                  │
│      │     "VllmPrefillWorker": 3,                              │
│      │     "VllmDecodeWorker": 5                                │
│      │ })                                                        │
│      ▼                                                           │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │ PlannerConnector (ABC 抽象接口)                            │    │
│  │  ├── add_component(type)     # +1 replica                 │    │
│  │  ├── remove_component(type)  # -1 replica                 │    │
│  │  ├── set_component_replicas(dict)  # 批量设置              │    │
│  │  ├── validate_deployment()   # 验证部署状态                │    │
│  │  └── get_model_name()        # 获取模型名                 │    │
│  └──────────────┬──────────────────────┬──────────────┬──────┘    │
│                 │                      │              │           │
│      ┌──────────▼──────────┐ ┌────────▼────────┐ ┌──▼────────┐  │
│      │KubernetesConnector  │ │VirtualConnector  │ │GlobalPlan-│  │
│      │                     │ │                  │ │nerConnect-│  │
│      │ PATCH DGD resource  │ │ 写入分布式运行时  │ │or (v1.0+)│  │
│      │ via K8s API         │ │ （非 K8s 环境）   │ │上报给     │  │
│      │                     │ │                  │ │GlobalPlan-│  │
│      │ 读取 DYN_PARENT_   │ │                  │ │ner        │  │
│      │ DGD_K8S_NAME       │ │                  │ │           │  │
│      └─────────────────────┘ └──────────────────┘ └───────────┘  │
│                                                                  │
│  K8s 中的执行路径：                                                │
│  KubernetesConnector                                             │
│    → PATCH DGD spec.services.{Component}.replicas                │
│    → DGD Operator 监听变更                                        │
│    → Operator 调整 Deployment/StatefulSet replicas               │
│    → K8s 创建/删除 Pod                                            │
└──────────────────────────────────────────────────────────────────┘
```

### 11.5 GlobalPlanner 架构（v1.0.0+ 新增）

GlobalPlanner 解决的核心问题：**多个 DGD 共享 GPU 集群时，如何全局协调扩缩？**

```
┌──────────────────────────────────────────────────────────────────┐
│                    GlobalPlanner 架构                              │
│                                                                  │
│  两种使用模式：                                                    │
│                                                                  │
│  模式 A：多模型端点（Multi-Model Endpoints）                       │
│  ─────────────────────────────────────────                       │
│  Client ──→ GlobalRouter ──→ DGD-A (Llama-70B)                  │
│                           ──→ DGD-B (Qwen-72B)                  │
│                           ──→ DGD-C (Mixtral-8x7B)              │
│                                                                  │
│  GlobalPlanner: 控制 A/B/C 的总 GPU 不超过 --max-total-gpus N     │
│                                                                  │
│  模式 B：单端点多池（Single-Endpoint Multi-Pool）                  │
│  ─────────────────────────────────────────                       │
│  Client ──→ Frontend ──→ Pool-1 (Node-Group-1)                  │
│                       ──→ Pool-2 (Node-Group-2)                  │
│                       ──→ Pool-3 (Node-Group-3)                  │
│                                                                  │
│  GlobalPlanner: 在不同节点组之间分配 replica                       │
│                                                                  │
│  Scale Request 协议：                                              │
│  ┌──────────────────────────────────────────┐                    │
│  │ ScaleRequest:                             │                    │
│  │   component: "VllmDecodeWorker"          │                    │
│  │   current_replicas: 2                    │                    │
│  │   desired_replicas: 4                    │                    │
│  │   dgd_name: "llama-70b"                  │                    │
│  │   namespace: "team-a"                    │                    │
│  │                                          │                    │
│  │ ScaleResponse:                           │                    │
│  │   approved_replicas: 3                   │                    │
│  │   reason: "GPU budget exceeded"          │                    │
│  └──────────────────────────────────────────┘                    │
│                                                                  │
│  部署参数：                                                        │
│  python -m dynamo.global_planner                                 │
│    --managed-namespaces team-a,team-b                            │
│    --max-total-gpus 64                                           │
│    --no-operation  # dry-run 模式                                 │
└──────────────────────────────────────────────────────────────────┘
```

---

## 十二、Planner 下一步改进方向

### 12.1 官方已明确的改进方向

根据官方设计文档（`docs/design-docs/planner-design.md`）的 **Future Work** 章节：

| 改进方向 | 当前问题 | 预期改进 |
|---------|---------|---------|
| **多 DGD 协调** | 单 Planner 只管一个 DGD，共享集群时可能冲突 | GlobalPlanner 已部分实现，还需深化 |
| **分布感知插值** | 当前用 ISL/OSL 的平均值做插值，双峰分布下不准确 | 使用分位数或完整分布信息 |
| **自适应调整间隔** | 固定 interval 不感知实际扩缩耗时，可能导致堆积 | 根据观测到的扩缩延迟动态调整 |

### 12.2 从源码和局限性分析推导的潜在改进

| 改进方向 | 当前局限 | 技术实现路径 |
|---------|---------|-------------|
| **消除 30s 硬编码延迟** | `INIT_PLANNER_START_DELAY = 30` 在 v0.7.1 硬编码 | 改为就绪探测（readiness probe）或组件依赖检查 |
| **更智能的 ±1 策略** | Load-Based 模式每次只 ±1，大流量波动下响应慢 | 引入比例控制或自适应步长 |
| **In-flight 请求处理** | 缩容时正在处理的请求可能丢失 | 需要 graceful drain 机制（已在 Fault Tolerance 路线图中） |
| **多后端统一 FPM** | 当前 FPM 主要来自 vLLM，SGLang/TRTLLM 支持程度不同 | 统一 FPM 接口标准 |
| **离线分析增强** | `offline/` 目录已存在但功能有限 | 提供历史数据回放、调参推荐 |
| **Profiling 自动化** | 吞吐量模式需要手动运行 Profiler 生成 NPZ | DGDR 已部分解决（自动 Profiling） |

### 12.3 从架构设计文档推导的远期方向

```
近期（v1.1-v1.2）：
  ├── 完善 GlobalPlanner 的 GPU 预算管理
  ├── 增加更多预测器选项
  └── 改进诊断报告（更丰富的 Prometheus 指标）

中期（v1.3+）：
  ├── 分布感知的性能插值
  ├── 自适应调整间隔
  ├── 跨 DGD 的请求迁移（scale-down 时保活请求）
  └── 多层 Planner 架构（Local → Global → Cluster）

远期：
  ├── AI 驱动的扩缩决策（ML 模型替代规则引擎）
  ├── 成本感知扩缩（融合 GPU 价格信息）
  └── 预热感知扩缩（结合 Snapshot 机制减少扩容延迟）
```

---

## 十三、模型加载架构

### 13.1 模型文件共享 vs GPU 内存共享


```
可以共享（Dynamo 已支持）：
  ✅ 模型文件存储：PVC + ReadWriteMany
     → 所有 Pod mount 同一个 PVC
     → 避免每个 Pod 重新下载模型到磁盘
     → 节省网络带宽和存储空间

  ✅ Model Express（P2P 模型分发）
     → 模型下载一次，通过网络分发到所有节点
     → 集成 vLLM 的 weight loading pipeline
     → mx-source / mx-target 加载格式

不能共享的：
  ❌ GPU VRAM 中的模型权重
     → 每个 CUDA Context 必须有自己的副本
     → 这是 GPU 硬件/驱动的基本约束

  ❌ KV Cache 内存
     → 每个 Engine 的 PagedAttention 管理器独立
     → 但 KV Cache 数据可以通过 NIXL 高速传输

  ❌ CUDA Graph / 计算图
     → 编译后绑定到特定 CUDA Context
```

### 13.2 官方模型缓存方案

Dynamo 提供了两种加速模型加载的方案：

**方案 1：PVC + Download Job（推荐的基础方案）**

```yaml
# Step 1: 创建共享 PVC
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: model-cache
spec:
  accessModes:
    - ReadWriteMany    # 多 Pod 同时读取
  resources:
    requests:
      storage: 100Gi

# Step 2: 一次性下载模型到 PVC
apiVersion: batch/v1
kind: Job
metadata:
  name: model-download
spec:
  template:
    spec:
      containers:
        - name: downloader
          command: ["huggingface-cli", "download", "Qwen/Qwen3-0.6B"]
          volumeMounts:
            - name: model-cache
              mountPath: /cache/huggingface

# Step 3: 在 DGD 中挂载
spec:
  pvcs:
    - create: false
      name: model-cache
  services:
    VllmDecodeWorker:
      volumeMounts:
        - name: model-cache
          mountPoint: /home/dynamo/.cache/huggingface
```

**方案 2：Model Express（P2P 分发，适合大集群）**

```
Model Express Server (集群内一个实例)
    │
    ├── 从 HuggingFace 下载模型一次
    ├── 缓存在内存/磁盘中
    │
    └── Worker Pod 启动时
        → 设置 VLLM_LOAD_FORMAT=mx-target
        → Worker 从 Model Express Server 流式加载权重
        → 比从 PVC 读取更快（网络 P2P 优化）

适用场景：
  • 大集群、多节点
  • 频繁更新模型
  • 没有 ReadWriteMany 存储
```

> **关键理解：PVC 和 Model Express 解决的是"模型从哪里读取"的问题（避免重复下载），但每个 Pod 仍然需要将模型权重加载到自己的 GPU VRAM 中。真正解决"GPU 加载慢"问题的是 Snapshot。**

---

## 十四、Dynamo Snapshot：解决模型加载慢的官方方案

### 14.1 问题定义

| 启动方式 | 耗时 | 过程 |
|---------|------|------|
| **冷启动** (Cold Start) | ~1 分钟+ | 下载模型 → 加载到 GPU → 初始化引擎 → 编译 CUDA Graph |
| **热启动** (Warm Start / Snapshot Restore) | ~10 秒 | 从 Checkpoint 恢复已初始化的完整进程状态 |

Snapshot 将冷启动变为热启动，**速度提升约 6 倍**。

### 14.2 Dynamo Snapshot 架构

```
┌──────────────────────────────────────────────────────────────────┐
│                    Dynamo Snapshot 架构                            │
│                                                                  │
│  核心理念：CRIU (Checkpoint/Restore in Userspace)                 │
│  + NVIDIA cuda-checkpoint 工具                                    │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  Checkpoint 流程（一次性操作）：                               │  │
│  │                                                            │  │
│  │  1. 启动 Worker Pod（冷启动，加载模型，初始化引擎）           │  │
│  │  2. Worker 就绪后，DaemonSet agent 执行：                   │  │
│  │     ├── cuda-checkpoint: 暂停 GPU 并保存 GPU 状态           │  │
│  │     ├── CRIU: 冻结进程并 dump 完整内存状态                   │  │
│  │     └── 保存到 Checkpoint PVC (ReadWriteMany 存储)          │  │
│  │  3. Checkpoint 内容：                                       │  │
│  │     ├── CPU 内存（完整虚拟内存映像）                         │  │
│  │     ├── GPU VRAM（模型权重 + KV Cache 元数据）               │  │
│  │     ├── CUDA Context 状态                                   │  │
│  │     ├── 文件描述符、网络 socket 状态                         │  │
│  │     └── 进程树状态                                          │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  Restore 流程（每次新 Pod 启动时）：                          │  │
│  │                                                            │  │
│  │  1. 新 Pod 使用 Placeholder Image 启动                      │  │
│  │     (包含 CRIU + cuda-checkpoint + nsrestore 工具)          │  │
│  │  2. DaemonSet agent 通过 nsenter 进入 Pod 命名空间          │  │
│  │  3. CRIU restore: 从 Checkpoint PVC 恢复完整进程状态        │  │
│  │  4. cuda-checkpoint --restore: 恢复 GPU 状态                │  │
│  │  5. 进程从 checkpoint 点继续执行                             │  │
│  │     → 模型已在 GPU VRAM 中 ✅                               │  │
│  │     → 引擎已初始化 ✅                                       │  │
│  │     → CUDA Graph 已编译 ✅                                  │  │
│  │     → 只需重新注册到 Service Discovery                      │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  K8s 部署架构：                                                   │
│                                                                  │
│  DynamoCheckpoint CR                                             │
│       │ (声明 checkpoint 身份: model + backend + TP + dtype)      │
│       ▼                                                          │
│  Dynamo Operator                                                 │
│       │ (创建 Checkpoint Job，监控完成状态)                        │
│       ▼                                                          │
│  snapshot-agent DaemonSet (特权模式)                               │
│       │ (每个 GPU 节点一个，执行 CRIU + cuda-checkpoint)           │
│       ▼                                                          │
│  Checkpoint PVC (ReadWriteMany)                                  │
│       │ (存储所有 checkpoint 数据)                                 │
│       ▼                                                          │
│  新 Worker Pod (使用 Placeholder Image)                           │
│       └──→ Restore 完成 → 注册到集群 → 开始服务                   │
└──────────────────────────────────────────────────────────────────┘
```

### 14.3 DynamoCheckpoint CRD

```yaml
# 创建 Checkpoint（一次冷启动 + 存储状态）
apiVersion: nvidia.com/v1alpha1
kind: DynamoCheckpoint
metadata:
  name: qwen3-06b-bf16
spec:
  identity:
    model: Qwen/Qwen3-0.6B         # 模型名
    backendFramework: vllm           # 后端框架
    tensorParallelSize: 1            # 张量并行度
    dtype: bfloat16                  # 数据类型
    maxModelLen: 2048                # 最大序列长度
  job:
    activeDeadlineSeconds: 3600      # 超时时间
    podTemplateSpec:
      spec:
        containers:
          - name: worker
            image: registry/dynamo/vllm-placeholder:1.0.0
            # ... 与正常 Worker 相同的配置
```

**Checkpoint Identity Hash 机制：**
- 用 `model + backendFramework + TP + dtype + maxModelLen` 等字段计算 SHA256 Hash（16字符）
- 不同的模型/配置生成不同的 Hash
- 相同的 Hash 意味着可以复用 Checkpoint

### 14.4 两种使用模式

**模式 1：checkpointRef（显式引用）**

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: vllm-fast-start
spec:
  services:
    VllmDecodeWorker:
      replicas: 3
      checkpoint:
        enabled: true
        checkpointRef: qwen3-06b-bf16    # 引用预创建的 DynamoCheckpoint
      extraPodSpec:
        mainContainer:
          image: registry/dynamo/vllm-placeholder:1.0.0   # 必须用 Placeholder Image
```

**模式 2：Auto（自动管理，推荐）**

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: vllm-auto-start
spec:
  services:
    VllmDecodeWorker:
      replicas: 3
      checkpoint:
        enabled: true
        mode: Auto
        identity:
          model: Qwen/Qwen3-0.6B
          backendFramework: vllm
          tensorParallelSize: 1
          dtype: bfloat16
          maxModelLen: 2048
```

Auto 模式的行为：
1. 计算 Identity Hash
2. 查找是否已有匹配的 DynamoCheckpoint
3. 有 → 直接 Restore（热启动 ~10s）
4. 无 → 第一个 Worker 冷启动，后台创建 Checkpoint，后续 Worker 从 Checkpoint 恢复

### 14.5 Snapshot 对 Planner 扩缩的意义

```
未使用 Snapshot 的扩缩时间线：
  T+0s:   Planner 决定扩容 +1 Decode Worker
  T+5s:   K8s 创建 Pod、拉取镜像
  T+30s:  下载模型文件到本地（如果有 PVC 则跳过）
  T+60s:  加载模型到 GPU VRAM
  T+90s:  编译 CUDA Graph
  T+120s: 注册到 Service Discovery
  T+120s: 开始处理请求
  → 总延迟：~2 分钟

使用 Snapshot 的扩缩时间线：
  T+0s:   Planner 决定扩容 +1 Decode Worker
  T+5s:   K8s 创建 Pod（Placeholder Image）
  T+8s:   snapshot-agent 开始 Restore
  T+15s:  CRIU + cuda-checkpoint 恢复完成
  T+18s:  注册到 Service Discovery
  T+18s:  开始处理请求
  → 总延迟：~18 秒

  速度提升：120s → 18s ≈ 6.7x
  
  意义：
  • Planner 的 adjustment_interval 可以缩短
    （因为扩容成本大幅降低）
  • Load-Based 模式的 ±1 策略更有效
    （因为 +1 的延迟从 2 分钟降到 18 秒）
  • 预测的重要性降低
    （反应式扩缩也能及时响应）
```

### 14.6 完整解决方案总结

```
                  解决"模型加载慢"的完整方案栈
┌──────────────────────────────────────────────────────────────┐
│                                                              │
│  层面 1: 避免重复下载（磁盘层）                                │
│  ──────────────────────────                                  │
│  ✅ PVC + Download Job         最基础，所有 Pod 共享模型文件   │
│  ✅ Model Express (P2P)        大集群优选，无需 RWX 存储      │
│  ✅ Compilation Cache PVC      缓存 CUDA Graph 编译结果       │
│                                                              │
│  层面 2: 避免 GPU 冷加载（GPU 层）                             │
│  ────────────────────────────                                │
│  ⚡ Dynamo Snapshot (CRIU)     将整个 GPU 进程状态检查点化     │
│     → 冷启动 ~60-120s → 热启动 ~10-18s                       │
│     → 需要特权 DaemonSet + RWX 存储                          │
│     → 目前仅支持 vLLM / SGLang                               │
│                                                              │
│  层面 3: 运行时优化（请求层）                                  │
│  ──────────────────────                                      │
│  🔄 Runtime xPyD Reconfig     不重启即可动态调整 Worker       │
│  🔄 Graceful Drain            缩容时优雅排空请求              │
│  🔄 KV Cache Transfer (NIXL)  引擎间高速传输 KV Cache         │
│                                                              │
│  推荐组合：                                                    │
│  ─────────                                                   │
│  开发环境：PVC + Download Job（简单有效）                      │
│  生产环境：PVC + Snapshot（最优启动速度）                      │
│  大规模集群：Model Express + Snapshot + GlobalPlanner          │
└──────────────────────────────────────────────────────────────┘
```

### 14.7 当前局限性

| 局限 | 详情 |
|------|------|
| **仅支持 LLM Worker** | 多模态、Embedding、Diffusion 等 Worker 暂不支持 |
| **Multi-GPU 仍是 Preview** | 张量并行配置在内部测试中，尚未广泛生产验证 |
| **网络状态敏感** | Restore 对活跃 TCP socket 状态敏感，Loopback bootstrap socket 最可靠 |
| **需要特权 DaemonSet** | `snapshot-agent` 必须以特权模式运行执行 CRIU |
| **仅 x86_64** | 当前仅支持 amd64 架构 |
| **NVIDIA Driver 要求** | 需要 580.xx+，multi-GPU 需要 590.xx+ |

---

## 附录 C：关键源代码文件索引

| 文件 | 版本 | 功能 |
|------|------|------|
| `components/src/dynamo/planner/planner_sla.py` | v0.7.1 | Planner 入口点 |
| `components/src/dynamo/planner/kubernetes_connector.py` | v0.7.1 | K8s Connector 实现 |
| `components/src/dynamo/planner/core/planner_core.py` | v1.0.x | 主循环 + 调度框架 |
| `components/src/dynamo/planner/core/disagg_planner.py` | v1.0.x | Disagg 模式协调器 |
| `components/src/dynamo/planner/core/prefill_planner.py` | v1.0.x | Prefill replica 计算 |
| `components/src/dynamo/planner/core/decode_planner.py` | v1.0.x | Decode replica 计算 |
| `components/src/dynamo/planner/core/load_based_regression.py` | v1.0.x | FPM 回归模型 |
| `components/src/dynamo/planner/core/perf_interpolation.py` | v1.0.x | NPZ 性能插值 |
| `components/src/dynamo/planner/core/load_predictor.py` | v1.0.x | ARIMA/Kalman/Prophet |
| `components/src/dynamo/planner/monitoring/prometheus.py` | v1.0.x | 诊断指标导出 |
| `components/src/dynamo/global_planner/scale_handler.py` | v1.0.x | GlobalPlanner 扩缩处理 |
| `deploy/snapshot/` | v1.0.x | Snapshot 整体实现（Go） |
| `deploy/snapshot/cmd/snapshotctl/` | v1.0.x | 底层 Checkpoint/Restore CLI |
| `deploy/snapshot/internal/criu/` | v1.0.x | CRIU 集成实现 |
| `deploy/snapshot/internal/cuda/` | v1.0.x | CUDA Checkpoint 集成 |
| `docs/design-docs/planner-design.md` | v1.0.x | Planner 算法设计文档 |
| `docs/components/planner/README.md` | v1.0.x | "Why LLM Needs Different Autoscaler" |
| `docs/components/planner/planner-guide.md` | v1.0.x | PlannerConfig 完整参考 |
| `docs/kubernetes/snapshot.md` | v1.0.x | Snapshot 用户指南 |
| `docs/kubernetes/model-caching.md` | v1.0.x | 模型缓存方案 |
| `docs/design-docs/disagg-serving.md` | v1.0.x | 分离式推理设计 |
| `docs/design-docs/architecture.md` | v1.0.x | 整体架构设计 |
