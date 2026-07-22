# 优化方案：metrics 补齐 + S2/S3 修正 + 5 场景重测（2026-07-22）

> 依据：`ending-report/Evaluation-DataAudit-20260722.md` 的数据审计结论。
> 目标：让 final report 的技术实现与数据分析和当前实现一致，并使 S2/S3 的
> 效益（queue time / batch time / GPU 占用）可被严谨测出。

## 0. 审计结论回顾（驱动本方案的四个事实）

1. D→P 在 6/6 run 中于 T0 前 8–26s 被 prewarm 探针误触发（PREFILL_QUEUE_THRESHOLD=1）；
   P→D 被 MIN_SWITCH_INTERVAL=60s 锁死在 D→P 后 60.1s（5/6 落在 C 段）。
   → S2 测的是"错误时机切换的代价"，不是"正确切换的收益"。
2. 切换 3.5s 中 3.0s 是 CORDON_SETTLE 纯等待（引擎已空闲、0 到达）。
3. S3 全部 6 个主性能 run migrated=0（空源释放）；validated run 证明迁移可执行，
   但镜像含 fidelity bug（migrated straggler stop@1283 vs peers length@5000）。
   修复已在代码，未构建。
4. 缺关键采集：TTFT、role-aware GPU 归因、per-role queue 序列、
   S2/S3 动作事件与耗时聚合（s2_switch_total_ms 恒 0）。

---

## Batch A — harness / metrics（只改 test-scripts + controller 配置，不动镜像）

A1. **TTFT**：harness 改 stream=true，记录首 token 时间戳 → requests.csv 加
    `ttft_s` 列。queue+prefill 时延 = TTFT，这是 indicator "queue timing" 的
    直接度量。分段聚合 p50/p95 TTFT。
A2. **role-aware GPU 序列**：pod sampler 每 1s 同时轮询各 worker sidecar
    `/v1/role`（现有端点），产出 `role_samples.csv`；分段 GPU 数按实际 role
    积分（当前按 Deployment 计数，S2 场景下 prefill/decode 数失真）。
A3. **机制事件与耗时**：S2/S3 动作（决策原因、时刻、switch timings_ms 分解、
    migrate 三阶段耗时、cordon/scale 时刻）写入 events.json；修复 summary 的
    `s2_switch_total_ms` 聚合；新增 `s3_release_lead_time_s`（释放时刻→T_end）。
A4. **per-role queue 序列**：prom 采样加 `dynamo_frontend_queued_requests{role=}`
    1s 粒度（当前 5s、无 role 维度）。
A5. **T0 前冻结策略**：controller 以 ROLE_SWITCH_ENABLED=0 / CONSOLIDATION_ENABLED=0
    prewarm，T0 时刻经 env/API 打开（或 T0 后再启动 controller），杜绝探针误触发。
A6. **workload 校正**（使各机制的触发窗口真实存在）：
    - A 段 max_tokens 64/96/128 → **8/12/16**：A 成为纯 prefill-bound，
      D→P 才有正收益空间（旧 105-req 套件 A 段 max_tokens=4 时 prefill −36%）。
    - B 段不变（decode-heavy，逼 P→D）。
    - C 段 offset +40 → **+30s**（B 未排空时注入）+ 保持 0/3/6 错峰：
      消除 B→C 空档，使 S3 必须走 migration 而非空源释放；
      另保留一个 deterministic migration 专项 run 作机制证据。
    - MIN_SWITCH_INTERVAL 60 → **20s**；PREFILL_QUEUE_THRESHOLD 1 → 2，
      DECODE_QUEUE_THRESHOLD 维持 2（配合 A5 后探针不再污染）。
A7. 报告口径修正：workload 表用实测 token 数（A≈4227/B≈1617/C≈288）。

## Batch B — worker-side 切换加速 + fidelity 修复（dynamo 镜像重建）

B1. **自适应 settle**（替代固定 3.0s）：cordon 后进入 stable window，
    早退条件 = 引擎空闲且连续 500ms 无新到达（arrivals 计数已有）；
    上限仍 3s 兜底。预期贡献：3.0s → ~0.5s。
B2. **stale-role 宽容窗口**：切换完成后 T=5s 内，dispatcher 对 role 不匹配的
    到达请求不再拒绝，而是用另一套 handler 照常服务（kv_both 引擎两个
    handler 常驻，能力上可服务两种角色），计数并打日志。
    这是 0 丢失的保底，使 B1 的激进早退安全。
    预期切换总耗时 **3.5s → ~1.0–1.4s**（register_mdc ~0.4s 成为主项）。
B3. **fidelity 修复入镜像**：`_sampling_params_to_dict` 全量快照（ignore_eos）
    + `_extract_prompt_token_ids` Mapping 修复（已在代码树，随本次一起构建）。
B4.（后续可选，本轮不做）pause 期 hold-and-serve（排队代替拒绝）→ settle≈0，
    ~0.6s；或 Rust frontend routing-epoch ACK → ~0.5s。写入 future work。

## Batch C — 构建与部署（按 CICD.md）

C1. dynamo fork：push 到 `RL-Scaling` 分支 → `rl-scaling-build` workflow →
    `ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-<sha>`（~30min）。
C2. controller 若 Batch A 涉及 controller 代码（A5 开关、A3 事件）→ CI 构建
    controller 镜像。
C3. 集群侧：SSH 隧道 16443→gpu14，patch DGD/Deployment 镜像 tag，operator
    保持 0 replicas 规则不变。

## Batch D — 5 场景重测 + 验证 gate

D1. 场景：baseline_1p1d / static_2p2d / s2_only / s3_only / mixed，
    **同 session interleave、反平衡顺序**，每场 3 次（时间允许 5 次）。
D2. 通过 gate（不达标不进报告）：
    - 全场景 100% valid、0 timeout、0 5xx；
    - s2: D→P 在 A 段内触发（0 < t < A_end）、P→D 在 B 段内；
      switch_time < 1.5s；A 段 TTFT p95 与 wall vs static 下降；
    - s3: migrated ≥ 1 且 migrated 请求 finish=length@6000（fidelity 验证）；
      tail decode-GPU·s 与 release lead time 改善；
    - mixed: S2/S3 无 churn 环（P→D 恢复的 decoder 不被 10s 内释放）。
D3. 产出：新 REPORT + 按审计意见重写 final-report Part 6/7（含正确的
    状态机描述、S3 命名、S2 时序、workload 实测 token 数）。

## 预估

| 批次 | 工作量 | 依赖 |
|---|---|---|
| A | 0.5–1 天（脚本） | 无 |
| B | 0.5 天 + 构建 30min | 无 |
| C | 1h 操作 | B 完成、隧道可用 |
| D | 一轮 5×3 约 2–3h + 分析 0.5 天 | A、C |
| 报告重写 | 0.5–1 天 | D |

---

## 实施状态（2026-07-22，Batch A/B 代码已完成）

### 已落地的改动

**dynamo（+100 −6 行，需重建镜像）**

- `dual_mode.py`：新增 switch 窗口事件（`switch_in_progress` /
  `switch_previous_role` / `wait_switch_complete`），switch_role 进入即开窗、
  finally 保证关窗（错误路径不泄漏）；响应新增 `frontend_ack`
  （method=cordon+arrival_silence+hold，含 arrivals_after_cordon 与
  settle_window_s）和 `frontend_target_ready`——`run_frontend_ack_staged_*`
  草稿 harness 的契约由此可满足。
- `main.py::_generate_dispatch`：**hold-during-switch**——cordon→register
  窗口内到达的请求必然是旧 role 流量（新卡尚未发布），不再被 sleep 拒绝
  （500），而是挂起等切换完成后按切换前 role 服务；另加永久防护：携带
  `kv_transfer_params` 的请求（decode-intent 确定性标记）在 prefill role
  下仍走 decode handler。
- 由此 `DYNAMO_RL_CORDON_SETTLE` 可从 3.0 压到 **0.5**（0 丢失由 hold
  保底），预期切换 3.5s → **~1.0s**（register_mdc ~0.4s 成为主项）。
- fidelity 修复（ignore_eos 全量快照 + prompt TypedDict）已在树内，随镜像
  一起发布。
- 本地已验证：py_compile + stub 异步测试（hold intent/completed、错误路径
  关窗、no-op、ack 字段）全部通过；现有 17 个 test_dual_mode 断言均为响应
  子集，不受新增字段影响（用户机器可再跑 pytest 确认）。

**RL-Scaling harness（`run_phased_rollout_5scenario_e2e.py` → v2）**

- nvext 富化进 requests.csv：`prefill_wait_time_ms`（router 队列等待）、
  `prefill_time_ms`、`ttft_ms`、`server_total_time_ms`、prefill/decode
  worker id。分段 summary 含三者的 mean/p50/p95 分布 + worker 分布。
- `effective_runtime_role_gpu_s`：按 pod role label 积分的 GPU 数
  （全程 + 分段），修正 Deployment 口径对 S2 的 role-blind 失真。
- `s3_release_lead_time_s` / `s3_release_ts`：从 controller status 采样中
  找到首次 scaled_down_to 的时刻，量化"提前释放的 1-GPU 窗口"。
- S2 触发校正：s2_only/mixed 场景 `PREFILL_QUEUE_THRESHOLD=3`
  （高于探针残留 ≤2，远低于 A burst 的 40+），`MIN_SWITCH_INTERVAL=20`。
- **pre-T0 守卫**：策略使能后监视 6s，若 T0 前有 switch 执行则 fail-fast
  （事件 `pre_t0_switch_detected`）。
- workload A6：A 段 max_tokens 默认 **8/12/16**（`--phase-a-max-tokens
  64,96,128` 可复现旧形态）。

### 关键新证据（用现有 0720 数据即可写进报告）

同 session（new session）A 段 TTFT 对比：static 556ms → **s2_only 334ms
（−40%）**、mixed 342ms；B 段 270ms → 191ms。即 **D→P 确实显著改善了
prefill burst 的 TTFT/queue timing**（indicator 的核心诉求成立），输在
decode 侧被饿死（A 段有 64–128 token 输出、仅剩 1 decoder）。这组数字来自
response JSON 的 nvext.timing，旧 harness 未聚合，现已入 v2。

### Runbook（Batch C+D，一条命令，Git Bash）

沙箱已实测无法到达集群（192.168.1.246 Network unreachable、无 gpu14 SSH
身份、无 GHCR push 凭证），因此 C+D 打包为一键脚本在工作站执行：

```sh
cd /c/projects/IP && bash RL-Scaling/test-scripts/run-batch-cd.sh
```

脚本内容（`test-scripts/run-batch-cd.sh`，幂等可重跑）：
preflight（隧道自动拉起/kubectl/docker/operator=0 检查）→ 双仓 commit →
**pyfix 薄覆盖镜像**（FROM 当前在跑的 worker 镜像 + 5 个 Python 文件，
~2min，替代 30min 全量构建；fidelity 修复一并入镜像）→ push GHCR →
直接 patch 两个 worker Deployment（image + `DYNAMO_RL_CORDON_SETTLE=0.5`，
operator 恒 0 所以不经 DGD reconcile；DGD spec 尽力同步防回卷）→
rollout 等待 + 运行镜像核验 → `run_phased_rollout_5scenario_e2e.py
--repeats 3`（约 2–3h）→ `check_suite_gates.py` 自动裁决。

可选单测（改动前后各跑一次）：
`python -m pytest components/src/dynamo/vllm/tests/test_dual_mode.py -q`（dynamo 目录）。

### Gate 自动裁决（`test-scripts/check_suite_gates.py`）

G1 质量门（100%/0/0）· G2 pre-T0 守卫 · G3 切换落点（D→P∈A 窗口、
P→D∈B 窗口，从 controller.log 时间戳判定）· G4 切换 <1500ms ·
G5 s3_only migrated≥1 · G6 全场景 tail fidelity（length@满额 token）·
G7 release lead time >0 · G8 s2 vs static 同轮 A 段 TTFT p95（软门）。

已在 0720 旧数据上自测：精确命中全部已知缺陷（每个 s2/mixed run 报
pre_t0_switches=1、worst switch 3445–3613ms、s3 migrated=0），证明判据
与审计一致；新一轮数据必须全绿才进报告。

### Gate 快查（对新 suite 的 summary/log）

- 每个 s2/mixed run：`pre_t0_guard_passed` 事件存在；D→P 时刻 ∈ A 段窗口，
  P→D ∈ B 段窗口；`switch_time_ms < 1500`；`arrivals_after_cordon` 与
  held-request 日志核对 0 丢失。
- s2 A 段：`ttft_ms.p95` 与 `service_window_s` 均低于同轮 static。
- s3/mixed：`s3_migrated_requests ≥ 1`（C 与 B 重叠后空档消失）；migrated
  straggler `finish_reason=length`、completion=5000（fidelity 修复生效）；
  `s3_release_lead_time_s > 0`；`effective_runtime_role_gpu_s` 分段可见
  decode GPU 下降。
- 全场景 100% valid、0 timeout、0 5xx。
