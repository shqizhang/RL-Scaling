# 四场景一致性测试结果分析（2026-07-11 干净镜像轮次）

数据目录：`test-scripts/reports/strategy-four-scenario-20260711-173142`

镜像与部署（本轮全部为正规构建镜像，无 ConfigMap overlay）：

- Worker：`ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-51e64d5-nixlfix`
- Controller：`ghcr.io/shqizhang/rl-scaling-controller:9120900`
- RBAC：`04-worker-role-label-rbac.yaml` 已接入 `deploy-dynamo.sh`，pod label patch 无 403。
- 拓扑管理：operator 保持 0 副本，测试脚本直接管理 worker Deployment（沿用既有模型）。

## 0. 与上一轮（20260706）相比，本轮修复了什么

上一轮的失败大多不是方案本身的问题，而是部署与测试基础设施问题。本轮已全部处理：

1. **镜像 NIXL 损坏**：`cccb9db` 基镜像里混入了错 CUDA 版本的 `nixl-cu13 1.1.0`（运行时是 CUDA 12.9），导致 `libplugin_UCX.so` 加载失败（`undefined symbol`），vLLM `NixlConnector` 无法创建 UCX backend，worker 直接 crashloop。已在薄层镜像里移除 `nixl-cu13`，构建期探针确认 `NIXL UCX backend OK`。
2. **ConfigMap overlay hack**：改用「基于已发布镜像做薄层 + COPY 改动的 .py + 移除坏 wheel」的正规不可变镜像，删除了 `rl-sidecar-main-patch` / `dynamo-block-bridge` 两个 overlay ConfigMap 和 `tmp-*-patch.json`。确认 worker pod 无 overlay volume。
3. **RBAC 403**：manifest 已接入部署脚本，D->P 后 pod label `nvidia.com/dynamo-current-role` 成功更新。
4. **S2 worker 侧一致性**：`dual_mode.py` 在发布 target MDC 前同步更新 `_current_role`，并在 wake 后清理旧 handler endpoint，消除 dispatcher/handler role 不一致窗口。最小 S2 correctness（`run_s2_minimal_e2e.py`）通过：D->P 3P1D、P->D 2P2D、`max_tokens=48` long decode probe 6/6 valid、timeout=0。
5. **native prefill 可观测**：`main.py` 给 native prefill worker 也挂只读 sidecar（`/v1/role`、`/v1/active_requests`），修复 §2.3 的 9091 connection refused。
6. **Controller S2 target 选择 bug（本轮新发现并修复）**：native prefill 现在也有 sidecar，旧的 `switch_capable = role in {...} and active is not None` 把 native prefill 误判为可切换，controller 反复对 native prefill 发 `/switch_role` 得到 503，形成死循环。已改为按 component（只有 `VllmDecodeWorker` 是 dual-mode-capable）判定 `switch_capable`。
7. **测试 harness 稳定性（本轮新增）**：kubectl port-forward 走单条 SSH 隧道，在 S2/S3 per-pod 快照的高频 port-forward 下会掉线，导致控制信号 `sampling_done` 超时并整体崩溃。已让 port-forward 按 local port 注册并在连接级错误时原端口重建；真实 model read-timeout 仍如实记录为数据。

## 1. 核心数据

| 场景 | wall(s) | prefill(s) | balanced(s) | tail(s) | timeout | valid% | GPU-s | tokens/GPU-s | S2 exec | S3 migrated/drained | perf_valid |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline_minimal (1P1D) | 403.4 | 321.3 | 27.3 | 16.3 | 0 | 100.0 | 804.9 | 20.67 | 0 | 0/0 | **true** |
| s2_only (2P2D) | 483.1 | **166.7** | 16.6 | 252.0 | 4 | 96.9 | 1904.4 | 8.64 | 2 | 0/0 | false |
| s3_only (2P2D) | 343.8 | 185.7 | 18.3 | 134.0 | 1 | 99.2 | 1362.3 | 12.18 | 0 | 0/0 | false |
| mixed_strategy (2P2D) | 488.0 | 173.0 | 17.0 | 251.4 | 4 | 96.9 | 1929.4 | 8.52 | 2 | 0/0 | false |

- S2 switch latency：435ms、507ms（D->P、P->D），受控，全程恰好 2 次。
- 所有 tail timeout 都是 `max_tokens=48` 的 `tail_long` 请求（s2/mixed：id 127-130 共 4 个；s3_only：id 130 共 1 个）。

## 2. 正确性

- baseline_minimal：130/130 valid decode，timeout=0，是唯一通过质量门（timeout==0、valid>=99%、5xx==0）的场景，作为 1P1D 资源受限慢基线。
- s2_only / mixed_strategy：各有 4 个 tail timeout，valid=96.9%，质量门失败。
- s3_only：1 个 tail timeout，valid=99.2%，质量门失败。
- S2 动作顺序正确：`decode->prefill` 后 `prefill->decode`，`s2_executed_count=2`，无 churn；S3 全程 `migrated=0/drained=0`，场景隔离正确（s2_only 无 S3、s3_only 无 S2）。

## 3. S2：机制成立，prefill 收益成立，但被 tail 缺陷拖累总体

**成立部分（干净、可复现）：**

- S2 D->P 切换在 preparation window 内完成，router 感知到新的 prefill capacity，`prefill_burst` 全程 0 timeout。
- prefill serving wall：baseline 1P = 321.3s → s2_only(D->P 3P) = 166.7s，**改善 48.1%**。
- 与同为 2P 起点的 s3_only（prefill 185.7s，无切换）相比，S2 再切出第 3 个 prefill 让 prefill wall 又快约 10%（185.7 → 166.7）。
- 本轮 prefill wall 改善在 3 次独立运行中稳定复现（166.7 / 163.3 / 150.7 vs baseline 321 / 301 / 297）。

**归因边界（必须诚实说明）：**

- 「48% vs baseline」里，1P→2P 的拓扑差异贡献了大部分（321 → ~186），S2 的第 3 个 prefill 再贡献约 10%（186 → 167）。要纯粹隔离 S2 收益，需要按 `test-strategy.md §2.4/§11.9` 增加同拓扑 disabled baseline（`baseline_2p2d_disabled`），本轮尚未包含。
- prefill 绝对时长（1P 321s）明显慢于上一轮 overlay 镜像（1P 约 49.6s，同一 workload）。balanced/decode 阶段两轮几乎一致（27/16s），只有 prefill 阶段变慢约 6 倍。怀疑与当前镜像 `cccb9db`（"implement kv trasform"）+ `kv_both` NIXL kv_transfer 的每请求 prefill 开销有关。因 baseline 与 S2 用同一镜像，**场景内相对对比仍然有效**，但跨轮次绝对值不可直接比较，后续应定位该 prefill 变慢原因。

**未成立部分：**

- s2_only 总体 wall 483.1s，比 baseline 403.4s 更差（-19.8%）。原因是 decode_tail 的 4 个 timeout 把 tail wall 从 16s 拉到 252s。这不是 S2 prefill 阶段的问题，而是 P->D 切回后的 decode 缺陷（见 §5）。

## 4. S3：本轮未产生任何 consolidation 证据

- s3_only 与 mixed_strategy 全程 `s3_history=0、attempts=0、migrated=0、declined=0、drained=0`。S3 consolidation **完全没有触发**。
- 报告中 `tail_decode_gpu_s_saved`（s3_only 7.0 / mixed 9.9）与 `savings_pct`（2.6% / 2.0%）只是 `counterfactual - observed` 的公式输出，**不能作为 S3 效能证据**（`migrated=0` 前提下无迁移可言）。s2_only 的该值为 -237.5（负），只反映 tail timeout 把 observed tail GPU-s 放大，与 S3 无关。
- 这与上一轮结论一致：S3 触发是 telemetry-driven 的时机问题（`test-strategy.md §11.10`）。当前 `/v1/active_requests` 只暴露 request id，不暴露 `generated_tokens`/`remaining_tokens` 进度，脚本无法在「已生成一部分、剩余仍足够」的窗口精确触发；固定延迟触发要么请求已近完成、要么 source 上已无 active request。**本轮属于诊断范围之外的已知 gap，未在本轮实现该 sidecar 进度接口。**

## 5. decode_tail 的 P->D 切回 KV 泄漏（本轮定位到的主障碍）

- s2_only / mixed 的 4 个 tail timeout 全部是 `max_tokens=48` 请求，全部 120s 超时无响应（http=0）。
- worker 日志显示 P->D 切回时：`Failed to reset prefix cache because some blocks (694) are not freed yet`。即 `handler.sleep(level=2)` 未完全 drain，`reset_prefix_cache` 无法释放全部 KV block，切回 decode 的 worker 带着泄漏的 block 进入退化状态。
- 路由证据：tail 阶段未切换的 decode worker（j9bbx）完全空闲（Running:0、GPU KV 0.0%），而长 tail 请求被路由到切回的退化 worker 并挂起。即「退化 worker + router 仍向其派发长 decode」双重问题。
- s3_only（无 P->D 切换）仍有 1 个 `max_tokens=48` tail timeout，说明 **dynamic 2P2D 拓扑本身对最长 tail 请求存在不稳定**（`test-strategy.md §7` 的 “dynamic 2D tail timeout”）；S2 的切回把它从 1 个放大到 4 个。

这是本轮明确的下一步修复目标，属 worker 侧较深问题，本轮未修。

## 6. 结论（按 test-strategy.md §9 顺序）

1. **正确性**：仅 baseline 通过 timeout==0 质量门。所有 dynamic 场景因 tail timeout 失败，不能作为 client-visible 端到端性能结论。
2. **S2**：动作发生且受控（2 次，无 churn）；prefill serving wall 相对 baseline 稳定改善约 48%（其中含 1P->2P 拓扑分量与 S2 第 3 prefill 约 10% 分量），prefill 阶段零 timeout。这是本轮唯一干净、可复现、可辩护的正向结果。S2 总体 wall 因 decode_tail 缺陷回退。
3. **S3**：无 migration/drain/consolidation 证据（全 0）。tail GPU-second「节省」为公式产物，不构成 S3 证据。S3 触发机制仍需 telemetry-driven 进度接口。
4. **Mixed**：拿到了 S2 的 prefill 收益，但同样被 decode_tail KV 泄漏拖累，且 S3 未触发，因此不是「组合最佳」。
5. **限制**：拓扑混淆（2P vs 1P baseline）未用同拓扑 counterfactual 隔离；prefill 绝对时长较上一轮镜像明显变慢待查；decode_tail 的 P->D 切回 KV 泄漏与 dynamic-2D tail 不稳定未修；S3 进度接口未实现。

## 7. 建议的下一步（优先级从高到低）

1. **修 P->D 切回 KV 泄漏**：切回前对 in-flight 做确定性 drain，确认 block 全部释放后再 `reset_prefix_cache`；并检查切回后 router 是否应优先把 decode 派发到未切换的健康 worker。修完只需重跑 s2_only 验证 tail timeout=0。
2. **加 `baseline_2p2d_disabled` 同拓扑基线**：把 S2 prefill 收益与 1P->2P 拓扑分量彻底分离；S3 tail GPU-second 也必须对同拓扑 disabled baseline 比较。
3. **定位 prefill 变慢**：对比 `cccb9db`（kv_transfer）与更早镜像的单 prefill 吞吐，确认是否为 `kv_both` NIXL 每请求开销。
4. **实现 S3 进度接口**：`/v1/active_requests` 暴露 `generated_tokens`/`max_tokens`/`remaining_tokens`，脚本在正确窗口触发 consolidation，并保存 migrate_out/migrate_in/complete/rollback 原始响应。
5. 上述修完后再跑完整四场景，方可期待 s2_only/mixed 通过质量门并给出端到端结论。
