# Dynamo 版本对比分析：v0.7.1 / v0.8.1 / v0.9.1

> 分析日期：2026年3月13日
> 项目地址：https://github.com/ai-dynamo/dynamo

---

## 一、版本总览

| 属性 | v0.7.1 | v0.8.1 | v0.9.1 |
|---|---|---|---|
| 发布日期 | 2025-12-16 | 2026-01-23 | 2026-03-06 |
| SGLang | 0.5.4.post3 | 0.5.6.post2 | 0.5.8 |
| TensorRT-LLM | 1.2.0rc3 | 1.2.0rc6.post1 | 1.3.0rc3 |
| vLLM | 0.11.0 | 0.12.0 | 0.14.1 |
| NIXL | 0.8.0 | 0.8.0 | 0.9.0 |

**三个版本定位：**
- **v0.7.1**："从传统依赖向云原生过渡"，很多能力刚引入，外部依赖（etcd/NATS）还重。**适合作为深入学习 Router/Scale 原理、动手实现的起点 Base**。
- **v0.8.1**："去外部依赖 + 生产可用增强"，K8s 原生发现和 TCP 传输成为默认，补齐了路由裁剪/拒绝/取消三件套和 Mocker-Planner。**是 v0.7.1 动手实现后的最佳对比参考**。
- **v0.9.1**："架构完全解耦 + 生产运维能力补齐"，新增 Event Plane，三平面完整，部署弹性和稳定性最好。**是新建生产集群的推荐版本**。

---

## 二、核心组件功能差异

### 2.1 通信架构总览

| 维度 | v0.7.1 | v0.8.1 | v0.9.1 |
|---|---|---|---|
| **通信架构** | Discovery + Request 两层 | 仍是两层，但默认更云原生 | **升级为三层**：Discovery + Request + Event |
| **服务发现（Discovery Plane）** | K8s 原生发现已引入，非默认；etcd 常见 | K8s 原生发现成为默认；etcd 完全可选 | 发现平面进一步解耦，etcd 依赖更弱 |
| **请求传输（Request Plane）** | HTTP/TCP 可用，NATS 常见 | TCP 成为默认；NATS 完全可选 | 更彻底去 NATS 依赖 |
| **事件平面（Event Plane）** | 无 | 无 | **新增**：基于 ZMQ + MessagePack 的高性能 pub/sub |
| **外部依赖** | 通常需要 etcd + NATS | etcd 和 NATS 均可选 | 无需任何外部消息代理即可部署 |

### 2.2 路由器（Router）

> v0.7.1 已有无锁路由骨架和基础 KV-Aware 路由，但关键决策算法缺失，正是动手实现的核心目标。

| 功能 | v0.7.1 | v0.8.1 | v0.9.1 | 实现要点（v0.7.1→v0.8.1） |
|---|---|---|---|---|
| **无锁路由器** | ✅ 骨架已有 | 趋于成熟 | ✅ | — |
| **KV-Aware 基础路由** | ✅ 基础已有 | 增强 | 进一步增强 | — |
| **最大树大小裁剪** | ❌ | ✅ 新增 | ✅ | 前缀树节点超阈值时按 LRU/LFU 策略剪枝 |
| **动态拒绝阈值** | ❌ | ✅ 新增 | ✅ | 根据 Worker 队列深度动态调整拒绝分数线 |
| **早期拒绝** | ❌ | ✅ 新增 | ✅ | 在路由入口即判断是否有能力接受新请求 |
| **P→D 请求取消** | ❌ | ✅ 新增 | ✅ | Prefill 完成后、Decode 开始前的中止机制 |
| **LoRA-Aware 路由** | ❌ | ✅ 新增（vLLM） | ✅ | 将 LoRA adapter 作为路由决策因子 |
| **路由提示（Header）** | ❌ | ❌ | ✅ 新增 | — |
| **PrefillComplete Hook** | ❌ | ❌ | ✅ 新增 | — |
| **预期输出 Token 感知** | ❌ | ❌ | ✅ 新增 | — |
| **输出块跟踪+分数衰减预测** | ❌ | ❌ | ✅ 新增 | — |

**Router 问题链（以 v0.7.1 为起点，逐步推导出 v0.8.1 各算法的必要性）：**

```
基础 KV-Aware 路由（v0.7.1 已有）
    │
    ▼ 问题一：前缀树存储的历史 KV 越来越多，内存怎么控制？
最大树大小裁剪
    │
    ▼ 问题二：裁剪阈值固定写死，负载突增时静态阈值不够灵活？
动态拒绝阈值
    │
    ▼ 问题三：请求已经进入路由但资源不足，怎么在最早时机拒绝？
早期拒绝
    │
    ▼ 问题四：Prefill 已经在跑，Decode Worker 却挂了，请求怎么取消？
P→D 请求取消
```

### 2.3 调度器（Planner）

> v0.7.1 具备基础容量感知，但缺少模拟调试工具；没有 Mocker-Planner 就必须连真实 GPU 才能测试调度逻辑。

| 功能 | v0.7.1 | v0.8.1 | v0.9.1 | 实现要点（v0.7.1→v0.8.1） |
|---|---|---|---|---|
| **基础容量调度** | ✅ 已有 | — | — | — |
| **SGLang MoE TEP/DEP** | ✅ 已有 | ✅ | ✅ | — |
| **Mocker-Planner** | ❌ | ✅ 新增 | ✅ | 用 Mock Worker 模拟负载，无需真实 GPU 即可测试调度逻辑 |
| **Profiler WebUI** | ❌ | ✅ 新增 | ✅ | 可视化调度决策过程；学习阶段的核心观测工具 |
| **DGD Scaling Adapter** | ❌ | ✅ 新增（默认禁用） | ✅ | Worker 数量动态伸缩适配器 |
| **Kalman 滤波器预测** | ❌ | ❌ | ✅ 新增 | — |
| **Mooncake-style 预热** | ❌ | ❌ | ✅ 新增 | — |
| **MoE DEP/TEP SLA 自动伸缩** | ❌ | ❌ | ✅ 新增（vLLM） | — |

**Mocker-Planner 的价值：**

```
没有 Mocker-Planner（v0.7.1）：
  测试调度逻辑 → 必须有真实 GPU → 成本高，无法快速迭代

有 Mocker-Planner（v0.8.1）：
  测试调度逻辑 → Mock Worker 模拟负载 → 本地即可验证调度决策是否合理
```

### 2.4 KV Block Manager（KVBM）

| 功能 | v0.7.1 | v0.8.1 | v0.9.1 |
|---|---|---|---|
| **独立 pip 安装包** | ✅ 已有 | ✅ | ✅ |
| **支持后端** | TRT-LLM + vLLM | TRT-LLM + vLLM | TRT-LLM + vLLM |
| **本地 KvIndexer** | ❌ | ✅ 新增（SGLang/TRT-LLM） | ✅ |
| **非阻塞 KV 快照** | ❌ | ✅ 新增 | ✅ |
| **对象存储（S3 後端）** | ❌ | ❌ | ✅ 新增（NIXL S3 后端） |
| **位置血统哈希** | ❌ | ❌ | ✅ 新增（PositionalLineageHash 128-bit） |
| **CUDA 内存池** | ❌ | ❌ | ✅ 新增（防止异步操作数据损坏） |

### 2.5 推理后端

| 功能 | v0.7.1 | v0.8.1 | v0.9.1 |
|---|---|---|---|
| **Intel Gaudi 支持** | ❌ | ✅ 新增 | ✅ |
| **TRT-LLM Autodeploy** | ❌ | ✅ 新增 | ✅ |
| **logprobs** | ❌ | ✅ 新增（vLLM + TRT-LLM） | ✅ |
| **libfabric 网络传输** | ❌ | ✅ 新增 | ✅ |
| **多模态（图像/音频/视频）** | 基础图像支持 | 扩展到音频 + 视频；Llama4 拆分服务 | 编码器拆分（EC Connector）；SGLang 单 GPU 多模态 |
| **扩散模型** | ❌ | ❌ | ✅ 新增（LLaDA2.0） |

### 2.6 Multi-LoRA 服务

| 功能 | v0.7.1 | v0.8.1 | v0.9.1 |
|---|---|---|---|
| **Multi-LoRA 支持** | ❌ | ✅ 新增（vLLM，含管理 API、K8s 示例） | ✅ |
| **KV-Aware LoRA 路由** | ❌ | ✅ 新增 | ✅ |

### 2.7 OpenAI API 兼容性

| 功能 | v0.7.1 | v0.8.1 | v0.9.1 |
|---|---|---|---|
| **skip_special_tokens** | ✅ 新增 | ✅ | ✅ |
| **批量补全** | ✅ 新增 | ✅ | ✅ |
| **prompt_tokens_details** | ❌ | ✅ 新增 | ✅ |
| **response_format（JSON Schema）** | ❌ | ❌ | ✅ 新增 |
| **continuous_usage_stats** | ❌ | ❌ | ✅ 新增 |
| **自动生成 OpenAPI Spec** | ❌ | ❌ | ✅ 新增 |

### 2.8 可观测性与容错

| 功能 | v0.7.1 | v0.8.1 | v0.9.1 |
|---|---|---|---|
| **分布式追踪** | 基础（etcd HA） | 统一追踪（SGLang + vLLM） | 全链路追踪（含 TRT-LLM + TCP 传输） |
| **Grafana Dashboard** | CPU 指标 | 新增 Planner Dashboard | 增强 |
| **nvext 扩展字段** | ❌ | ✅ 新增（worker_id, TTFT, 请求时间） | ✅ |
| **Prometheus 指标** | 基础 | 增强（cache hit rate、请求迁移） | 精简 91% 未使用代码 |
| **请求迁移** | ❌ | ❌ | ✅ 新增（TRT-LLM shutdown_event） |

---

## 三、部署差异

### 3.1 外部依赖与部署复杂度

| 维度 | v0.7.1 | v0.8.1 | v0.9.1 |
|---|---|---|---|
| **etcd** | 通常必需 | 可选 | 依赖进一步消除 |
| **NATS** | 常见 / 默认 | 可选 | 基本消除 |
| **外部消息代理** | 需要 | 可选 | **无需任何外部消息代理** |
| **部署链路复杂度** | 高 | 中 | 低（最精简） |

### 3.2 Kubernetes 原生能力

| 功能 | v0.7.1 | v0.8.1 | v0.9.1 |
|---|---|---|---|
| **K8s 原生服务发现** | 已引入，非默认 | **成为默认** | 成为默认 |
| **Validation Webhooks** | ❌ | ✅ 新增 | ✅ |
| **CUDA Fault Injection** | ❌ | ✅ 新增 | ✅ |
| **DGD Scaling Adapter** | ❌ | ✅ 新增（默认禁用） | ✅（默认禁用） |
| **Rollout Restart** | ❌ | ❌ | ✅ 新增 |
| **Operator 可观测性指标** | ❌ | ❌ | ✅ 新增 |
| **容器安全（非特权模式）** | ❌ | ❌ | ✅ 新增 |
| **Profiler PVC Model Cache** | ❌ | ✅ 新增 | ✅ |
| **命名空间隔离** | ✅ | ✅ | ✅ |

### 3.3 扩缩容与高可用

| 维度 | v0.7.1 | v0.8.1 | v0.9.1 |
|---|---|---|---|
| **调度/路由预测能力** | 相对基础 | 增强，更稳定弹性 | Kalman 预测 + 预热 + SLA 自动伸缩，最智能 |
| **Event Plane 协同扩缩** | ❌ | ❌ | ✅（ZMQ 本地通信，无中心节点） |
| **Prefill / Decode 独立扩缩** | ✅ | ✅ | ✅（Rollout Restart 支持有序更新） |
| **MoE SLA 驱动自动伸缩** | ❌ | ❌ | ✅ 新增（vLLM） |

### 3.4 本地开发环境对比

| 维度 | v0.7.1 | v0.8.1 |
|---|---|---|
| **最简启动依赖** | Docker + etcd + NATS | Docker（K8s 模式无需 etcd/NATS） |
| **无 GPU 本地调试** | 无 Mock 工具，必须连真实 Worker | Mocker-Planner 支持，无需 GPU |
| **调度可视化** | 无 WebUI，只能看日志 | Profiler WebUI 可直观观察调度行为 |
| **非法配置防护** | 错误配置到运行时才报错 | Validation Webhooks 在 apply 时即拦截 |

**v0.7.1 本地环境快速固化（消除 etcd/NATS 噪音，专注核心逻辑）：**

```yaml
# docker-compose.dev.yaml
services:
  etcd:
    image: bitnami/etcd:3.5
    environment:
      - ALLOW_NONE_AUTHENTICATION=yes
    ports:
      - "2379:2379"

  nats:
    image: nats:2.10
    ports:
      - "4222:4222"
```

一次 `docker compose up -d` 固化后，开发过程中完全忽略这两组件，专注 Router/Planner 逻辑。

### 3.5 部署演进趋势

```
v0.7.1                    v0.8.1                    v0.9.1
  │                          │                          │
  ├─ etcd 必需               ├─ etcd 可选               ├─ etcd 几乎不需
  ├─ NATS 常见               ├─ NATS 可选               ├─ NATS 消除
  ├─ K8s 原生发现可选         ├─ K8s 原生发现默认         ├─ 发现平面完全解耦
  ├─ 基础治理能力             ├─ Webhook/FaultInject     ├─ 三平面完整架构
  └─ CUDA 12.8 起步          └─ 统一 CUDA 12.9          └─ 事件平面 + 安全加固
```

---

## 四、CUDA 版本详细分析

### 4.1 各版本 CUDA 需求汇总

| Dynamo 版本 | 后端 | CUDA Toolkit | 最低驱动版本 | 备注 |
|---|---|---|---|---|
| **v0.7.1** | SGLang | **12.8** | 570.xx+ | |
| | vLLM | **12.9** | 575.xx+ | |
| | TensorRT-LLM | **13.0** | 580.xx+ | |
| **v0.8.1** | SGLang | **12.9** | 575.xx+ | |
| | SGLang | 13.0 | 580.xx+ | 实验性 |
| | vLLM | **12.9** | 575.xx+ | |
| | vLLM | 13.0 | 580.xx+ | 实验性 |
| | TensorRT-LLM | **13.0** | 580.xx+ | |
| **v0.9.1** | SGLang | **12.9** | 575.xx+ | |
| | vLLM | **12.9.1** | 575.xx+ | |
| | TensorRT-LLM | **13.0** | 580.xx+ | |

### 4.2 最低 CUDA 版本快速参考

| 使用场景 | v0.7.1 | v0.8.1 | v0.9.1 |
|---|---|---|---|
| **仅 SGLang** | CUDA **12.8**，驱动 570.xx+ | CUDA **12.9**，驱动 575.xx+ | CUDA **12.9**，驱动 575.xx+ |
| **仅 vLLM** | CUDA **12.9**，驱动 575.xx+ | CUDA **12.9**，驱动 575.xx+ | CUDA **12.9.1**，驱动 575.xx+ |
| **使用 TRT-LLM** | CUDA **13.0**，驱动 580.xx+ | CUDA **13.0**，驱动 580.xx+ | CUDA **13.0**，驱动 580.xx+ |
| **全部三个后端** | CUDA **13.0**，驱动 580.xx+ | CUDA **13.0**，驱动 580.xx+ | CUDA **13.0**，驱动 580.xx+ |

> **关键结论：** 只要使用 TRT-LLM，三个版本都强制要求 CUDA 13.0 + 驱动 580.xx+，由 TRT-LLM 决定下限。

### 4.3 各版本 CUDA 需求变化原因

#### v0.7.1：CUDA 12.8 / 12.9 / 13.0 三线并存

1. **SGLang 需要 CUDA 12.8**：SGLang 0.5.4.post3 基于较早的 PyTorch 构建，仅需 12.8。
2. **vLLM 需要 CUDA 12.9**：vLLM 0.11.0 容器镜像基于 CUDA 12.9 构建。
3. **TRT-LLM 需要 CUDA 13.0**：TRT-LLM 1.2.0rc3 自该版本起升级至 CUDA 13.0 基础镜像，以支持 Blackwell 架构（B200/GB200/GB300）。
4. **NIXL 兼容性修复**：v0.7.0 默认的 TRT-LLM 1.2.0rc2 携带 NIXL 0.5.0，而 Dynamo 需要 NIXL 0.7.1+；v0.7.1 升级到 rc3 修复了此问题。

#### v0.8.1：统一到 CUDA 12.9，并引入实验性 CUDA 13

1. **SGLang 升级到 12.9**：升级 SGLang 到 0.5.6.post2 并切换为上游 SGLang 运行时容器，基于 CUDA 12.9 构建。
2. **实验性 CUDA 13 引入**：为 SGLang 和 vLLM 添加实验性 CUDA 13.0 容器镜像，提前验证 Blackwell GPU 兼容性。
3. **TRT-LLM 仍需 CUDA 13.0**：TRT-LLM 1.2.0rc6.post1 继续基于 CUDA 13.0。
4. **NIXL/UCX 双版本支持**：NIXL 升级到 0.8.0，UCX 升级到 1.20，KVBM 同时支持 CUDA 12 和 CUDA 13。
5. **CuDNN 修复**：v0.8.1 修复 SGLang CUDA 13 容器中的 CuDNN 安装问题，需安装 CuDNN 9.16+（否则 `nn.Conv3d` 出现性能退化和内存溢出）。

#### v0.9.1：稳定在 CUDA 12.9，移除实验性标签

1. **SGLang/vLLM 维持 CUDA 12.9**：SGLang 0.5.8 和 vLLM 0.14.1 主容器保持 CUDA 12.9。
2. **实验性 CUDA 13 标签移除**：SGLang/vLLM 的实验性 CUDA 13 标注不再出现，表明暂未成熟到正式支持。
3. **vLLM 容器升级到 CUDA 12.9.1**：明确将 vLLM 容器的 CUDA 版本升级到 12.9.1，提供更新工具链和 bug 修复。
4. **TRT-LLM 升级到 1.3.0rc3**：继续要求 CUDA 13.0，包含上游 bug 修复和性能改进。
5. **KVBM 修复**：移除了 KVBM 的变通方案，TRT-LLM 1.3.0rc3 内含上游修复（TRT-LLM #11247）。

### 4.4 TensorRT-LLM 始终要求 CUDA 13.0 的原因

1. **Blackwell GPU 原生支持**：CUDA 13.0 是 NVIDIA Blackwell 架构（B200/B300/GB200/GB300）的原生运行时，TRT-LLM 率先切换以支持最新硬件。
2. **TensorRT 引擎依赖**：TRT-LLM 底层 TensorRT 核心库与 CUDA 13 工具链紧密绑定。
3. **性能优化**：CUDA 13.0 引入了针对 Blackwell 架构优化的 kernel 和 API（更高效的 Tensor Core 利用），TRT-LLM 需要这些特性实现最佳推理性能。
4. **NCCL 通信**：TRT-LLM 多节点部署依赖的 NCCL 版本需要与 CUDA 13 配套。

### 4.5 SGLang/vLLM 可以使用 CUDA 12.x 的原因

1. **PyTorch 兼容性**：SGLang 和 vLLM 基于 PyTorch，PyTorch 主流发布版本以 CUDA 12.x 为主要支持目标。
2. **社区驱动**：SGLang/vLLM 面向更广泛的用户群体（Ampere A100、Ada L40S、Hopper H100/H200），这些 GPU 主要运行 CUDA 12.x。
3. **渐进式迁移**：采用从实验性（v0.8.x）逐步稳定的策略，在不强制升级用户环境的前提下提供最新硬件支持。

---

## 五、版本选型建议

| 场景 | 推荐版本 | 理由 |
|---|---|---|
| **深入学习 Router/Scale 原理（动手实现）** | **v0.7.1** | 骨架已就位，关键算法缺位，正是最佳实现起点 |
| **实现完成后的对比参考** | **v0.8.1** | 补齐路由裁剪/拒绝/取消三件套、Mocker-Planner、Profiler WebUI |
| **新建生产 K8s 集群** | v0.9.1 | 三平面解耦、部署治理、可观测性最完整 |
| **需要简化部署 / 暂不追最新特性** | v0.8.1 | 已去除 etcd/NATS 依赖，K8s 原生发现稳定 |
| **受限于旧 CUDA 12.8 环境（SGLang only）** | v0.7.1 | 唯一支持 CUDA 12.8 的版本 |
| **重度依赖 TRT-LLM** | v0.9.1 | TRT-LLM 1.3.0rc3 性能最优（所有版本都需 CUDA 13.0） |
| **Multi-LoRA 服务** | v0.8.1 / v0.9.1 | v0.7.1 不支持 Multi-LoRA |
| **Hopper（H100/H200）+ SGLang/vLLM** | v0.9.1 | 最新稳定版，CUDA 12.9 即可，功能最完整 |
| **Blackwell（B200/GB200）+ TRT-LLM** | v0.9.1 | 需 CUDA 13.0，TRT-LLM 1.3.0rc3 性能最优 |

---

## 六、从旧版本迁移要点

### v0.7.1 → v0.8.1 主要变化

| 维度 | 关键变化 |
|---|---|
| **基础设施** | etcd/NATS 从必需变为可选；K8s 原生发现成为默认；TCP 成为默认请求传输 |
| **多模态** | 从基础图像支持扩展到音频 + 视频；Llama4 多模态拆分服务 |
| **LoRA** | 新增完整 Multi-LoRA 服务能力（vLLM） |
| **可观测性** | 统一分布式追踪；Planner Grafana Dashboard；nvext 扩展字段 |
| **K8s** | CUDA Fault Injection 框架；Validation Webhooks；Profiler PVC 支持 |
| **CUDA** | SGLang 从 12.8 升到 12.9；新增实验性 CUDA 13 容器 |

### v0.8.1 → v0.9.1 主要变化

| 维度 | 关键变化 |
|---|---|
| **基础设施** | 新增 Event Plane（ZMQ + MessagePack）；通信架构升级为三层完全解耦 |
| **多模态/扩散** | 编码器拆分（vLLM EC Connector + TRT-LLM Standalone Encoder）；LLaDA2.0 扩散模型 |
| **路由** | 输出块跟踪 + 分数衰减预测；路由提示从 Header 读取；PrefillComplete Hook |
| **调度** | Kalman 滤波器预测；Mooncake-style 预热；MoE SLA 自动伸缩 |
| **KVBM** | S3 对象存储后端；PositionalLineageHash；CUDA 内存池 |
| **K8s** | Rollout Restart；Operator 可观测性指标；容器安全（非特权模式） |
| **容错** | TRT-LLM 请求迁移；简化 Prometheus API（精简 91% 未使用代码） |
| **CUDA** | 实验性 CUDA 13 标签移除；vLLM 容器升级到 CUDA 12.9.1 |

---

## 七、以 v0.7.1 为 Base 的学习实现路线图

```
阶段一：理解 v0.7.1 现有骨架
├─ 读懂无锁路由器的数据结构
├─ 读懂基础 KV-Aware 路由的前缀树实现
└─ 读懂 Planner 的基础容量感知逻辑

阶段二：自己实现 Router 增强（对标 v0.8.1）
├─ 实现最大树大小裁剪
│     目标：前缀树节点数超过阈值时，按 LRU/LFU 策略裁剪
├─ 实现动态拒绝阈值
│     目标：根据 Worker 队列深度动态调整拒绝分数线
├─ 实现早期拒绝
│     目标：在路由入口即判断是否有能力接受新请求
└─ 实现 P→D 请求取消
      目标：Prefill 完成通知到达后，若 Decode Worker 不可用则取消并回复客户端

阶段三：自己实现 Planner 增强（对标 v0.8.1）
├─ 实现 Mocker-Planner
│     目标：用 Mock Worker 替代真实 GPU Worker，模拟负载上报和 KV 状态
└─ 实现 DGD Scaling Adapter（可选）
      目标：根据队列积压触发 Worker 数量变化

阶段四：对比 v0.8.1 官方实现
└─ diff 你的实现 vs 官方实现
      重点关注：设计取舍、边界处理、性能优化点
```

| 版本 | 定位 |
|---|---|
| **v0.7.1** | Router 骨架 + 基础 KV 路由 + 基础调度已就位；**关键算法缺位，正是动手实现的起点** |
| **v0.8.1** | 补齐了路由裁剪/拒绝/取消三件套、Mocker-Planner、Profiler WebUI；**是你实现完成后的对比参考** |
| **v0.9.1** | 架构完全解耦、三平面成熟、生产运维完备；**是最终生产目标参考** |
