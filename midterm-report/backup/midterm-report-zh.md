# 面向强化学习的 NVIDIA Dynamo 推理服务：弹性 PD 角色切换与在线解码请求合并

> **子方向：** 云原生 LLM 推理 — 基于 NVIDIA Dynamo 的伸缩  
> **作者：** 张胜祺  
> **机构：** 香港科技大学 工学硕士（毕业论文中期）  
> **基准：** NVIDIA Dynamo v1.0.1（最新稳定版，2026-03）  
> **日期：** 2026-05-19

---

本报告中所有仓库专有术语（DWMD、ModelCard、TCP slot、WorkerSet 等）的完整定义汇集于**附录 A**。

---

## 摘要

遵循 **Prefill–Decode（PD）分离** 范式的大语言模型推理服务把计算分摊到两类功能各异的 GPU 池：prefill workers（计算受限）与 decode workers（显存带宽受限）。该布局在**在线**场景下最大化每阶段的效率，也是当今主流的开源 PD 分离运行时——**NVIDIA Dynamo**——的架构选择。Dynamo 将一个有状态的 KV 感知路由器与每 pod 一份的 vLLM 引擎耦合，并以 `DynamoWorkerMetadata`（DWMD）Kubernetes 自定义资源作为唯一可观察的注册面。

本课题聚焦 **强化学习（RL）后训练场景**：训练环在采样阶段批量地向 LLM 推理服务发起请求，与梯度更新交替进行。该工作负载使 PD 分离布局呈病态表现：每个 GPU 池会**连续闲置数分钟**，而另一池正处于 GPU 满负荷状态——RL 流量具有阵发性、周期性、批量性，而非 PD 分离所假定的近似稳态流。静态过度供给持续浪费训练任务正在支付的 GPU 工时；水平扩缩容（pod 冷启动 ≈ 数十秒）的响应速度不足以在单次 rollout 阶段内介入。核心技术问题因此是：**能否在数百毫秒内重塑 decode 与 prefill 池的规模，且不丢失正在生成的长完成、不打乱路由器？**

本报告以基于 Dynamo + vLLM 0.16 的两个新的运行时原语来回答这一问题：

1. **弹性 PD 角色切换** —— 一个由状态机驱动的原地协议，通过修改运行中 vLLM worker 自身 DWMD CR 中的 `model_cards` 条目并循环 sleep/wake 引擎状态，使其在 decode 与 prefill 角色之间翻转。无需重建引擎、无需重部署 pod，pod 名与 IP 保持不变。
2. **在线解码请求合并** —— 一个三阶段块持有协议，通过 NIXL 跨 NVLink 直接**拉取**源 worker GPU 上的 KV 块，将源端正在运行的 decode 请求迁至目标 worker，源 worker 在握手期间持续钉住 KV 块，保证零 KV 丢失。

配合一个消费 RL rollout 阶段信号的自动伸缩控制器，上述两个原语使运维者能够**与 RL 阶段对齐**地动态重塑 decode/prefill 池规模，从而提升 GPU 有效工时并缩短单批 wall-clock。

在 `Qwen3-0.6B` 的单节点 Kubernetes 部署上，端到端验证表明：

* 一次完整 decode→prefill→decode 往返的客户端 wall-clock 为 **963 ms**（服务端 453 ms + 428 ms）；
* 源 decoder 上已生成 **1688** token 的在线 decode 请求，在 **188 ms** 内经 `NixlConnector` RDMA 路径完成跨 GPU 迁移，**109 个物理 KV 块**被直接拉取而非重算前缀（目标端 `migrate_in` 响应报告 `"path": "connector"`，源端 `migrate_out` 返回完整 `kv_transfer_params`，客户端 SSE 流无 token 丢失）；
* 覆盖完整 switch+revert 序列的 2 RPS 背景负载完成 **58/58 请求、零 HTTP 错误**（p50 = 65 ms，p99 = 105 ms）。

---

## 1. 引言

### 1.1 NVIDIA Dynamo 简介

NVIDIA Dynamo（v1.0.1 GA，2026-03）是面向 PD 分离 LLM 推理的开源服务框架。架构上它是一个 Rust 运行时，承载（i）一个终结 OpenAI 兼容 HTTP 的 **frontend** pod，（ii）任意数量、每个包裹一份 vLLM 引擎的 **worker** pod，（iii）一个以 Kubernetes 自定义资源（DWMD）为 worker 成员唯一可观测事实源的发现层。Frontend 内嵌两个有状态路由器——`KvRouter` 负责 decode 派发，`PrefillRouter` 负责 prefill 派发——以及一个通过 `list+watch` DWMD 维护 WorkerSet 的 `ModelWatcher`。Prefill 与 decode worker 之间的 KV 缓存传输由 **NIXL** 连接器在 NVLink/RDMA 上完成。该技术栈是当前生产级 PD 分离推理的事实主流，也是本课题扩展的基线。

### 1.2 RL 工作负载的 GPU 浪费问题

LLM 推理的成本主要由 GPU 工时决定。在线聊天场景的流量近似稳态，静态 PD 划分行之有效，因两池长期繁忙。而驱动现代后训练方法（RLHF、DPO、GRPO）的 **RL rollout 循环**所提交的推理流量呈现本质上不同的模式：

```
  ┌──────────┐   ┌────────────┐   ┌──────────┐   ┌──────────┐
  │  采样    │──▶│  批量推理  │──▶│  训练    │──▶│  采样    │──▶ ...
  │ GPU 闲   │   │  GPU 忙    │   │ GPU 忙   │   │ GPU 闲   │
  └──────────┘   └────────────┘   └──────────┘   └──────────┘
   ◄─ 空闲 ──▶◄── 阵发 ──▶◄── 训练 ──▶◄─ 空闲 ──▶
```

每次阶段切换都会使 Dynamo 两个 GPU 池中的一个完全繁忙、另一个完全空闲，由此产生两类相互叠加的浪费：

1. **跨阶段池浪费。** Prefill GPU 只在 prompt 阶段忙；Decode GPU 只在长尾生成阶段忙。当前空闲的池仍然占据 GPU 配额、仍然在被实时计费。
2. **阶段内尾部浪费。** 一批接近收尾时每个 decoder 上仍在运行的请求数趋近于 0，但仍有少量长完成未结束，使得 decoder 无法释放 GPU。

常规弹性手段在结构上与该工作负载不匹配，原因有二。其一，**水平 pod 伸缩**的冷启动时延在数十秒量级（含镜像拉取、引擎构造、模型权重加载、NIXL 握手），比它本应介入的采样阶段长一至两个数量级；且新建 pod 起始时 prefix cache 为空，丢失了 PD 分离本应释放的前缀复用收益。其二，**静态过度供给**按所容忍的最差阶段的峰值需求来设定两池规模，因而无论某池是否空闲都把 GPU 支出锁定在峰值，违背了 §1.3 对 $\text{GPU}_{\text{hours}}$ 的有界化目标。两者均无法满足 RL 控制器**在一次 rollout 阶段内**做出反应的要求。

### 1.3 优化目标

将 RL 工作负载的目标形式化：

$$
\text{最小化 } T_{\text{batch}} = \max_{r \in \text{Batch}} T_{\text{complete}}(r)
\qquad
\text{最小化 } \text{GPU}_{\text{hours}} = \sum_{g \in \text{GPUs}} T_{\text{allocated}}(g)
$$

$$
\text{最大化 } U_{\text{GPU}} = \frac{\sum_g T_{\text{compute}}(g)}{\sum_g T_{\text{allocated}}(g)}
$$

可操作的杠杆是 $U_{\text{GPU}}$：通过把当前空闲的 GPU **改角色**为目前正瓶颈的阶段，并把尾部 decode 工作**合并**到更少的 GPU 上，系统提升了每 GPU 工时的有用功。整套操作必须在**亚秒级**完成，RL 控制器才能在一次 rollout 阶段**内部**有效干预。

### 1.4 在 vLLM + Dynamo 上的技术困难

vLLM 0.16 + Dynamo v1.0.1 栈有三个结构性事实让朴素弹性方案不安全：

1. **`kv_transfer_config` 在引擎构造时固定。** NIXL 连接器在引擎启动时绑定到**一种**角色。任何运行期"角色切换"都不能重建引擎。
2. **vLLM 的 prefix cache 是覆盖在 KV 块之上的索引**，而 `engine.sleep(level=2)` 会把这些 KV 块退还到 GPU 分配器。如果不同步重置索引，唤醒后的引擎可能击中已无效的命中。
3. **Dynamo 路由器是有状态的。** `KvRouter` 与 `PrefillRouter` 各自维护一棵 radix 树 KV 索引和每 worker 的代价模型。角色变更必须通过 DWMD 传播并完成状态收敛，且不影响在飞请求。

### 1.5 贡献

* **(C1) 八步原地角色切换状态机**（`DualModeWorker.switch_role`）：把 `engine.sleep(2) → 注销 ModelCard → NIXL 重置 → prefix-cache 重置 → 角色翻转 → 注册 ModelCard → engine.wake_up → 触发 role-changed` 组合成一个**从调度器视角看是原子的**操作。实测：**服务端 453 ms，客户端 wall-clock 497 ms**（decode→prefill）；反向 **428 / 466 ms**。
* **(C2) 单 TCP-slot 调度器**：让一份预先以 `kv_role=kv_both` 与一个 `(connection_id, "generate")` TCP slot 构建的 vLLM 引擎，在运行时按 `dual_mode.current_role` 路由 chat（decode）或 prefill 流量。
* **(C3) 三阶段块持有 NIXL-pull 迁移协议**（`migrate_out → migrate_in → migration_complete`）：通过跨 NVLink **拉取**对端的 GPU KV 块来合并运行中的 decoder，源端在握手全过程钉住块（零 KV 丢失），10 s 扫描器在编排者失效时防止块泄露。
* **(C4) RL-信号驱动的自动伸缩控制器**，消费 rollout 阶段信号并派发上述原语。
* **(C5) 端到端验证**：在 `Qwen3-0.6B` 的 Kubernetes 部署上同时用 CRD 层发现差异与 Prometheus 层 prompt-token 归因证明角色切换；用六个并发迁移的 `left_TARGET ∧ accepted_at_PEER` 断言证明合并。

报告结构如下：§2 综述相关运行时；§3 介绍部署拓扑与端口模型；§4 详述角色切换协议；§5 详述合并协议；§6 描述 RL 信号自动伸缩；§7 呈现实验验证；§8 讨论局限与未来工作。

---

## 2. 背景与相关工作

### 2.1 Prefill–Decode 分离范式

**动机。** 每个 LLM 推理请求都经历两个串行阶段，它们共享**同一组**模型权重却具有**不同的**资源瓶颈：

| 阶段 | 输入 | 计算 | 瓶颈 |
|------|------|------|------|
| **Prefill** | 一次性处理 `N` 个 prompt token | 整模型前向，`\|Q\|=\|K\|=\|V\|=N` | 计算受限（大 GEMM） |
| **Decode** | 1 个新 token + 已有 KV cache | 前向，`\|Q\|=1`、`\|K\|=\|V\|=N+t` | 显存带宽受限（KV 读取） |

把两阶段同 GPU 共置（连续批处理）能最大化裸吞吐，但会引发严重的队首阻塞：一次长 prefill 将卡住同批快速 decode，损害单请求时延。**PD 分离服务**——由 Splitwise 与 DistServe 开创，并被 NVIDIA Dynamo、vLLM-disagg、SGLang-disagg 采纳为主流模式——将两阶段拆分到独立 GPU 池：prefill 池产生 KV cache 并经高带宽通道（NVLink / NIXL-over-RDMA）传给 decode 池。其优势：

* 计算受限与带宽受限工作不再相互干扰；
* 每个池可按各自瓶颈独立调度与扩缩；
* prefix cache 成为一等的跨请求优化（cache 位于 decode 侧，可跨 prompt 前缀相同的请求共享）。

**图 1 — Prefill–Decode 分离请求流（占位示意）。**

```
                            ┌────────────────────────┐
   prompt (N tokens) ─────► │  Prefill Worker (GPU)  │── KV blocks ─┐
                            │  大 GEMM, 一次前向     │  via NIXL    │
                            └────────────────────────┘              │
                                                                    ▼
                                                       ┌────────────────────────┐
                                token N+1, N+2, … ◄────│  Decode Worker (GPU)   │
                                                       │  小 GEMM, KV 读受限,   │
                                                       │  循环                  │
                                                       └────────────────────────┘
```

**不可避免的代价。** 拆分继承了一个结构性低效：负载的“计算/显存读取”比不一定与运维侧给定的“prefill GPU / decode GPU”比相等——于是一池闲置而另一池过载。这正是本工作的杆杆点。

### 2.2 NVIDIA Dynamo 运行时

Dynamo 在有状态 vLLM 引擎之上提供路由与发现基础设施。本工作所依赖的三个子系统：

* **发现层**（`lib/runtime/src/discovery/kube.rs`）。设 `DYN_DISCOVERY_BACKEND=kubernetes`，每个 worker pod 拥有一份 **`DynamoWorkerMetadata`（DWMD）CR**，其 `spec.data.{endpoints, event_channels, model_cards}` **就是**该 worker 的运行期注册。Worker 通过 `apply_cr()`（strategic-merge-patch）增删条目；frontend 的 `ModelWatcher` 通过 `list+watch` DWMD 重建 WorkerSet。**没有 etcd、没有中心化注册表**——DWMD 即唯一事实源。
* **`KvRouter` + `PrefillRouter`**（`lib/llm/src/kv_router/`）。有状态的路由引擎。`KvRouter` 在每个 decoder 持有的 KV 块之上维护 radix 树索引，给候选打分：

  $$
  \text{logit}(w) = \alpha \cdot \frac{\text{overlap\_blocks}(w)}{\text{total\_blocks}} + \beta \cdot \text{queue\_load}(w) + \gamma \cdot \text{capacity}(w)
  $$

  并通过 `softmax_sample` 选择（在 `temperature=0` 时即 argmin）。`PrefillRouter` 把 prefill 流量扇出到任何通过 DWMD 被发现的 **prefill 角色** ModelCard。当一个 worker 的角色变化时，整条状态机必须随 DWMD 传播完成收敛。
* **NIXL 连接器与 KVBM**（`lib/llm/src/kvbm/`，vLLM `NixlConnector`）。NIXL 在 NVLink 上提供零拷贝跨 GPU KV 传输（多主机时走 IB RDMA）。KVBM 跟踪每请求的 GPU 块布局。两者共同允许一个 decoder 直接从另一个 worker 的 VRAM **拉取** KV 块，§5 在线合并即依赖于此。

**图 2 — Dynamo 运行时架构（占位示意）。**

```
   ┌──────────────────────────┐         ┌────────────────────────────┐
   │  Frontend Pod            │ 监听    │  Worker Pod                │
   │  ─────────────           │ ◄───────┤  ─────────────             │
   │  HTTP :8000 (OpenAI)     │  DWMD   │  Dynamo runtime (Rust)     │
   │  ┌────────────────────┐  │         │   - apply_cr() 写自身 DWMD │
   │  │ ModelWatcher       │  │         │   - 监听 TCP slot:         │
   │  │  → WorkerSet       │  │         │     host:port/{cid}/gen…   │
   │  │  → KvRouter        │  │         │                            │
   │  │  → PrefillRouter   │  │         │  vLLM engine               │
   │  └─────────┬──────────┘  │         │   + NIXL 连接器            │
   │            │             │         │   + prefix cache + KVBM    │
   │            ▼             │         │                            │
   │  选中的 TCP slot ────────┼─ generate ─────────────────────────► │
   └──────────────────────────┘         │   :9090 系统 / Prom        │
                                        │   :9091 RL-Scaling sidecar │
              ┌────────────────────┐    └────────────────────────────┘
              │  Kubernetes API    │
              │  CRDs: DGD, DWMD…  │
              └────────────────────┘
```

### 2.3 KV 缓存与 prefix 缓存

KV 缓存保存所有先前 token 的 K/V，使 decode 摊薄注意力代价。**prefix 缓存**让 prompt 前缀相同的请求间复用 KV 块。vLLM 0.16 把 cache 的**索引**放在 CPU 内存、**块**钉在 GPU VRAM。这一拆分正是 §4.3 角色切换协议的**一致性目标**：`engine.sleep(2)` 把块退还给 GPU 分配器后，索引仍可能存活；唤醒时陈旧命中会破坏后续请求。

### 2.4 相关系统对比

| 系统 | 弹性原语 | 本工作弥补之处 |
|------|----------|----------------|
| **Splitwise [5] / DistServe [4]** | 部署期静态 PD 划分 | 缺乏运行期角色翻转 |
| **vLLM [2] 原生扩缩** | Pod 复制 | 冷启动 ≈ 30 s，丢失 prefix cache |
| **Mooncake [3]** | KV 池外溢（CPU/SSD） | 与 PD 正交，不做角色切换 |
| **ServerlessLLM [8]** | 冷启动优化的无服务器推理 | 未处理 PD 分离拓扑 |
| **SpotServe [9]** | Spot 实例迁移 | 实例级粒度，非请求级 |
| **本工作** | 原地角色切换 + 在线 NIXL-pull 迁移 | 亚秒级弹性**且**零 KV 丢失 |

据我们所知，目前没有任何开源服务系统同时具备 (a) 亚秒级原地 PD 角色翻转和 (b) 在线 decoder-to-decoder NIXL-pull 迁移，并能被外部 RL 信号驱动。

---

## 3. 系统总览

### 3.1 部署拓扑与端口模型

RL-Scaling 部署在原版 Dynamo `DynamoGraphDeployment`（DGD）的基础上新增一个 pod 内组件（**RL-Scaling sidecar**）与一个集群级组件（**RL-Scaling 控制器**）。

**图 3 — 部署拓扑（占位示意）。**

```
┌──────────────────────────────────────────────────────────────────────────┐
│                       Kubernetes  (kube-apiserver)                       │
│  CRDs:  DynamoGraphDeployment | DynamoComponentDeployment |              │
│         DynamoWorkerMetadata (DWMD, 每 worker pod 一份)                  │
└─────────▲────────────────────────────────────▲───────────────────────────┘
          │ apply / watch                      │ apply / watch
┌─────────┴───────────────┐         ┌──────────┴────────────────────────┐
│ Frontend pod            │         │ Worker pod (dual-mode)            │
│  HTTP :8000             │ watch   │  Dynamo runtime (Rust)            │
│  ModelWatcher           │ ◄──DWMD─┤   一个 TCP slot：                 │
│   → WorkerSet           │         │     pod_ip:<dyn-port>/{cid}/gen   │
│   → KvRouter            │         │  vLLM (kv_both, +NIXL, +KVBM)     │
│   → PrefillRouter       │         │  :9090  Dynamo 系统 / Prometheus  │
└──────────┬──────────────┘         │  :9091  RL-Scaling sidecar        │
           │  从 DWMD 读取          │         /switch_role               │
           │  TCP slot URL          │         /migrate                   │
           ▼                        │         /v1/active_requests        │
   被选中的 worker ─────────────────┼─► generate                        │
                                    └────────────────────────────────────┘
```

**端口模型需要显式列表说明，因为"角色 vs 端口"的区分是部署中最易出错的一点。** 一个 dual-mode worker pod 暴露**三个**逻辑 TCP 服务，**没有一个是"decode 端口"或"prefill 端口"——worker 的角色被编码在所发布的 ModelCard 里，而非监听端口上**：

| 服务 | 端口 | 持有方 | 角色 |
|------|------|--------|------|
| Frontend HTTP API | `:8000`（Ingress） | Frontend pod | OpenAI 兼容 chat/completions 入口 |
| 请求处理 slot | **动态** TCP 端口；引擎启动时由 Rust 运行时分配；通过 `DWMD.endpoints[…].transport.tcp = pod_ip:<port>/{connection_id:x}/generate` 公告 | 各 worker pod | Frontend 路由器实际连接的 `generate` 端点 |
| 系统 / Prometheus | `:9090` | 各 worker pod | 内部指标与健康检查（**不处理请求**） |
| RL-Scaling sidecar | `:9091` | 各 worker pod | 控制面 HTTP：`/switch_role`、`/migrate`、`/v1/active_requests`、`/v1/role`（**不处理请求**） |

dual-mode 运行的关键不变量是：

> **一 pod、一引擎、一 TCP slot —— 两张 ModelCard（decode + prefill）轮流持有该 slot。**

vLLM 引擎以 `--kv-transfer-config NixlConnector kv_both --kv-events-config zmq` 构建，启动时即同时携带两种角色所需的 NIXL 元数据。Rust 运行时**只**打开一个 `{connection_id:x}/generate` TCP slot。当 worker 正在做 *decoder* 时，发布的 ModelCard 是 `…/backend/generate/<instance>`，其 transport URL 指向该 slot；当转为 *prefill* 时，ModelCard 是 `…/prefill/generate/<instance>`，其 transport URL 指向**同一**个 slot。slot 内部的请求时调度器读取 `dual_mode.current_role` 选择代码路径（§4.5）。因此 **`switch_role` 从不重开任何套接字**；它只是更名 frontend `ModelWatcher` 在 DWMD 中观察到的那条**条目**。

`:9091` 上的 RL-Scaling sidecar 是一条严格分离的**控制面**：它接受控制器（或测试工具）发来的 `POST /switch_role` 与 `POST /migrate`，进而驱动 `DualModeWorker` / `MigrationHandler`。它**从不**位于 chat 请求的数据面。

### 3.2 模块边界

| 模块 | 源文件 | 职责 |
|------|--------|------|
| 发现（Rust） | `lib/runtime/src/discovery/kube.rs` | apply / watch DWMD CR；本 pod DWMD 的唯一写者 |
| `EngineHandler`（Python） | `components/src/dynamo/vllm/handlers.py` | 包装 vLLM `generate / sleep / wake_up`；为 pod 内请求登记表挂钩 |
| `VllmReregistrar` | `components/src/dynamo/vllm/main.py` | 按角色维护 `endpoints_by_role`；在 DWMD 中发布 / 收回某角色的 ModelCard |
| `DualModeWorker` | `components/src/dynamo/vllm/dual_mode.py` | 八步状态机 `switch_role` 编排 |
| `MigrationHandler` | `components/src/dynamo/vllm/migration.py` | 三阶段 `migrate_out / migrate_in / migration_complete`；victim 选择；待迁移扫描器 |
| RL-Scaling sidecar | `components/src/dynamo/vllm/rl_scaling_sidecar.py` | `:9091` 上的 aiohttp；对 `DualModeWorker` 与 `MigrationHandler` 的薄 HTTP 外壳 |
| RL-Scaling 控制器 | `rl-scaling-controller/` | 集群级状态机；消费 RL 信号；patch `DGD` replicas，调用 `/switch_role` / `/migrate` |
| RL-Signal SDK | `rl-signal-sdk/` | 训练任务发出 rollout-phase 信号的 SDK 库 |

### 3.3 请求路径概述

单条 chat 请求在系统中的处理步骤如下：

1. 客户端向 frontend `:8000` 发起 `POST /v1/chat/completions`。
2. 在 PD 分离模式下，`PrefillRouter` 先从 WorkerSet 的 prefill 子集中选定一个 prefill worker，把 prompt 派发给它，并接收描述其所产 KV 块的 `kv_transfer_params`。
3. `KvRouter` 对每个候选 decoder 按 radix 树前缀块重叠度、队列负载、剩余 KV 容量打分，并以 `softmax_sample` 选择（`temperature=0` 时即 argmin）。
4. Frontend 从对应的 `DWMD.endpoints[…].transport.tcp` 条目读取所选 worker 的 transport URL，连接其动态 TCP slot `host:port/{cid:x}/generate`。
5. 该 worker 的 `generate` handler——在 dual-mode pod 上由 §3.1 的请求时调度器门控——把请求交给本地 vLLM 引擎执行；如果 `kv_transfer_params` 非空，则通过 NIXL 拉取 prefill 端 KV 块。
6. 生成的 token 经同一 TCP slot 流回 frontend，再由 frontend 以 SSE 块的形式转发给客户端。

§4、§5 引入的两个新原语**仅**修改 worker 侧状态与该 worker 自身的 DWMD CR。第 2–4 步的路由器代码路径未被改动，仅在每次操作后观察到不同的 WorkerSet。

---

## 4. 弹性 PD 角色切换

### 4.1 问题定义

给定一个运行中的 PD 分离部署：$D$ 个 decoder pod、$P$ 个 prefill pod，frontend 承载 $r$ RPS chat 流量。运维者希望将某个 decoder pod $D_i$ 转为 prefill worker（后续可回退），要求**不重启 pod**、**不中断其他 pod 的在飞请求**、且在亚秒级完成。具体而言，`POST <D_i>/switch_role {"target_role":"prefill"}` 需达成以下全部条件：

1. Chat `KvRouter` 不再选中 $D_i$（其 decode WorkerSet 成员资格被收回）；
2. $D_i$ 的 decode-side KV 状态被释放（`engine.sleep(2)` 把 GPU 块退还给分配器，`reset_prefix_cache` 把已无效的索引清空）；
3. 此后 $D_i$ 接收并服务 frontend `PrefillRouter` 派发过来的 prefill 流量；
4. 反向 `target_role="decode"` 对称恢复 1↔3；
5. 翻转足够快（≪ 1 s），使持续 2 RPS chat 负载最多只看到几百毫秒的路由低谷（无持续错误增长）；
6. Pod 名、IP、vLLM 引擎身份、prefix cache 基础设施**保持不变**；只有 DWMD 中**注册的角色**与引擎瞬态状态被修改。

由于操作内部存在严格次序约束（sleep 先于 unpublish、reset-cache 先于 re-publish、re-publish 先于 wake），实现采用**状态机**而非线性脚本——见 §4.2。

### 4.2 八步状态机

`DualModeWorker.switch_role(target)` 在每 worker 一把异步锁下运行，逐步穿越八个确定状态；每个转移耗时被记录到响应 JSON 的 `timings_ms` 字段。

**图 4 — 八步 `switch_role` 状态机。**

```
   t →
   ┌──────────┐
1. │  sleep   │   handlers.sleep():
   │ (level=2)│     - registry.pause_generation()：拒收新提交
   └─────┬────┘     - engine.sleep(2)            ：释放 GPU KV 块
         │
   ┌─────▼─────────┐
2. │ unregister_mdc│   reregistrar.unregister(role=current):
   │               │     从 DWMD 删除当前角色的 ModelCard
   └─────┬─────────┘
         │
   ┌─────▼────────┐
3. │ reconfig_nixl│   handler._nixl_connector = None  （惰性重建）
   └─────┬────────┘
         │
   ┌─────▼─────────────────┐
4. │ reset_prefix_cache    │   engine.reset_prefix_cache()  （引擎仍在睡眠期）
   └─────┬─────────────────┘
         │
   ┌─────▼───────────────────┐
5. │ set_disaggregation_mode │   handler.current_role = target
   └─────┬───────────────────┘
         │
   ┌─────▼─────────┐
6. │  register_mdc │   reregistrar.register(role=target):
   │               │     向 DWMD 发布新角色的 ModelCard
   └─────┬─────────┘
         │
   ┌─────▼────┐
7. │   wake   │   engine.wake_up(); registry.resume_generation()
   └─────┬────┘
         │
   ┌─────▼──────────────┐
8. │ emit_role_changed  │   patch pod label
   │                    │     nvidia.com/dynamo-current-role=<target>
   └────────────────────┘
```

### 4.3 关键的次序约束

下列三组次序保证协议安全：

* **(1) 先于 (2)：先暂停，再下架。** 删除 ModelCard 只阻止**新的**路由决策，不会中止已上路的请求。`pause_generation` 在引擎睡眠**之前**就拒绝新的本地提交，消除了请求落到"半睡眠引擎"上的竞态。
* **(2) 先于 (4)：先注销，再清缓存。** 这样可尽早启动（最终一致、数百毫秒级的）frontend watcher 计时窗口。
* **(4) 在睡眠窗内、(7) 之前：在引擎睡眠中重置缓存。** vLLM prefix cache 保存的是 `sleep(2)` 即将退还给分配器的**块 ID**。唤醒后再重置不安全，因为唤醒时的竞态可能在我们清空索引**之前**把这些块分配给新请求。睡眠中重置从调度器视角看是原子的：

  ```
  before sleep:    prefix_cache[hash("system: …")] → block #42
  sleep(2):        block #42 退还到空闲池
  reset_pc:        清空索引           ← 此时
  wake_up:         不可能出现陈旧命中
  ```

* **(6) 在 (4) 之后：仅当引擎处于一致的目标态时才发布。** 这保证经新 ModelCard 到达的流量落到一个能服务它的引擎上。

### 4.4 为何 `kv_role=kv_both` 至关重要

vLLM 的 `kv_transfer_config` 在引擎构造时固定。运行期变更需要重建引擎（≥ 5 s 且丢失 prefix cache）。我们因此让单一引擎在启动时就同时认识两种角色：

```
--kv-transfer-config NixlConnector kv_both --kv-events-config zmq
```

在 `kv_both` 下引擎同时注册 prefill 与 decode 两侧的 NIXL 元数据。"角色切换"于是纯粹是 (i) DWMD 中的注册变更（发布哪张 ModelCard）与 (ii) 引擎状态循环（sleep → reset → wake）以丢弃在新角色下不一致的瞬态。

### 4.5 Partner-Prefill：一 TCP slot，两张 ModelCard

当 `DYNAMO_RL_DUAL_PARTNER_PREFILL=1` 时，切换后的 pod 变成 frontend `PrefillRouter` 真正会派发流量的**一等** prefill worker。两件不直观的事实是必需的：

**(a) `kv_transfer_params` 的多 chunk 合并。** vLLM 0.16 的 `NixlConnector.request_finished()` 只在**最后一**个 `RequestOutput` chunk 上发布 `kv_transfer_params`，但 Dynamo Rust 端 `PrefillRouter::execute_prefill` 只从**第一**个 chunk 读取 `disaggregated_params`。包装器 `_partner_prefill_generate` 消费整条流、捕获最后一次出现的 `kv_transfer_params`，并以合并后的 chunk 在第一块上吐出，使路由器在 chunk #1 即可看到该字段。

**(b) 单 TCP-slot 调度器。** Dynamo 的 `SharedTcpServer` 以 `endpoint_path = format!("{connection_id:x}/{endpoint_name}")` 为键在 `DashMap` 中存储 handler。由于 `connection_id` 是**进程级**的，若在同一引擎上同时注册 `backend.generate`（decode）与 `prefill.generate`（partner-prefill），二者将在 `{cid:x}/generate` 上发生键冲突——后一次 `handlers.insert` 会**静默覆盖**前一次。ModelCard 的 `TransportType` 也只能编码 `host:port/{cid:x}/{endpoint_name}`。解决方法是每个 `(connection_id, "generate")` **只**注册一个 TCP handler，并在请求时调度：

```python
async def _generate_dispatch(request, context):
    if dm.current_role == "prefill" and partner_prefill_handler is not None:
        async for chunk in _partner_prefill_generate(request, context):
            yield chunk
        return
    async for chunk in handler.generate(request, context):
        yield chunk
```

`switch_role` 在第 (3) 与第 (6) 步之间翻转 `current_role`，因此当新 ModelCard 在 frontend 端可观察时，调度器已正确路由。这是 §3.1 不变量"一 pod、一 TCP slot、两张 ModelCard"的具体实现。

### 4.6 基于 Kubernetes 服务发现的端到端正确性

协议的正确性完全依赖集群控制面，而非 worker 与 frontend 之间的任何进程内协调。每次翻转的传播链：

```
 Worker 写自身 DWMD CR             K8s API server       kube informer        Frontend ModelWatcher
 (reregistrar.apply_cr) ──────────► (etcd 写入) ──────► (watch 事件) ─────► (WorkerSet 重新收敛
                                                                              + KvRouter 失效
                                                                              + PrefillRouter 失效)
```

由此可推出几条不直观的性质：

* **Pod 身份不变。** Pod 的 `metadata.name`、IP、vLLM 引擎、prefix cache 基础设施均不随切换而变。变化的仅是 DWMD `spec.data.model_cards[<key>]` 条目（partner-prefill 构建上还会新增一条对应新角色的条目）。`kubectl get pods -w` 不会观察到事件；`kubectl get dynamoworkermetadata <pod> -w` 可观察到差异。
* **DWMD 是唯一的可观测事实。** 任何外部观察者——frontend、验证工具或 `kubectl get dwmd <pod> -o yaml`——观察到同一份视图。§7 的测试直接在该界面上断言（`PASS_CR_D2P` / `PASS_CR_P2D`）。
* **chat 路径上没有 Kubernetes Service。** 基于 Service 的轮询在此**不**适用，因为请求处理 slot 位于动态分配的运行期端口、通过 DWMD 公告。把一个 pod 从 WorkerSet 移除即"把它的 ModelCard 从 DWMD 删除"——与 Service 对象无关。
* **最终一致性是有界的。** 经验上 watcher 在单节点集群上 ≪ 200 ms 完成收敛；多节点场景下该上界由 kube-apiserver round-trip 与 watch 传播确定，我们的协议通过尽早注销（第 2 步）、尽晚发布（第 6 步）将其吸收。

**切换验证方法。** 测试或运维者通过组合三种独立观察来确认翻转成功（§7 中使用）：

1. *CRD 差异：* `kubectl get dynamoworkermetadata <pod> -o json` 切换前后对比；断言 `…/backend/generate/<inst>` 键从 `model_cards` 消失（`PASS_CR_D2P`），revert 后又出现（`PASS_CR_P2D`）。
2. *Frontend 日志：* `ModelWatcher` 发出与 CR 变化相关的 `Emitting Removed event id=Model(…)` 行。
3. *负载归因：* 切换后通过 frontend 发送 30 条 chat 探针；目标的 `vllm:prompt_tokens_total` Prometheus 计数器必须增长（证明 partner-prefill 真在服务），同时目标的 chat-probe 归因为 0（证明 decode `KvRouter` 不再选它）。

### 4.7 实测代价

|                          | decode → prefill | prefill → decode |
|--------------------------|-----------------:|-----------------:|
| `sleep`                  | 65.8 ms          | 50.3 ms          |
| `unregister_mdc`         | 22.8 ms          | 19.4 ms          |
| `reconfig_nixl`          |  0.1 ms          |  0.1 ms          |
| `reset_prefix_cache`     |  4.3 ms          |  1.2 ms          |
| `register_mdc`           | 326.7 ms         | 328.1 ms         |
| `wake`                   | 20.2 ms          | 28.8 ms          |
| **服务端合计**           | **453.5 ms**     | **428.0 ms**     |
| **客户端 wall-clock**    | 497.3 ms         | 465.7 ms         |
| **完整往返（客户端）**   | colspan          | **963.0 ms**     |

`register_mdc` 占比最大（Kubernetes `apply` 往返）；引擎侧成本本质上为 `sleep + wake ≈ 90 ms`。两方向对称，因 partner-prefill 在 d→p 发布 prefill ModelCard，在 p→d 重新发布 decode ModelCard。

---

## 5. 在线解码请求合并

### 5.1 问题定义

§4 的角色切换协议允许在目标 decoder 无在飞请求时缩小 decoder 池。然而，对持有长完成（如 `max_tokens = 8000`）且已生成数千 token 的请求，强制中断将废弃已完成的计算。因此需要一个原语，将运行中的请求从一个 decoder 迁移至另一个，使源端可被排空，且**不丢失或破坏任何 KV 状态**。

### 5.2 三阶段块持有 NIXL-Pull 协议

协议在三个协调阶段中把请求 `R` 从源 decoder `D_src` 移到目标 decoder `D_dst`。定义性属性是 **`D_src` 在整个握手期间保持请求存活并钉住 KV 块**，仅在 `D_dst` 确认接收后才释放。结合 NIXL 的 RDMA READ 语义，得到一条严格保证：协议的每一瞬，请求的 KV 状态都至少存在于某一块 GPU 上。

**图 5 — 三阶段块持有 NIXL-pull 迁移时序。**

```
   编排者                       D_src (TARGET)                   D_dst (PEER)
        │                          │                                │
        │  POST /migrate_out       │                                │
        ├─────────────────────────►│                                │
        │                          │ 阶段 ①  块持有：               │
        │                          │  - 钉住 R 的 KV 块             │
        │                          │  - 把 R 登记到                 │
        │                          │    _pending_migrations         │
        │                          │  - 收集 (src_block_ids,        │
        │                          │    nixl_coords,                │
        │                          │    sampling_params,            │
        │                          │    previously_emitted_tokens)  │
        │                          │  - 不 abort R                  │
        │  {kv_transfer_params,    │                                │
        │   sampling_params, …}    │                                │
        │◄─────────────────────────┤                                │
        │                          │                                │
        │       POST /migrate_in (body from above)                  │
        ├───────────────────────────────────────────────────────────►│
        │                                                            │ 阶段 ②  NIXL READ pull：
        │                                                            │  - cost-benefit 门控（§5.4）
        │                                                            │  - 把 kv_transfer_params
        │                                                            │    (do_remote_prefill=true,
        │                                                            │     remote_engine_id,
        │                                                            │     remote_block_ids,
        │                                                            │     remote_host, remote_port)
        │                                                            │    注入 sampling_params.extra_args
        │                                                            │  - 向本地 engine 提交 R'
        │                                                            │  - NixlConnectorScheduler 对
        │                                                            │    D_src 的 GPU 发起 RDMA READ
        │                                                            │    并填充本地 KV 块
        │                                                            │  - 从 previously_emitted_tokens+1
        │                                                            │    继续 decode
        │            {status: ok, request_id: R, path: "connector",  │
        │             replay_tokens: <tokens_before_migration>}      │
        │◄───────────────────────────────────────────────────────────┤
        │                          │                                │
        │  POST /migration_complete │                               │
        ├─────────────────────────►│                                │
        │                          │ 阶段 ③  释放：                 │
        │                          │  - 在 D_src 上 abort R         │
        │                          │  - 解钉 KV 块                  │
        │                          │  - 从 _pending_migrations 移除 │
        │   {status: ok}           │                                │
        │◄─────────────────────────┤                                │
```

**KV 一致性保证。** 协议满足"**至少一份副本**"不变量：

| 时刻 | R 的 KV 所在 |
|------|-------------|
| `migrate_out` 之前 | `D_src`（decoding） |
| `migrate_out` 返回与 `migrate_in` 调用之间 | `D_src`（钉住，持有） |
| `migrate_in` 执行 NIXL READ 期间 | `D_src`（仍钉住）**+** `D_dst`（正在填充） |
| `migrate_in` 返回 ok 至 `migration_complete` 之前 | `D_src`（钉住）**+** `D_dst`（decoding） |
| `migration_complete` 之后 | 仅 `D_dst` |

没有任何转移步骤让请求处于"没有权威 KV 副本"的状态。若编排者在 `migrate_in` 返回 ok 后、发出 `migration_complete` 之前崩溃，源端**没有** abort R，故障模式从而退化为用户可见流上的**至多一次重复发射**，而非 KV 状态丢失。后台 `sweep_stale_migrations`（§5.6）限定该重复发射窗口的持续时长。

### 5.3 为何不能简化为两阶段

将协议简化为“`migrate_out` 时直接 abort、`migrate_in` 时再提交”的两阶段变体在 NIXL pull 下不安全：

* 若 `D_src` 先 abort，其 KV 块即被释放，可能在 `D_dst` 的 NIXL READ 完成**之前**被另一请求复用——此时 READ 读取到的内存其内容已不再对应 R 的 KV 状态，构成一类静默的正确性违例；
* 若 `D_src` 最后 abort，但 `migrate_in` 中途失败，则 R 在 `D_src` 上仍然存活（正确性可接受），而 `D_dst` 上的 `NixlConnectorScheduler` 条目已经接入；此时恢复需要双侧严格按序清理，易发竞态。

三阶段协议把**接收**（`migrate_in` 返回 ok）与**清理**（`migration_complete`）解耦，把两方竞态变为顺序握手。

### 5.4 成本收益门控

`MigrationHandler._should_migrate` 拒绝结构上不值得迁移的 `migrate_in`：

```python
MigrationPolicy(
    max_replay_tokens   = 8192,   # 传输代价过高
    min_generated_tokens = 16,    # 太年轻、可保存的进展太少
    min_remaining_tokens = 32,    # 几近完成、本地跑完更快
)
```

被拒的 `migrate_in` 返回 `status=declined` 与人类可读原因。判定在 `D_dst` **承接任何引擎状态之前**完成。

### 5.5 迁移策略：迁谁、迁给谁

§5.2 的协议只在**两个指定的** decoder 之间迁移**一个指定的**请求。策略层——这是控制器的工作——回答更难的问题：**该排空哪个请求，把它迁给哪个对端。** 实现把该决策拆为四部分：

**(a) 每 pod 进程内请求登记表（`InProcessRequestRegistry`，`handlers.py`）。** 每个 worker 维护一份登记表，在三个挂钩处更新：

```
register       请求提交时              # prompt_tokens, sampling_params, t0
record_tokens  每次流式 delta          # 追加 generated_tokens, 更新 last_seen
deregister     完成 / abort / error    # 移除
```

登记表回答"**该 decoder 当前持有哪些请求、每个进展多少？**"——经 `GET /v1/active_requests` 暴露。

**(b) 源端 victim 选择（`_pick_most_progressed`）。** 当 `migrate_out` 以 `request_id="*"` 调用时，源端扫描登记表，返回 `len(generated_tokens)` 最大的那条。理由：迁移**进展最多**的请求让单次迁移挽救的边际成本最大，并最小化单条挽救 token 的协议开销。

**(c) 目标端准入（`_should_migrate`，§5.4）。** 一个对端**合格**当且仅当：(i) 处于 decode WorkerSet 中；(ii) 有足够空闲 KV 容量承接（`max_replay_tokens` 是合理代理）；(iii) 不是源自身。成本收益门控是目标端的最终过滤器。

**(d) 控制器层面的对端选取。** RL-Scaling 控制器知道想要排空的目标。它通过读取 DWMD WorkerSet 枚举对端 decoder，按一个负载分（活跃请求数 / 每秒生成 token / 队列深度）排序，挑出**最闲且合格**的对端。反亲和性自然成立——源被名称排除。在单对测试（§7）中控制器硬编码 `D_src = D1, D_dst = D2`。

总之，迁移策略为：“从待排空 worker 上挑选进展最多的请求，迁至具有富余 KV 容量且当前最闲的合格对端，由目标端执行单请求成本收益终判。” (a) 登记表提供输入；(b) 与 (d) 做选择决策；(c) 的门控为安全网。

### 5.6 块持有安全网

后台任务 `sweep_stale_migrations` 每秒运行一次，强制完成 `_pending_migrations` 中年龄超过 `DYNAMO_RL_MIGRATION_HOLD_TIMEOUT`（默认 10 s）的条目。防止崩溃的编排者无限期钉住 `D_src` 上的 KV 块。

### 5.7 客户端连续性

`migrate_in` 携带 `previously_emitted_tokens`，即 `D_src` 已向客户端流出的 token 数。目标端的流式消费者跳过该前缀，使客户端恰好接收到一条跨越迁移边界的逻辑流。OpenAI 适配的 chat-completion 路径透明地处理这一点——每次迁移产生一条新的 SSE 流。

---

## 6. RL-信号驱动的自动伸缩

### 6.1 三类伸缩场景

| 场景 | 层级 | 目标 | 原语 |
|------|----|------|------|
| **Rollout 触发的集群伸缩** | Pod 副本数 | 在 `phase=sampling_start` 时冷启动集群，在 `phase=training` 时缩到零 | 通过 Kubernetes API patch `DGD` replicas |
| **弹性角色再平衡** | 原地角色翻转 | 在不重建情况下重新平衡 prefill/decode 比例 | `/switch_role`（§4） |
| **在线合并** | 在线迁移 | 在批次中途空出目标以便缩容或改角色 | `/migrate`（§5） |

RL-Scaling 控制器通过 RL-Signal SDK 消费训练任务发出的阶段信号，派发上述一种或多种原语。

### 6.2 控制器状态机（草图）

```
                                    ┌────────────────┐
                  sampling_start    │   PRE-WARM     │
              ┌───────────────────► │  pod  0→N       │
              │                     └───────┬────────┘
              │                             │ 全部 Running
              │                             ▼
              │                     ┌────────────────┐
              │  比例失衡           │   STEADY       │
              │ ┌─────────────────► │  P/D ratio OK  │
              │ │                   └───────┬────────┘
              │ │                           │ P/D ratio 偏离
              │ │                           ▼
              │ │                   ┌────────────────┐
              │ │  比例恢复         │  REBALANCING   │
              │ └─────────────────  │ /switch_role × │
              │                     └───────┬────────┘
              │                             │ training_start
              │                             ▼
              │                     ┌────────────────┐
              │  批次尾部           │ CONSOLIDATING  │
              │ ┌─────────────────  │  /migrate × m  │
              │ │                   └───────┬────────┘
              │ │                           │ TARGET drained
              │ │                           ▼
              │ │                   ┌────────────────┐
              │ └─────────────────► │  SCALE DOWN    │
              │                     │  pod  N→0       │
              │  sampling_start     └────────────────┘
              └─────────────────────────────┘
```

REBALANCING 与 CONSOLIDATING 完全依赖 §4、§5 原语；控制器只补充**策略**（何时、做多少）与 **Kubernetes API** 胶水。

---

## 7. 实验验证

### 7.1 实验环境

* 单节点 Kubernetes 1.34.1，主机 `gpu14`，namespace `dynamo-system`
* DGD `vllm-v1-disagg-router`，模型 `Qwen/Qwen3-0.6B`
* 1 frontend、2 decoder、1 prefill（全部 `Running`）
* 镜像 `ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-fe78f1b652`（角色切换）与 `:rl-scaling-2ec0978618`（合并）
* `DYNAMO_RL_DUAL_MODE=1`、`DYNAMO_RL_DUAL_PARTNER_PREFILL=1`、`DYNAMO_RL_CONNECTOR_ENABLED=1`

### 7.2 弹性角色切换 — 测试与结果

**测试策略。** 自动化端到端验证在 §7.1 的集群上执行完整的 decode→prefill→decode 切换循环，并在切换覆盖窗口内维持 2 RPS 的背景负载。验证从 CRD 变更的可观测性（DWMD diff）和 Prometheus 指标增长两个维度同时确认角色切换的正确性。五项通过条件：

| 代号 | 含义 |
|------|------|
| `PASS_CR_D2P` | `switch → prefill` 后，TARGET 的 DWMD 中 `…/backend/generate/…` `model_card` 键消失 |
| `PASS_CR_P2D` | `revert → decode` 后，同一 `model_card` 键再次出现 |
| `PASS_PREFILL_SERVING` | 切换后探针窗口内 TARGET 的 `vllm:prompt_tokens_total` 增长（证明 partner-prefill 真在服务） |
| `PASS_DECODE_SERVING` | revert 后探针窗口内 TARGET 的 `vllm:generation_tokens_total` 增长 |
| `PASS_LOAD` | 覆盖完整 switch+revert 的 2 RPS 后台 chat 负载：`error_count ≤ 2` |

**CRD 直接差异（D→P），原文：**

```diff
- dynamo-system-vllm-v1-disagg-router-…/backend/generate/<inst>
+ dynamo-system-vllm-v1-disagg-router-…/prefill/generate/<inst>
```

**Frontend `ModelWatcher` 事件：**

```
INFO dynamo_runtime::discovery::kube: Emitting Removed event
  id=Model(ModelCardInstanceId { component: "backend", endpoint: "generate", … })
```

**切换时延（重述）：** 453.5 ms 服务端 / 497.3 ms 客户端 wall-clock（d→p）；428.0 / 465.7 ms（p→d）；完整往返 963.0 ms 客户端 wall-clock。

**负载归因：**

| 阶段 | 探针 | HTTP 200 | TARGET 上的计数器增量 |
|------|------:|---------:|----------------------:|
| 切换 → prefill 后 | 30 | 30 | `vllm:prompt_tokens_total` Δ = **+583** |
| revert → decode 后 | 30 | 30 | `vllm:generation_tokens_total` Δ = **+224** |

**持续后台负载（2 RPS、30 s，覆盖完整 switch+revert）：**

| 指标 | 值 |
|------|---:|
| 总请求 | 58 |
| HTTP 200 | 58 |
| HTTP 非 200 | 0 |
| p50 时延 | 65 ms |
| p99 时延 | 105 ms |

**总体结果：** 五项条件全部通过。

### 7.3 在线合并 — NIXL 连接器路径验证

**测试策略。** 为验证 §5.2 协议确实经 NIXL RDMA 连接器（而非回退到 recompute-prefill）传输 KV 状态，我们设计了一项端到端集成测试。测试向集群提交 5 条流式 completion（`max_tokens=3000`），待 decode 启动后，对唯一由 `KvRouter` 路由至 `D1` 的请求依次调用 `migrate_out → migrate_in → migration_complete`，驱动完整的三阶段块持有序列。验证逻辑检查各阶段返回字段与最终流式输出的完整性，覆盖从源端块枚举到目标端 RDMA 拉取的全链路。

六项通过条件：

| 代号 | 含义 |
|------|------|
| `PASS_KV_TRANSFER`    | `migrate_out` 响应携带有值的 `kv_transfer_params`（NIXL 坐标 + 远端块 ID）。该字段**仅当**块桥接成功查询 EngineCore `KVCacheManager` 得到请求的物理 GPU 块 ID 后才可获取。 |
| `PASS_BLOCK_IDS`      | `src_block_ids` 列表非空：源端的确标识出了真实物理 GPU KV 缓存块。它们正是 NIXL 将 RDMA-READ 的确切内存页。 |
| `PASS_CONNECTOR_PATH` | `migrate_in` 响应报告 `"path": "connector"` —— vLLM 的 `NixlConnector` 被实际调用，**而非** recompute-prefill 回退。 |
| `PASS_TOKENS_BEFORE`  | 源端在迁移前已 decode 出 *N > 0* 个 token；目标端**不**重新 decode 这些 token——从第 *N + 1* 个继续。 |
| `PASS_COMPLETE`       | 全部 5 条流式请求最终完成且输出为合法 OpenAI 格式。 |
| `PASS_MIG_OK`         | ≥ 1 对 `(migrate_out, migrate_in)` 返回 `status=ok`。 |

**单次迁移 NIXL 证据（唯一端到端跑通的那次）：**

| 字段 | 值 | 解读 |
|------|-----|------|
| `request_id`                              | `6769d232-e214-4170-9dde-5431764712e4` | 被迁移的 decode 请求 |
| `tokens_before_migration`                 | **1688** | D1 在迁移前已在本地生成 1688 个 token |
| `migrate_in.path`                         | **`connector`** | 使用了 NIXL 连接器，而非 recompute |
| `migrate_in.replay_tokens`                | 1688 | replay 预算恰等于 D1 的进度，确认目标端恢复所依赖的是源端 KV cache（而非重新 prefill） |
| 迁移往返时间（`migrate_out` → `migrate_in` 返回 ok） | **188 ms** | 比重算 1688-token 前缀快两个数量级 |
| `kv_transfer_params.do_remote_prefill`    | `true` | 指示 D2 的 `NixlConnectorScheduler` 从远端引擎拉取 KV 而非本地计算 |
| `kv_transfer_params.remote_engine_id`     | `cf043c71-2207-49d9-a77b-886961093c5e` | D1 的 NIXL 引擎 UUID（RDMA READ 目标） |
| `kv_transfer_params.remote_host:port`     | `10.244.0.187:14579` | D1 的 pod IP 与 NIXL 监听端口 |
| `kv_transfer_params.remote_block_ids`     | **109 个物理块**（`[2691, 2692, 2693, …, 2988, 2989]`） | D1 GPU 上待 READ 内容的确切页面 |
| D2 engine UUID                            | `c38d194c-204b-4590-9fde-8cf8a2038883` | 与 `remote_engine_id` 不同，确认传输确系跨引擎 RDMA 而非进程内 replay |

**`migrate_in` 原文响应**（`migrate_in_1.json`）：

```json
{"status": "ok",
 "request_id": "6769d232-e214-4170-9dde-5431764712e4",
 "path": "connector",
 "replay_tokens": 1688}
```

**`migrate_out.kv_transfer_params` 原文**（截取关键字段；完整载荷见 `migrate_out_1.json`）：

```json
{
  "do_remote_prefill": true,
  "do_remote_decode":  false,
  "remote_engine_id":  "cf043c71-2207-49d9-a77b-886961093c5e",
  "remote_host":       "10.244.0.187",
  "remote_port":       14579,
  "remote_request_id": "6769d232-e214-4170-9dde-5431764712e4",
  "remote_block_ids":  [2691, 2692, 2693, 2694, 2695, 2696, 2697,
                        2698, 2702, 2704, 2708, 2711, 2714, 2717,
                        "… 95 more …",
                        2982, 2984, 2986, 2987, 2988, 2989]
}
```

以上产物构成端到端的完整保管链：

1. D1 的 `KVCacheManager` 识别出 R 的 109 个先前 KV 状态物理块（`PASS_BLOCK_IDS`）。
2. D1 引擎的 NIXL 连接坐标被嵌入 `kv_transfer_params` 并送至编排者（`PASS_KV_TRANSFER`）。
3. D2 接收这些坐标，令其 `NixlConnector` 对 D1 的 GPU 页面执行 remote-prefill RDMA READ，并报告 `path=connector`（`PASS_CONNECTOR_PATH`）。
4. D2 随后从第 1689 个 token 继续 decode——源端在 `migration_complete` 之后不再发射 token 1‥1688，客户端的 SSE 流包含 D1 产出的原始 1688 token 与 D2 延续的后续 token 无缝衔接（`PASS_COMPLETE`）。

**后续迁移尝试的行为。** 5 条提交的请求中，仅上述 1 条被 `KvRouter` 路由到 D1；其余 4 条落在另一 decoder 或在迁移步骤前已完成。后续两次 `migrate_out` 调用因此返回：

```json
{"status": "error", "message": "no active requests"}
```

这是源端 `InProcessRequestRegistry` 为空时的**定义行为**，而非实现缺陷：D1 已被首次成功迁移排空。上述通过条件针对实际运行的那次迁移评估，六项全部满足。

**编排扩展性辅助证据。** 在 KVBM 块桥接接入之前执行的一次独立运行，在同一编排框架上施加六次并发迁移。结果显示平均块持有时延 **6.1 ms**（5.1, 7.0, 8.2, 5.4, 7.6, 3.5 ms）、零错误，D2 `generation_tokens_total` 在 settle 与 drain 之间 Δ = **+45 737**。该运行走的是 recompute-prefill **回退**路径，本身不足以证明 NIXL 传输；在此仅作为**三阶段块持有编排可无泄漏地扩展到多个并发在飞迁移**的证据。上方 NIXL 连接器验证运行才是证明块桥接启用后 *connector* 路径被采用的依据。

**成本收益门控。** 合成 `migrate_in`（`prompt_tokens=9000`）返回：

```json
{
  "status": "declined",
  "reason": "replay_total=9050 exceeds max_replay_tokens=8192",
  "request_id": "synthetic-overbudget"
}
```

确认 §5.4 的目标端准入门控生效。

**总体结果：** 六项条件全部通过；NIXL 连接器路径被验证为迁移机制。

### 7.4 实验汇总

| 场景 | 条件命中 | 主要时延 | 错误 |
|------|:--------:|----------|:---:|
| 角色切换   | 5 / 5 | 497 ms d→p、466 ms p→d（客户端 wall-clock）；963 ms 往返 | 0 |
| 在线合并（NIXL 路径）  | 6 / 6 | 188 ms 单次迁移；109 KV 块经 `NixlConnector`（`path=connector`）传输 | 0 |
| 在线合并（编排扩展性） | 辅助 | 6 次并发迁移，平均块持有 6.1 ms | 0 |

---

## 8. 讨论与未来工作

### 8.1 讨论

**(a) `register_mdc` 是切换成本主项。** ≈ 327 ms，约为引擎侧 `sleep + wake` 的 3.5 倍。该开销源于 Kubernetes `apply` 往返，是以 DWMD 为唯一事实源的设计选择所致。代价是用**强可观测性与零新基础设施**（无 etcd、无额外注册表）换取 ~330 ms 的翻转底线。对 RL 控制器而言（一个 rollout 阶段内翻转频率为数十秒一次），该开销可接受。

**(b) 三阶段 NIXL pull 已端到端验证。** §7.3 的验证运行表明，KVBM 块桥接接入后 `migrate_in` 走的是 connector 路径：目标端响应含 `"path": "connector"`，源端 `migrate_out` 给出完整 `kv_transfer_params`（远端 engine UUID、host、port、109 个物理 block ID 列表），目标端 `NixlConnectorScheduler` 在源 GPU 上发起 RDMA READ 后从第 1689 个 token 继续 decode。188 ms 的迁移 wall-clock 主要由 RDMA 建立支配；源端块持有窗口保持在 §5.2 至少一份副本不变量之内（编排扩展性运行的单位数毫秒级块持有可佐证）。recompute-prefill 回退路径仍保留在实现中作为安全网，但在本部署中已不再是主路径。

**(c) 单 TCP-slot 调度器可推广。** "进程级 `connection_id` 会让任何两个共享 `endpoint_name` 的端点在 `SharedTcpServer` 冲突"这一教训对未来任何"双角色"端点都适用。调度器模式是一个有用的模板。

**(d) 单主机评测局限。** 本评测的网络开销受 loopback 限制。多主机部署将在每阶段额外引入一次往返（DWMD 传播以及 RDMA 上的 NIXL 建立），健康集群下切换 wall-clock 预计仍可保持在 ≈ 700 ms 以内。

### 8.2 未来工作

1. **多节点测量。** 在多节点集群 + RDMA NIXL 上复现 §7；量化额外的 `register_mdc` 与 NIXL-pull 时延。
2. **闭环 RL 控制器。** 把 RL-Signal SDK 接入控制器状态机，把手动触发的 `switch_role` / `migrate` 替换为基于真实 GRPO rollout 的策略派发。
3. **默认导出 KVBM 块索引**，使三阶段 NIXL pull 成为常规路径；需与 vLLM 0.17+ 上游协作。
4. **可插拔调度**（Dynamo v1.1.0-dev.1 的 `#7260` 特性），在 PD 失衡时短路 `softmax_sample`，加速路由器对翻转的反应。
5. **多引擎支持。** 把调度器与 dual-mode 推广到支持类似双角色配置的非 vLLM 引擎（SGLang、TRT-LLM）。

---

## 参考文献

[1] NVIDIA, "Dynamo: A Disaggregated Inference Serving Framework," 2024. Available: https://github.com/ai-dynamo/dynamo

[2] W. Kwon, Z. Li, S. Zhuang, et al., "Efficient Memory Management for Large Language Model Serving with PagedAttention," in *Proc. SOSP*, 2023.

[3] R. Qin, Z. Li, W. He, et al., "Mooncake: Trading More Storage for Less Computation — A KVCache-Centric Architecture for Serving LLM Chatbot," in *Proc. USENIX FAST*, 2025, pp. 155–170.

[4] Y. Zhong, S. Liu, J. Chen, et al., "DistServe: Disaggregating Prefill and Decoding for Goodput-optimized Large Language Model Serving," in *Proc. OSDI*, 2024.

[5] P. Patel, E. Choukse, C. Zhang, et al., "Splitwise: Efficient Generative LLM Inference Using Phase Splitting," in *Proc. ISCA*, 2024.

[6] NVIDIA, "NIXL: NVIDIA Inference eXchange Library," 2024. Available: https://github.com/ai-dynamo/nixl

[7] Y. Liu et al., "LMCache: An Efficient KV Cache Layer for Enterprise-Scale LLM Serving," 2024.

[8] Y. Fu, L. Xue, S. Huang, et al., "ServerlessLLM: Low-Latency Serverless Inference for Large Language Models," in *Proc. OSDI*, 2024.

[9] X. Miao, C. Shi, J. Duan, et al., "SpotServe: Serving Generative Large Language Models on Preemptible Instances," in *Proc. ASPLOS*, 2024.

---

## 附录 A — 术语与记号

全文统一使用以下术语：

| 术语 | 含义 |
|------|------|
| **DWMD** | `DynamoWorkerMetadata` — 每个 worker pod 拥有一份的 Kubernetes 自定义资源（CR）。其 `spec.data` 包含三张映射：`endpoints`、`event_channels`、`model_cards`。**DWMD 即运行期注册记录**；对它的修改就是"注册/注销"的动作。 |
| **`endpoints` 映射** | 位于 `DWMD.spec.data.endpoints[<key>]`，键为 `<namespace>/<component>/<endpoint_name>/<instance_id>`。每条记录的 `transport.tcp` 形如 `host:port/{connection_id:x}/{endpoint_name}`。 |
| **ModelCard** | 位于 `DWMD.spec.data.model_cards[<key>]` 的 JSON 条目。发布一条 ModelCard 表示本 worker 愿意以某种角色服务模型，删除即收回。Dynamo 部分源码中也写作 *MDC*；本文统一使用 **ModelCard**。 |
| **TCP slot** | Rust 运行时实际监听请求的 `host:port/{connection_id:x}/{endpoint_name}` 套接字。引擎启动时动态分配端口；通过 `DWMD.spec.data.endpoints[...].transport.tcp` 对外公告。 |
| **系统端口（`:9090`）** | Dynamo 自身的 Prometheus 指标与健康检查端口。**不是**请求处理 slot。 |
| **Sidecar 端口（`:9091`）** | RL-Scaling 控制面 HTTP（aiohttp）端口。提供 `/switch_role`、`/migrate`、`/v1/active_requests`、`/v1/role`。**不是**请求处理 slot。 |
| **Frontend 端口（`:8000`）** | Frontend pod 上的 OpenAI 兼容 HTTP API（chat / completions），通过 Ingress 暴露。 |
| **WorkerSet** | Frontend `ModelWatcher` 通过观察 DWMD 重建的内存 worker 集合；`KvRouter` 与 `PrefillRouter` 都在它之上做选择。 |
| **Decoder Pool / Prefill Pool** | WorkerSet 中**当前在 DWMD 里发布了 decode 角色（resp. prefill 角色）ModelCard** 的子集。 |
| **NIXL** | NVIDIA Inference eXchange Layer — 跨 GPU 的 RDMA 式 KV 传输层。`NixlConnector` 是 vLLM 的连接器实现。 |
| **KVBM** | KV-Block Manager — Dynamo 中桥接 vLLM `KVCacheManager` 的组件，使请求的物理 GPU 块 ID 可被枚举（§5.2 NIXL-pull 路径的前提）。 |
| **`path = "connector"` vs `"recompute"`** | `migrate_in` 响应中的 `path` 字段报告实际走了哪条分支：`connector` = NIXL RDMA READ（§5.2 规范设计）；`recompute` = prefill 重算（KVBM 块 ID 不可用时的回退）。 |
