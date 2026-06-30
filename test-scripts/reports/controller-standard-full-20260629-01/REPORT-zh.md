# Controller 自动闭环标准流水线测试报告

生成时间：2026-06-29

Controller 镜像：`ghcr.io/shqizhang/rl-scaling-controller:fb8b4fb`

部署方式：GitHub Actions 标准 CI 构建并推送 GHCR，然后在 `gpu14` 上使用 `deploy/apply-controller.sh` 部署。

测试命名空间：controller `dynamo`，Dynamo workload `dynamo-system`。

DGD：`vllm-v1-disagg-router`

模型：`Qwen/Qwen3-0.6B`

## 1. 流水线与部署验证

本次没有使用 ConfigMap overlay 替换 Python 文件，而是按标准流水线完成：

1. 提交 `fb8b4fb Stop repeated S3 migration attempts after decline` 到 `origin/RL-Scaling`。
2. GitHub Actions run `28339304744` 通过：`unit-tests` 通过，`build-controller-image` 成功。
3. CI 推送镜像 `ghcr.io/shqizhang/rl-scaling-controller:fb8b4fb`。
4. 在 `gpu14` 执行标准部署：`IMAGE=ghcr.io/shqizhang/rl-scaling-controller:fb8b4fb NAMESPACE=dynamo ./deploy/apply-controller.sh`。
5. 部署后确认：Deployment image 为 `fb8b4fb`，`Mounts: <none>`，`Volumes: <none>`，说明运行逻辑来自标准镜像，不再依赖旧的 ConfigMap overlay。

controller 单元测试：`65 passed`。其中新增验证：S3 migration 如果收到 `declined/error`，同一 pair 本轮立即停止后续迁移尝试，避免重复 rollback。

## 2. 指标含义

| 指标 | 含义 | 统计边界 | 解读 |
|---|---|---|---|
| completed requests | 客户端成功写入 `requests.csv` 的请求数 | 每个 curl 请求完成后写一行 | 验证 workload 是否完整结束 |
| success % | `HTTP 200 / completed * 100` | Dynamo frontend `/v1/chat/completions` 返回码 | 策略动作过程中服务是否保持正确 |
| wall time | `max(end_ts)-min(start_ts)` | 第一个测量请求发出到最后一个测量请求返回 | 整批请求端到端完成时间，越低越好 |
| req/s | `HTTP 200 / wall time` | 与 wall time 相同窗口 | 用户可见请求吞吐，越高越好 |
| avg latency | 每个请求 curl total time 的平均值 | 单请求发出到完整响应体返回 | 平均用户等待时间 |
| p50 latency | latency 中位数 | 单请求发出到完整响应体返回 | 典型请求延迟 |
| p95 / p99 latency | 95/99 分位 latency | 单请求发出到完整响应体返回 | 长尾延迟，对排队和 straggler 更敏感 |
| TTFT | curl `time_starttransfer` | 请求发出到首字节返回 | 非 streaming 模式下近似首 token / 首字节响应时间 |
| engine gen tok/s | vLLM `generation_tokens_total` delta / wall time | worker metrics 采样前后差值 | engine 侧 decode token 吞吐，可能包含 migration replay token |
| user completion tok/s | HTTP response `usage.completion_tokens` 总和 / wall time | 用户响应 JSON 中的 usage | 用户实际可见输出 token 吞吐，不包含内部 replay |
| replay/overhead tokens | `engine_generation_tokens_delta - user_completion_tokens`，小于 0 时按 0 | worker token counter 与 frontend usage 对比 | 反映 migration/recompute/replay 等内部额外 engine 工作 |
| GPU active sample % | `nvidia-smi utilization.gpu > 0` 的采样占比 | 每个 worker pod 定时 `nvidia-smi` | GPU 是否活跃的粗粒度 proxy |
| GPU effective seconds | `sum(gpu_util_pct/100 * sample_duration)` | 每个 worker pod 的 `nvidia-smi` util 积分 | 粗粒度 GPU effective time；相同 workload 下越低越好 |
| avg GPU util % | GPU util 采样平均值 | 每个 worker pod 定时采样 | 粗略观察 GPU 忙碌程度 |
| max GPU mem MiB | 采样期间最大显存占用 | `nvidia-smi memory.used` | 判断 worker 是否仍占用显存 |

说明：集群中存在 DCGM exporter，但本次 E2E 脚本仍使用 `nvidia-smi` per-pod 采样。因此 GPU effective seconds 是粗粒度 proxy，不是 DCGM busy time 积分。

## 3. S3 Request Consolidation 测试

报告目录：`test-scripts/reports/controller-standard-s3-20260629-01/`

### 3.1 测试策略

Baseline 配置：

- `ROLE_SWITCH_ENABLED=false`
- `CONSOLIDATION_ENABLED=false`

Strategy 配置：

- `ROLE_SWITCH_ENABLED=false`
- `CONSOLIDATION_ENABLED=true`
- `CONSOLIDATION_THRESHOLD=4`
- `CONSOLIDATION_STABLE_SAMPLES=2`
- `CONSOLIDATION_MIN_INTERVAL=10`
- `CONSOLIDATION_SCALE_DOWN_ENABLED=false`

触发逻辑：

1. batch progress 达到 `MIN_BATCH_COMPLETION=0.6`。
2. source decode worker active requests 位于 `1..CONSOLIDATION_THRESHOLD`。
3. target available capacity 大于等于 source active request count。
4. 同一个 source/target/request_count plan 连续 `CONSOLIDATION_STABLE_SAMPLES=2` 个 controller sample 成立。
5. 如果 worker 返回 `declined/error`，controller 停止该 pair 本轮后续尝试；如果成功则记录 migrated requests。

### 3.2 数据与结果

| 指标 | Baseline | S3 Strategy | 变化 |
|---|---:|---:|---:|
| completed | 48 | 48 | 0 |
| success % | 100.000 | 100.000 | 0 |
| wall time (s) | 19.918 | 19.913 | +0.027% faster |
| req/s | 2.410 | 2.411 | +0.027% |
| avg latency (s) | 3.181 | 3.107 | +2.307% lower |
| p50 latency (s) | 3.188 | 3.202 | -0.423% |
| p95 latency (s) | 3.260 | 3.258 | +0.061% lower |
| p99 latency (s) | 3.262 | 3.260 | +0.053% lower |
| engine gen tok/s | 1852.784 | 1915.251 | +3.372% |
| user completion tok/s | 1850.776 | 1805.925 | -2.423% |
| replay/overhead tokens | 40 | 2177 | increased |
| GPU active sample % | 62.500 | 58.333 | -4.167 pp |
| GPU effective seconds | 31.163 | 30.919 | +0.784% lower |
| avg GPU util % | 46.542 | 46.208 | -0.334 pp |

### 3.3 Controller 证据

`STRATEGY_DRIVER=auto`，脚本未直接调用 worker sidecar action endpoint。证据来自 controller status 和日志：

- 第一次满足 plan 后：`S3 consolidation waiting for stable window: required=2`。
- 第二个 sample 后：controller 形成 plan，source active=4，target capacity=60。
- 第一轮迁移尝试过早，worker 返回 declined，controller 只尝试 1 次并停止：`declined_requests=1, migration_attempts=1, migrated_requests=0`。
- 后续 sample 成功迁移 4 个请求：`migration_attempts=4, migrated_requests=4, executed_pairs=1`。
- worker 日志出现 `migration_complete`，证明 request handoff 路径完成。

### 3.4 结论

S3 自动闭环已经成立：controller 能够发现 tail consolidation 条件、等待稳定窗口、调用 sidecar，并区分 declined 与成功迁移。新 gating 避免了旧版本中对同一个过早 request 连续多次 rollback 的问题。

性能可见性方面，本轮 S3 对 wall time、req/s、p95/p99、GPU effective seconds 有轻微正向变化；但 user completion tok/s 下降，engine replay/overhead tokens 明显上升。因此 S3 当前更适合作为“controller 闭环与迁移机制正确性”证据，性能收益仍需要更稳定的长尾 workload、固定输出长度和 DCGM busy time 积分来进一步验证。

## 4. S2 PD Role Switch 测试

报告目录：`test-scripts/reports/controller-standard-s2-20260629-01/`

### 4.1 测试策略

Baseline 配置：

- `ROLE_SWITCH_ENABLED=false`
- `CONSOLIDATION_ENABLED=false`

Strategy 配置：

- `ROLE_SWITCH_ENABLED=true`
- `CONSOLIDATION_ENABLED=false`
- `PREFILL_QUEUE_THRESHOLD=0`
- `DECODE_IDLE_THRESHOLD=1.0`
- `DECODE_QUEUE_THRESHOLD=999`
- `PREFILL_IDLE_THRESHOLD=0.0`
- `MIN_SWITCH_INTERVAL=1`

Workload 特性：

- `N_REQ=36`
- `CONCURRENCY=6`
- `PROMPT_WORDS=512`
- `MAX_TOKENS=192`

该 workload 使用较长 prompt 和较短输出，目的是形成 prefill-heavy 阶段。controller 在 prefill-heavy 条件下应选择一个 decode worker 切换为 prefill，从而提高 prefill 承载能力。

### 4.2 数据与结果

| 指标 | Baseline | S2 Strategy | 变化 |
|---|---:|---:|---:|
| completed | 36 | 36 | 0 |
| success % | 100.000 | 100.000 | 0 |
| wall time (s) | 16.398 | 10.455 | +36.243% faster |
| req/s | 2.195 | 3.443 | +56.847% |
| avg latency (s) | 2.536 | 1.632 | +35.646% lower |
| p50 latency (s) | 2.519 | 1.644 | +34.736% lower |
| p95 latency (s) | 2.861 | 1.686 | +41.047% lower |
| p99 latency (s) | 2.864 | 1.687 | +41.087% lower |
| engine gen tok/s | 423.335 | 664.275 | +56.917% |
| user completion tok/s | 421.506 | 661.119 | +56.847% |
| replay/overhead tokens | 30 | 33 | +3 |
| GPU active sample % | 66.667 | 60.000 | -6.667 pp |
| GPU effective seconds | 5.468 | 9.444 | -72.722% higher |
| avg GPU util % | 9.143 | 22.133 | +12.990 pp |

### 4.3 Controller 证据

`STRATEGY_DRIVER=auto`，脚本未直接调用 `/switch_role`。controller status 中记录：

- `s2_enabled=true`
- `executed=true`
- `from_role=decode`
- `to_role=prefill`
- `worker_url=http://10.244.0.187:9091`
- reason: `prefill_queue=0>=0 and decode_util=0.00<=1.00`
- sidecar result: `status=ok`, `new_role=prefill`, `switch_time_ms=469.571`

测试后已关闭 controller 策略，并将该 worker 手动恢复为 decode。最终两个 decode worker 当前 role 均为 decode。

### 4.4 结论

S2 自动闭环测试具有较强性能可见性：在 prefill-heavy workload 下，controller 自动将一个 decode worker 切换为 prefill，端到端 wall time 降低约 36.24%，req/s 与 user completion tok/s 提升约 56.85%，p95 latency 降低约 41.05%。

GPU effective seconds 上升，原因是 strategy 在更短时间内把更多 GPU 计算集中完成，平均 GPU util 从 9.14% 提升到 22.13%。因此这里的 GPU 指标应解读为：S2 提高了 GPU 忙碌度和服务吞吐，而不是减少总 GPU utilization 积分。对 prefill-heavy 阶段而言，这是符合预期的资源利用改善。

## 5. 完整性与正确性判断

### 已验证

- 标准 CI/GHCR 镜像构建与部署链路可用。
- controller S2/S3 逻辑来自新镜像，而不是 ConfigMap overlay。
- S2 controller 自动闭环成立，并产生明显端到端性能提升。
- S3 controller 自动闭环成立，支持稳定窗口 gating、declined 后停止重复尝试、成功 migration 记录。
- 报告区分了 engine token counter 与 user-visible completion tokens，避免把 migration replay 错当作用户吞吐。
- GPU 指标扩展到了 active sample、util、memory 和 effective seconds proxy。

### 仍需改进

- S3 的 user-visible stream continuity 仍不是完整 client stream reattachment 语义，当前更偏 engine-side migration / takeover 证明。
- S3 replay/overhead token 较高，说明 migration 成本还需要更严格的 request age / generated token gating。
- 当前 GPU effective seconds 使用 `nvidia-smi` 粗粒度采样；集群已有 DCGM exporter，下一步应接入 DCGM metric，计算 GPU busy time 积分。
- S2 本轮使用阈值 `PREFILL_QUEUE_THRESHOLD=0`、`DECODE_IDLE_THRESHOLD=1.0` 来稳定触发 controller，适合证明闭环链路；生产阈值需要基于真实 queue depth、utilization 和阶段信号重新校准。

## 6. 原始报告与 Artifact

- S3 报告：`test-scripts/reports/controller-standard-s3-20260629-01/REPORT.md`
- S3 raw data：`baseline/summary.json`、`strategy/summary.json`、`strategy/strategy_events.jsonl`、`strategy/logs/`
- S2 报告：`test-scripts/reports/controller-standard-s2-20260629-01/REPORT.md`
- S2 raw data：`baseline/summary.json`、`strategy/summary.json`、`strategy/strategy_events.jsonl`、`strategy/logs/`
