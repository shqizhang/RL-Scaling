# 手动测试指南（Manual Testing Guideline）— RL-Scaling on Dynamo

最后更新：2026-05-10
分支：`RL-Scaling`
读者：在生产集群上手动验证 S2（弹性 PD 角色切换）和 S3（长请求合并）的工程师。

关于架构背景，请先阅读：
- [docs/TECH-REPORT-architecture-and-implementation.md](../docs/TECH-REPORT-architecture-and-implementation.md)
- [docs/S2-elastic-pd-switch.md](../docs/S2-elastic-pd-switch.md)
- [docs/S3-request-consolidation.md](../docs/S3-request-consolidation.md)

本目录中的两个自动化脚本（`test-s2-elastic.sh`、`test-s3-consolidation.sh`）是权威参考。本指南说明如何在需要调试、演示或扩展场景时，手动执行相同的流程。

---

## 0. 前置条件

| 项目 | 所需值 / 检查方法 |
|---|---|
| 集群 | K8s ≥ 1.30 单节点，GPU 节点就绪（`kubectl get node -o wide`） |
| 命名空间 | `dynamo-system`（可通过 `NS=...` 覆盖） |
| DGD | `vllm-v1-disagg-router`（可通过 `DGD=...` 覆盖）— `kubectl -n dynamo-system get dynamographdeployments.nvidia.com` |
| 服务发现后端 | DynamoWorkerMetadata CRD — `kubectl get crd dynamoworkermetadatas.nvidia.com` |
| 镜像 | `ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-<git-sha>`，部署在 Frontend + decode + prefill Pod 上 |
| 模型 | `Qwen/Qwen3-0.6B` |

Decode Pod 必须使用双模式（dual-mode）补丁运行：

- 引擎参数 `--kv-transfer-config '{"kv_connector":"NixlConnector","kv_role":"kv_both",...}'`
- 环境变量 `DYNAMO_RL_DUAL_MODE=1`
- 环境变量 `DYNAMO_RL_SIDECAR_PORT=9091`
- 环境变量 `DYN_SYSTEM_PORT=9090`

一键应用或重新应用双模式补丁：

```bash
IMAGE=ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-<sha> \
  ./test-scripts/apply-dual-mode-decode.sh
```

验证 Pod 已 Ready：

```bash
kubectl -n dynamo-system get pod -l nvidia.com/dynamo-graph-deployment-name=vllm-v1-disagg-router -o wide
```

你应该看到 ≥ 2 个 decode Pod（`vllmdecodeworker-...`）、≥ 1 个 prefill Pod（`vllmprefillworker-...`）以及 1 个 frontend（`...frontend-...`）。

---

## 1. 常用端口转发

打开三个本地端口 — 在独立的终端中保持运行（`Ctrl-C` 释放）：

```bash
NS=dynamo-system

# Frontend OpenAI API
FRONTEND=$(kubectl -n $NS get pod -l nvidia.com/dynamo-component-type=frontend -o name | head -1)
kubectl -n $NS port-forward "$FRONTEND" 18000:8000 &

# 选取两个 decode Pod
mapfile -t DEC < <(kubectl -n $NS get pod -l nvidia.com/dynamo-component-type=worker \
  -o jsonpath='{range .items[?(@.spec.containers[0].args[0]=="vllmdecodeworker")]}{.metadata.name}{"\n"}{end}')
TGT="${DEC[0]}"; PEER="${DEC[1]}"
echo "TARGET=$TGT  PEER=$PEER"

# 每个 decode 的 Sidecar HTTP（角色切换 + 迁移）
kubectl -n $NS port-forward "$TGT"  19191:9091 &   # TARGET sidecar
kubectl -n $NS port-forward "$PEER" 19192:9091 &   # PEER   sidecar

# 每个 decode 的 vLLM /metrics
kubectl -n $NS port-forward "$TGT"  19291:9090 &   # TARGET metrics
kubectl -n $NS port-forward "$PEER" 19292:9090 &   # PEER   metrics
```

快速冒烟测试：

```bash
curl -s localhost:18000/v1/models | jq .data[].id        # -> "Qwen/Qwen3-0.6B"
curl -s localhost:19191/v1/role                          # -> {"role":"decode"}
curl -s localhost:19291/metrics | grep '^vllm:num_requests_running'
```

---

## 2. 检查服务发现基础设施（DynamoWorkerMetadata CR）

路由器**不**使用 Service endpoints，而是通过 watch CR 实现：

```bash
# 列出 CR（每个 worker Pod 对应一个）
kubectl -n dynamo-system get dynamoworkermetadatas.nvidia.com

# 查看 TARGET Pod 当前发布了哪些 model_cards
kubectl -n dynamo-system get dynamoworkermetadatas.nvidia.com \
  -o json | jq -r --arg p "$TGT" '
    .items[] | select(.metadata.ownerReferences[0].name==$p)
    | .spec.data.model_cards[].endpoint_id'
```

处于 decode 模式的 Pod 会发布一个 endpoint_id 以 `/backend/generate` 结尾的条目。执行 `switch_role -> prefill` 后，该条目消失。这是验证路由器感知的最可靠探针。

---

## 3. S2 — 弹性 PD 角色切换（手动演练）

**目标**：将一个 decode Pod 从聊天 WorkerSet 中移出（变为仅 prefill），再将其恢复。验证路由器是否停止/恢复向该 Pod 路由 decode 流量。

### 3.1 切换前快照

```bash
# TARGET 的 CR 状态（应包含 "/backend/generate" endpoint）
kubectl -n dynamo-system get dynamoworkermetadatas.nvidia.com \
  -o json | jq -r --arg p "$TGT" '.items[] | select(.metadata.ownerReferences[0].name==$p) | .spec.data.model_cards'

# Sidecar 当前角色
curl -s localhost:19191/v1/role
```

### 3.2 触发切换（decode -> prefill）

```bash
curl -s -X POST localhost:19191/switch_role \
     -H 'content-type: application/json' \
     -d '{"target_role":"prefill"}' | jq .
```

响应返回 `status:"ok"` 及每步耗时明细（`sleep_ms`、`unregister_mdc_ms`、`reconfig_nixl_ms`、`reset_prefix_cache_ms`、`set_disaggregation_mode_ms`、`register_mdc_ms`、`wake_ms`、`emit_role_changed_ms`）。

### 3.3 直接验证路由器感知

```bash
# (a) CR 差异：TARGET 的 "/backend/generate" 条目应已消失
kubectl -n dynamo-system get dynamoworkermetadatas.nvidia.com \
  -o json | jq -r --arg p "$TGT" '.items[] | select(.metadata.ownerReferences[0].name==$p) | .spec.data.model_cards[].endpoint_id'

# (b) 聊天归属验证：发送 30 次探测；TARGET 的命中次数应为 0
TGT_BEFORE=$(curl -s localhost:19291/metrics | awk '/^vllm:request_success_total/{s+=$2} END{print s+0}')
PEER_BEFORE=$(curl -s localhost:19292/metrics | awk '/^vllm:request_success_total/{s+=$2} END{print s+0}')
for i in $(seq 1 30); do
  curl -s -X POST localhost:18000/v1/chat/completions \
       -H 'content-type: application/json' \
       -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"say hi"}],"max_tokens":4}' >/dev/null
done
TGT_AFTER=$(curl -s localhost:19291/metrics | awk '/^vllm:request_success_total/{s+=$2} END{print s+0}')
PEER_AFTER=$(curl -s localhost:19292/metrics | awk '/^vllm:request_success_total/{s+=$2} END{print s+0}')
echo "TARGET delta = $((TGT_AFTER-TGT_BEFORE))   PEER delta = $((PEER_AFTER-PEER_BEFORE))"
# 预期结果：TARGET delta == 0, PEER delta == 30
```

### 3.4 恢复（prefill -> decode）

```bash
curl -s -X POST localhost:19191/switch_role -H 'content-type: application/json' -d '{"target_role":"decode"}' | jq .

# CR 应重新出现 "/backend/generate" 条目
kubectl -n dynamo-system get dynamoworkermetadatas.nvidia.com \
  -o json | jq -r --arg p "$TGT" '.items[] | select(.metadata.ownerReferences[0].name==$p) | .spec.data.model_cards[].endpoint_id'

# 探测流量现在应在两个 decoder 之间分配
```

### 3.5（可选）切换期间施加持续负载

在第二个 Shell 中，于步骤 3.2 之前执行：

```bash
end=$((SECONDS+30))
while (( SECONDS < end )); do
  curl -s -X POST localhost:18000/v1/chat/completions \
       -H 'content-type: application/json' \
       -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"hi"}],"max_tokens":8}' >/dev/null &
  sleep 0.5
done
wait
```

不应出现 5xx 错误；尾部延迟可能在 NIXL 重新握手期间短暂升高。

---

## 4. S3 — 长请求合并（手动演练）

**目标**：将 TARGET 上正在执行的长 decode 请求迁移到 PEER，释放 TARGET 的 GPU KV 内存，同时请求继续正常推进。

### 4.1 在 TARGET 上调度长请求负载

路由器会根据 KV 亲和性选择 decoder；当只有 2 个 decoder 且流式请求数 N≥24 时，两个 Pod 都会分配到任务。

```bash
# 快照
curl -s localhost:19291/metrics | grep -E '^vllm:num_requests_running' ; \
curl -s localhost:19292/metrics | grep -E '^vllm:num_requests_running'

# 后台发送 24 个流式长聊天请求
for i in $(seq 1 24); do
  curl -sN -X POST localhost:18000/v1/chat/completions \
       -H 'content-type: application/json' \
       -d "{\"model\":\"Qwen/Qwen3-0.6B\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"please write a long story #$i\"}],\"max_tokens\":3500}" \
       >/dev/null &
done
sleep 8   # 等待调度器启动

# 确认两个 decoder 都处于忙碌状态
echo "TGT  running=$(curl -s localhost:19291/metrics | awk '/^vllm:num_requests_running/{print $2;exit}')"
echo "PEER running=$(curl -s localhost:19292/metrics | awk '/^vllm:num_requests_running/{print $2;exit}')"
```

### 4.2 将 TARGET 上进度最大的请求迁移到 PEER

```bash
BODY=$(curl -s -X POST localhost:19191/migrate_out \
       -H 'content-type: application/json' \
       -d '{"request_id":"*"}')
echo "$BODY" | jq '.status, .request_id, .generated_tokens'

curl -s -X POST localhost:19192/migrate_in \
     -H 'content-type: application/json' \
     -d "$BODY" | jq .
```

预期结果：
- `migrate_out.status == "ok"`（通配符 `"*"` 自动选择进度最大的在途请求）
- `migrate_in.status == "ok"`（如果成本收益门控拒绝，则为 `"declined"` — 见 §4.4）

重复 5-6 次以进一步排空 TARGET。每次迭代之间观察：

```bash
curl -s localhost:19291/metrics | awk '/^vllm:num_requests_running/{print "TGT  running="$2}'
curl -s localhost:19292/metrics | awk '/^vllm:num_requests_running/{print "PEER running="$2}'
```

`TGT.running` 应单调递减至 0；`PEER.generation_tokens_total` 应持续增长。

### 4.3 等待原始聊天分发完成

```bash
wait   # 等待 24 个后台 curl 进程
```

每个聊天请求都应正常结束（无 5xx，无截断提示）。迁移到 PEER 的请求会继续向同一客户端连接流式输出 token，因为 Frontend 不受底层引擎切换的影响（request_id 被保留）。

### 4.4 拒绝路径（成本收益门控）

门控（位于 `MigrationPolicy` 中）在以下情况下会拒绝迁移：
- `generated_tokens < 16`（重放成本过低，不值得迁移；直接本地重试即可），或
- `generated_tokens > max_replay_tokens (8192)`（重放成本过高），或
- `remaining < min_remaining_tokens (32)`（请求即将完成），或
- 两端均将达到 `max_active` 饱和。

通过构造一个明显过长的请求体来强制触发拒绝：

```bash
curl -s -X POST localhost:19192/migrate_in -H 'content-type: application/json' -d '{
  "status":"ok","request_id":"synthetic","prompt_token_ids":[1,2,3],
  "generated_token_ids":[],"generated_tokens":99999,
  "sampling_params":{"max_tokens":1000},"original_max_tokens":1000
}' | jq .
# -> {"status":"declined","reason":"generated_tokens_exceeds_max_replay_tokens"}
```

---

## 5. 故障排查

| 症状 | 可能的原因 / 修复方法 |
|---|---|
| `switch_role` 返回 5xx 并提示 `kv_transfer_config not set` | Decode Pod 启动时未设置 `--kv-transfer-config`。重新运行 `apply-dual-mode-decode.sh`。 |
| 执行 `switch_role -> prefill` 后 CR 仍显示 `/backend/generate` | 重注册器（Reregistrar）未执行。查看 Pod 日志：`kubectl logs $TGT -c main | grep -iE 'reregistrar\|register_endpoint\|apply_cr'`。 |
| 切换后探测仍然命中 TARGET | Frontend 缓存延迟。`ModelWatcher` 每 1 秒重新读取 CR；等待 2 秒后重新探测。如果仍然失败，检查 frontend Pod 是否设置了 `DYN_DISCOVERY_BACKEND=kubernetes`。 |
| `migrate_out` 返回 `"no_eligible_request"` | TARGET 上没有满足 `min_generated_tokens` 的请求。增大 `LONG_MAX_TOK` 或等待更长时间再执行迁移。 |
| `migrate_in` 始终拒绝 | 检查 `reason` 字段 — 最常见的原因是请求太短（重放成本低）或太长（重放成本高）。在 `components/src/dynamo/vllm/migration.py` 中调整 `MigrationPolicy`。 |
| 两个 decoder 立即归零 | Qwen3-0.6B 速度很快；负载在你执行迁移前已排空。使用 `stream=true` 且 `max_tokens >= 3500`，或切换到更大的模型。 |
| `kubectl port-forward` 挂起 / 断开 | 重启即可。迁移 / 角色切换状态存储在 Pod 上，与 port-forward 无关。 |

关键日志：

```bash
# Decode worker — 角色转换、NIXL 握手、迁移注册/注销
kubectl -n dynamo-system logs "$TGT"  -c main | grep -iE 'switch_role|reregistr|nixl|migrate|model_card'

# Frontend — 路由决策、model-card watcher 事件
kubectl -n dynamo-system logs "$FRONTEND" -c main | grep -iE 'kv_router|prefill_router|model_watcher|backend/generate'
```

---

## 6. 清理

```bash
# 终止所有残留的 port-forward 进程
pkill -f 'kubectl.*port-forward' || true

# 如果调整过副本数，将部署恢复为干净的镜像/副本数
kubectl -n dynamo-system rollout restart deploy
```

脚本自动运行生成的报告保存在 [test-scripts/reports/](reports/) — 请勿手动删除，场景文档中引用了这些报告。
