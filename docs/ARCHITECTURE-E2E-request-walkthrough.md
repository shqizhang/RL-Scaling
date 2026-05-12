# Dynamo 端到端请求处理架构详解

> 以一个具体请求 `"who are you"` 为例，追踪从 HTTP 入口到 token 输出的完整生命周期。
> 涵盖 K8s 部署层、Dynamo 运行时各组件、vLLM 引擎、KVBM、NIXL 的交互。

---

## 架构全景图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        K8s Cluster (namespace: dynamo-system)              │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                  DGD: vllm-v1-disagg-router                         │   │
│  │                                                                      │   │
│  │  ┌─────────────────────────────────────────────────────────────┐    │   │
│  │  │ Frontend Pod (Rust binary)                                   │    │   │
│  │  │                                                               │    │   │
│  │  │  HTTP Server (:8000)                                          │    │   │
│  │  │    │                                                          │    │   │
│  │  │    ▼                                                          │    │   │
│  │  │  Preprocessor (chat→tokens, tokenization)                     │    │   │
│  │  │    │                                                          │    │   │
│  │  │    ▼                                                          │    │   │
│  │  │  Migration (retry on worker failure)                          │    │   │
│  │  │    │                                                          │    │   │
│  │  │    ▼                                                          │    │   │
│  │  │  Backend (prepare request)                                    │    │   │
│  │  │    │                                                          │    │   │
│  │  │    ▼                                                          │    │   │
│  │  │  ┌────────────────────────────────────────────────────────┐  │    │   │
│  │  │  │ PrefillRouter                                          │  │    │   │
│  │  │  │   ├─ KvRouter (prefill) ─→ 选择 prefill worker        │  │    │   │
│  │  │  │   │    └─ Indexer (radix tree, 每个 worker 的 KV 缓存)│  │    │   │
│  │  │  │   │    └─ KvScheduler (cost function + softmax)        │  │    │   │
│  │  │  │   │                                                    │  │    │   │
│  │  │  │   └─ KvRouter (decode) ─→ 选择 decode worker          │  │    │   │
│  │  │  │        └─ Indexer (radix tree)                         │  │    │   │
│  │  │  │        └─ KvScheduler                                  │  │    │   │
│  │  │  └────────────────────────────────────────────────────────┘  │    │   │
│  │  │    │                                ▲                        │    │   │
│  │  │    ▼ (forward: tokens→worker)       │ (backward: tokens→text)│    │   │
│  │  │  Backend (detokenization)                                    │    │   │
│  │  │    │                                                          │    │   │
│  │  │    ▼                                                          │    │   │
│  │  │  HTTP Response (SSE stream / JSON)                           │    │   │
│  │  └─────────────────────────────────────────────────────────────┘    │   │
│  │                                                                      │   │
│  │  ┌──────────────────────┐  ┌──────────────────────┐                 │   │
│  │  │ Prefill Worker Pod   │  │ Prefill Worker Pod   │  (可多个)       │   │
│  │  │ (Python: vLLM engine)│  │                      │                 │   │
│  │  │  ├─ NixlConnector    │  │                      │                 │   │
│  │  │  ├─ GPU KV Cache     │  │                      │                 │   │
│  │  │  └─ KVBM integration │  │                      │                 │   │
│  │  └──────────────────────┘  └──────────────────────┘                 │   │
│  │         │ NIXL RDMA write (KV blocks)                               │   │
│  │         ▼                                                            │   │
│  │  ┌──────────────────────┐  ┌──────────────────────┐                 │   │
│  │  │ Decode Worker Pod    │  │ Decode Worker Pod    │  (可多个)       │   │
│  │  │ (Python: vLLM engine)│  │                      │                 │   │
│  │  │  ├─ NixlConnector    │  │  ├─ RL-Scaling       │                 │   │
│  │  │  ├─ GPU KV Cache     │  │  │   Sidecar (:9091) │                 │   │
│  │  │  ├─ KVBM integration │  │  │   ├─ /switch_role │                 │   │
│  │  │  └─ Token streaming  │  │  │   ├─ /migrate_out │                 │   │
│  │  └──────────────────────┘  │  │   └─ /migrate_in  │                 │   │
│  │                             └──────────────────────┘                 │   │
│  │                                                                      │   │
│  │  ┌─────────────────────────────────────────┐                        │   │
│  │  │ Discovery Layer (DynamoWorkerMetadata CR)│                        │   │
│  │  │  每个 pod 写自己的 CR:                   │                        │   │
│  │  │   model_cards: {backend/generate/...}   │                        │   │
│  │  │   endpoints:   {backend/generate/...}   │                        │   │
│  │  │  Frontend 通过 ModelWatcher 实时监听     │                        │   │
│  │  └─────────────────────────────────────────┘                        │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 第一阶段：HTTP 请求到达 Frontend

### 1.1 用户发送请求

```bash
curl -X POST http://frontend:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-0.6B",
    "messages": [{"role": "user", "content": "who are you"}],
    "max_tokens": 100,
    "stream": false
  }'
```

### 1.2 Frontend HTTP Server (Rust: Axum)

**文件**: `lib/llm/src/http/service/openai.rs`

Frontend pod 运行 Rust binary，使用 Axum 框架监听 `:8000`。路由注册：

```rust
Router::new()
    .route("/v1/chat/completions", post(handler_chat_completions))
```

`chat_completions()` 函数处理流程：
1. **就绪检查** — 如果未就绪返回 HTTP 503
2. **模板应用** — 填充默认 `model`、`temperature`、`max_completion_tokens`
3. **验证** — 检查必填字段（messages 非空）、不支持的字段
4. **引擎查找** — `state.manager().get_chat_completions_engine_with_parsing(&model)` 从 `ModelManager` 中查找 pipeline
5. **生成** — `engine.generate(request)` 进入 operator pipeline
6. **响应** — streaming 返回 SSE 事件；非 streaming 合并为一个 JSON 响应

---

## 第二阶段：Preprocessor — 分词与模板处理

**文件**: `lib/llm/src/preprocessor.rs`

`OpenAIPreprocessor` 是 pipeline 中第一个 operator，负责将 OpenAI chat 格式转为 token 序列：

### 2.1 Chat Template 应用

将 messages 数组通过 Qwen3 的 chat template 转换为格式化文本：

```
<|im_start|>user
who are you<|im_end|>
<|im_start|>assistant
```

### 2.2 Tokenization

使用 Qwen3-0.6B 的 tokenizer（HuggingFace `tokenizers` 库，Rust 实现）将文本编码为 token IDs：

```
"who are you" → [15196, 525, 498]  (示意，实际值取决于 tokenizer)
```

加上 chat template 的特殊 token，最终 `token_ids` 大约有 9 个 tokens。

### 2.3 输出

生成 `PreprocessedRequest`：
```rust
PreprocessedRequest {
    token_ids: [151644, 872, 198, 15196, 525, 498, 151645, 198, 151644, ...],
    routing: RoutingHints { model: "Qwen/Qwen3-0.6B", ... },
    sampling_options: SamplingOptions { temperature: 0.7, max_tokens: 100, ... },
    stop_conditions: StopConditions { stop_token_ids: [151643, 151645], ... },
    ...
}
```

---

## 第三阶段：PrefillRouter — 选择 Prefill Worker

**文件**: `lib/llm/src/kv_router/prefill_router.rs`

### 3.1 PrefillRouter 架构

`PrefillRouter` 是一个 Rust `Operator`，位于 pipeline 的中间层：

```
Preprocessor → Migration → Backend → PrefillRouter → DecodeRouter(KvPushRouter)
```

它内部持有两个独立的路由器：
- **Prefill KvRouter** — 只看到注册为 `prefill` 类型的 worker
- **Decode KvRouter** — 只看到注册为 `backend`(decode) 类型的 worker

### 3.2 Prefill Worker 选择算法

当请求到达 `PrefillRouter.generate()` 时：

1. **激活检查** — 检查是否发现了任何 prefill worker。如果没有，直接 passthrough 到 decode（单体模式）
2. **获取 semaphore** — 限制并发 prefill 数量
3. **设置 max_tokens=1** — prefill 只生成 1 个 token（KV 计算为主）
4. **选择 prefill worker** — 调用 `query_prefill_worker()`

#### `query_prefill_worker()` — KV 感知选择

在 KV 模式下，调用 `KvRouter.find_best_match()`：

```
输入: token_ids = [151644, 872, 198, 15196, 525, 498, ...]
```

**Step 1: 计算 block hash**

将 token 序列按 `block_size`（默认 64）分块，每块计算 hash：
```
tokens[0:64]  → hash_0
tokens[64:128] → hash_1
...
```

对于 "who are you" 只有 ~9 tokens，只有 1 个不完整的 block。

**Step 2: 查询 radix tree**

`Indexer.find_matches(block_hashes)` 在每个 prefill worker 的 radix tree 中查找匹配：
```
Prefill Worker P1 (原始 prefill worker):  overlap = 0 blocks
Prefill Worker P2 (从 decode 切换来的):    overlap = 0 blocks
```

由于 "who are you" 是新请求，两个 worker 都没有缓存，overlap = 0。

**Step 3: 计算 cost logit（每个 worker）**

```
logit = overlap_score_weight × potential_prefill_blocks + decode_blocks

P1: logit = 1.0 × (9/64) + current_decode_blocks_on_P1
P2: logit = 1.0 × (9/64) + current_decode_blocks_on_P2
```

当 overlap = 0 时，`potential_prefill_blocks` 相同，选择取决于 `decode_blocks`（即 worker 当前负载）。

**Step 4: Softmax 采样**

用 `router_temperature` 对 logits 做 softmax 后采样。temperature=0 时贪心选最低 logit。

**关键洞察**：对于新请求，KV overlap 为 0，选择主要由 **当前负载** 决定。但如果 dedicated prefill worker 已经处理过类似前缀的请求，它的 radix tree 中会有缓存记录，使得后续请求更倾向于选择它。

### 3.3 为什么切换后的 TARGET 可能不被选中

当一个 decode worker 通过 `switch_role` 切换为 prefill 时：

1. **新 worker 的 radix tree 为空** — prefill KvRouter 的 Indexer 没有该 worker 的任何 KV 缓存记录
2. **dedicated worker 可能有缓存** — 如果之前处理过相似前缀，radix tree 中有 overlap
3. **负载平衡** — 如果 dedicated worker 当前空闲，它的 `decode_blocks` 更低

要让 TARGET 一定被选为 prefill worker，可以：
- **设置 `overlap_score_weight=0`** — 完全禁用 KV overlap，纯负载均衡
- **关闭 dedicated prefill worker** — 只剩 TARGET 一个 prefill worker
- **让 dedicated worker 满载** — 其 `decode_blocks` 高于 TARGET

---

## 第四阶段：Prefill 执行

**文件**: `components/src/dynamo/vllm/handlers.py`

### 4.1 请求到达 Prefill Worker

PrefillRouter 通过 Dynamo 的 TCP transport 将请求发送到选中的 prefill worker pod。

传输路径：
```
Frontend (Rust) → TCP connection → Prefill Worker Pod (Python handler)
```

连接基于 `DynamoWorkerMetadata` CR 中注册的 `endpoints`，transport type 编码为 `host:port/{connection_id}/{endpoint_name}`。

### 4.2 PrefillWorkerHandler.generate()

```python
# handlers.py L1588-L1702
class PrefillWorkerHandler:
    def _generate_token_mode(self, request, ...):
        # 1. 提取 token_ids
        token_ids = request["token_ids"]  # [151644, 872, 198, ...]
        
        # 2. 构建 prompt
        prompt = TokensPrompt(prompt_token_ids=token_ids)
        
        # 3. 设置 prefill-only 参数
        sampling_params = SamplingParams(
            max_tokens=1,           # 只生成 1 个 token
            min_tokens=1,
        )
        sampling_params.extra_args["kv_transfer_params"] = {
            "do_remote_decode": True,  # 告诉 NixlConnector: 计算完 KV 后传给 decode worker
        }
        
        # 4. 调用 vLLM 引擎
        result = engine.generate(prompt, sampling_params, request_id)
```

### 4.3 vLLM 引擎内部（prefill 阶段）

```
vLLM AsyncLLMEngine.generate()
  │
  ├─ Scheduler: 将请求排入 prefill queue
  │
  ├─ Model Forward Pass (Qwen3-0.6B):
  │    ├─ Embedding: token_ids → embeddings
  │    ├─ Transformer layers × N:
  │    │    ├─ Self-Attention (计算 Q, K, V)
  │    │    ├─ K, V 写入 GPU KV Cache blocks
  │    │    └─ FFN
  │    └─ Output: 生成第 1 个 token 的 logits
  │
  ├─ NixlConnector.request_finished():
  │    ├─ 读取该请求占用的 GPU block IDs
  │    ├─ 构建 kv_transfer_params:
  │    │    {
  │    │      "do_remote_prefill": false,
  │    │      "do_remote_decode": true,
  │    │      "remote_engine_id": "engine-prefill-xyz",
  │    │      "remote_block_ids": [0, 1, 2],     // GPU block IDs
  │    │      "remote_host": "10.244.0.15",
  │    │      "remote_port": 12345,
  │    │      "remote_request_id": "req-abc"
  │    │    }
  │    └─ 注册 NIXL agent，等待 decode worker 的 READ 请求
  │
  └─ RequestOutput: 包含 kv_transfer_params
```

### 4.4 KV Cache 存储位置

**此时 KV cache 存在 prefill worker pod 的 GPU 显存中。**

对于 "who are you" (~9 tokens, block_size=64)：
- 占用 1 个 GPU KV block（包含 K 和 V 的张量）
- 每个 block 的物理位置由 KVBM 管理
- block ID 例如 `[42]`（物理 block 编号）

### 4.5 _partner_prefill_generate 包装器（dual-mode 时）

当 decode worker 切换为 prefill 模式时，使用 `_partner_prefill_generate` 包装器：

```python
# main.py L1175-L1215
async def _partner_prefill_generate(request, context, handler):
    # vLLM 的 NixlConnector 在最后一个 chunk 才发布 kv_transfer_params
    # 但 Rust PrefillRouter 从第一个 chunk 读取
    # 解决方案：消费整个流，合并为单个 chunk
    
    last_kv_params = None
    all_chunks = []
    async for chunk in handler.generate(request, context):
        if "kv_transfer_params" in chunk.get("disaggregated_params", {}):
            last_kv_params = chunk["disaggregated_params"]["kv_transfer_params"]
        all_chunks.append(chunk)
    
    # 合并：将最后的 kv_transfer_params 放入第一个 chunk
    consolidated = merge_chunks(all_chunks, last_kv_params)
    yield consolidated
```

---

## 第五阶段：KV Transfer (NIXL)

### 5.1 PrefillRouter 提取 KV 参数

```rust
// prefill_router.rs L353-L470
fn execute_prefill():
    // 1. 发送请求到 prefill worker
    let output = router.generate_to_worker(request, target_worker);
    
    // 2. 读取第一个 output chunk
    let first_chunk = output.next().await;
    
    // 3. 提取 disaggregated_params
    let kv_params = first_chunk.data["disaggregated_params"]["kv_transfer_params"];
    
    // 4. 返回 PrefillResult
    PrefillResult {
        disaggregated_params: kv_params,
        prompt_tokens_details: ...,
    }
```

### 5.2 注入到 Decode 请求

PrefillRouter 将 `PrefillResult` 注入 decode 请求：

```rust
decode_request.prefill_result = Some(prefill_result);
decode_request.router_config_override = RouterConfigOverride {
    overlap_score_weight: Some(0.0),    // 不考虑 KV overlap（KV 已通过 NIXL 传输）
    assume_kv_reuse: Some(false),
};
```

---

## 第六阶段：Decode Worker 选择

### 6.1 Decode KvRouter

PrefillRouter 调用 `next.generate(decode_request)`，进入 decode routing。

Decode KvRouter 使用**独立的** Indexer 和 Scheduler（只追踪 `backend` 类型 worker）。

由于 `overlap_score_weight=0.0`（PrefillRouter 注入的 override），decode 选择**纯基于负载**：

```
logit = 0.0 × potential_prefill_blocks + decode_blocks
      = decode_blocks  (只看当前负载)
```

选择 `decode_blocks` 最低的 worker。

### 6.2 对于我们的集群

```
Decode Worker D1 (decode_blocks=3): logit = 3
Decode Worker D2 (decode_blocks=5): logit = 5
→ 选择 D1
```

---

## 第七阶段：Decode 执行

**文件**: `components/src/dynamo/vllm/handlers.py`

### 7.1 DecodeWorkerHandler._generate_token_mode()

```python
# handlers.py L1402-L1560
def _generate_token_mode(self, request, ...):
    # 1. 提取 prefill 结果中的 KV 参数
    prefill_result = request.get("prefill_result")
    kv_params = prefill_result["disaggregated_params"]["kv_transfer_params"]
    # kv_params = {
    #   "do_remote_prefill": True,   # 从远程拉取 KV
    #   "remote_engine_id": "engine-prefill-xyz",
    #   "remote_block_ids": [42],    # prefill worker 的 GPU block IDs
    #   "remote_host": "10.244.0.15",
    #   "remote_port": 12345,
    #   "remote_request_id": "req-abc"
    # }
    
    # 2. 注入到 sampling_params
    sampling_params.extra_args["kv_transfer_params"] = kv_params
    
    # 3. 调用 vLLM 引擎
    result = engine.generate(prompt, sampling_params, request_id)
```

### 7.2 vLLM 引擎内部（decode 阶段）

```
vLLM AsyncLLMEngine.generate()
  │
  ├─ NixlConnectorScheduler.add_new_req_to_recv():
  │    ├─ 解析 kv_transfer_params
  │    ├─ 将请求加入 NIXL receive queue
  │    └─ 在下一个 scheduler step 中：
  │         start_load_kv → _read_blocks:
  │           ├─ NIXL READ: 从 prefill worker GPU 拉取 KV blocks
  │           │   源: 10.244.0.15:12345, block_ids=[42]
  │           │   目标: 本地 GPU block_ids=[17]  (decode worker 分配的)
  │           └─ 等待 RDMA 传输完成
  │
  ├─ Scheduler: KV 加载完成后，开始 decode loop
  │
  ├─ Decode Loop (每步生成 1 个 token):
  │    ├─ 步骤 1: Attention(Q=new_token, K=cached, V=cached)
  │    │   KV cache 来自 NIXL 传输的 blocks
  │    ├─ 步骤 2: FFN
  │    ├─ 步骤 3: Sampling → next_token_id
  │    ├─ 步骤 4: 新 KV 写入 cache，decode_blocks += 1
  │    └─ 步骤 5: yield token_id 到 stream
  │
  └─ 直到 stop condition（max_tokens 或 EOS token）
```

### 7.3 Token Streaming

```python
# handlers.py L1229-L1350
def generate_tokens(self, ...):
    async for output in engine_output_stream:
        # 计算新生成的 token delta
        new_tokens = output.token_ids[last_seen:]
        
        yield {
            "token_ids": new_tokens,        # [15, 1097, 264, ...]
            "finish_reason": None,           # 或 "stop" / "length"
            "completion_usage": {
                "prompt_tokens": 9,
                "completion_tokens": len(all_generated),
                "total_tokens": 9 + len(all_generated),
            }
        }
```

---

## 第八阶段：Backend 反向 — Detokenization

**文件**: `lib/llm/src/backend.rs`

Backend operator 的 backward edge 将 token IDs 解码为文本：

```rust
// token_ids: [15, 1097, 264, 2007, 4221, 3108, ...]
// → text: "I am a large language model..."
```

处理 stop conditions：如果遇到 stop string 或 stop token ID，截断输出。

---

## 第九阶段：HTTP 响应

### 非 streaming 响应

```json
{
  "id": "chatcmpl-abc123",
  "choices": [{
    "index": 0,
    "message": {
      "content": "<think>\nThe user is asking...\n</think>\n\nI am Qwen, a large language model...",
      "role": "assistant"
    },
    "finish_reason": "stop"
  }],
  "usage": {
    "prompt_tokens": 9,
    "completion_tokens": 42,
    "total_tokens": 51
  },
  "nvext": {
    "worker_id": {
      "prefill_worker_id": 5846683276016038,
      "prefill_dp_rank": 0,
      "decode_worker_id": 3205305842231862,
      "decode_dp_rank": 0
    },
    "timing": {
      "prefill_time_ms": 25.07,
      "ttft_ms": 26.21,
      "total_time_ms": 67.29,
      "kv_hit_rate": 0.0
    }
  }
}
```

`nvext.worker_id` 字段明确记录了哪个 worker 做了 prefill，哪个做了 decode。

---

## KV Cache 生命周期总结

```
时间线:
  t0: 请求到达 Frontend
  t1: Preprocessor 将 "who are you" tokenize 为 9 tokens
  t2: PrefillRouter 选择 Prefill Worker P1
  t3: P1 执行 prefill → KV cache 写入 P1 的 GPU blocks [42]
  t4: P1 返回 kv_transfer_params (engine_id, host:port, block_ids=[42])
  t5: PrefillRouter 选择 Decode Worker D1
  t6: D1 通过 NIXL RDMA READ 从 P1:blocks[42] 拉取 KV 到 D1:blocks[17]
  t7: D1 开始 decode loop，每步 attention 使用 blocks[17] 中的 KV
  t8: D1 生成完毕，释放 blocks[17]
  t9: P1 释放 blocks[42]（或被 prefix cache 保留）

KV Cache 位置:
  t3-t9: P1 GPU memory (blocks[42]) — 被 prefix cache 保留以加速后续相似请求
  t6-t8: D1 GPU memory (blocks[17]) — decode 期间使用，完成后释放
```

---

## Discovery 层：DynamoWorkerMetadata CR

每个 worker pod 通过 Rust runtime 向 K8s API 写入自己的 CR：

```yaml
# Decode Worker D1 的 CR
apiVersion: nvidia.com/v1alpha1
kind: DynamoWorkerMetadata
metadata:
  name: vllm-v1-disagg-router-vllmdecodeworker-7663d0d2-84dc55489ccjp8x
spec:
  data:
    model_cards:
      dynamo-system-.../backend/generate/b63356c1f6a36:
        data:
          model_type: "Chat | Completions"
    endpoints:
      dynamo-system-.../backend/generate/b63356c1f6a36:
        transport_type: "tcp://10.244.0.20:8001/cid/generate"
```

Frontend 的 `ModelWatcher` 通过 K8s Watch API 监听这些 CR 的变化，构建 WorkerSet。

---

## S2: Elastic PD Switch 对这个流程的影响

### 切换前（正常状态）

```
Frontend → PrefillRouter → [P1] → NIXL → [D1, D2] → Response
                prefill 池: {P1}
                decode  池: {D1, D2}
```

### 切换 D1 为 prefill 后

`POST D1:9091/switch_role {"target_role":"prefill"}` 触发 DualModeWorker：

1. **K8s 层面**：D1 的 `DynamoWorkerMetadata` CR 更新：
   - 删除 `model_cards.backend/generate/...`（decode）
   - 添加 `model_cards.prefill/generate/...`（prefill）

2. **Dynamo 层面**：
   - Frontend `ModelWatcher` 收到 CR 变更事件
   - Decode KvRouter 移除 D1（`Removed` event）
   - Prefill KvRouter 添加 D1（`Added` event）

3. **路由变化**：
   ```
   Frontend → PrefillRouter → [P1, D1*] → NIXL → [D2] → Response
                   prefill 池: {P1, D1}  (* D1 是切换后的)
                   decode  池: {D2}
   ```

4. **为什么 TARGET (D1) 可能不被选为 prefill**：
   - D1 在 prefill KvRouter 的 radix tree 中是空的（刚加入）
   - P1 如果之前处理过类似前缀，有 overlap 优势
   - 但如果所有请求都是新的，两者 overlap=0，选择纯看负载

### 要让 TARGET 一定被选为 prefill

方法：在测试时禁用 dedicated prefill worker（scale to 0），这样 prefill 池中只有 TARGET。
或者：发送足够多的请求，统计 prefill_worker_id 的分布。

---

## S3: Request Consolidation — Phase A vs Phase B 详解

### 场景设定

假设 D1 上正在处理一个长请求：
```
prompt: "Write a detailed essay about computing history" (30 tokens)
已生成: 1500 tokens (decoded by D1)
还需生成: ~500 tokens
```

**此时 KV Cache 状态**：
```
D1 GPU Memory:
  Block [10]: tokens 0-63 的 KV (prompt 部分)
  Block [11]: tokens 64-127 的 KV
  ...
  Block [33]: tokens 1472-1529 的 KV (最后一个 partial block)
  共约 24 个 blocks
```

### Phase A: Recompute-Prefill（当前默认）

```
步骤 1: POST D1/migrate_out {"request_id": "*"}
  → D1 找到最长的请求 (generated_tokens=1500)
  → D1 从 InProcessRequestRegistry 读取状态:
      prompt_tokens: [tok0, tok1, ..., tok29]      (30 tokens)
      generated_tokens: [tok30, tok31, ..., tok1529] (1500 tokens)
      sampling_params: {temperature: 0.7, max_tokens: 2000}
  → D1 调用 engine.abort(request_id)
  → D1 的 GPU blocks [10-33] 被释放 ← 立即释放！
  → 返回完整状态

步骤 2: POST D2/migrate_in {上面的完整状态}
  → D2 检查 cost-benefit: replay_total = 30 + 1500 = 1530 < 8192 ✓
  → D2 构建 replay prompt: [tok0, ..., tok29, tok30, ..., tok1529]
     即 "原始 prompt + 已生成的全部 token" 作为新的 prefill 输入
  → D2 调用 engine.generate(replay_prompt, sampling_params)
  
  → D2 的 vLLM 执行 prefill:
     ├─ 对 1530 tokens 做 prefill attention
     ├─ 如果 prefix cache 有命中：只需计算未缓存部分
     │   例如: 前 30 tokens 可能已缓存 → 只需 prefill 1500 tokens
     ├─ KV cache 写入 D2 的 GPU blocks [50-73]
     └─ 开始从 token 1530 继续 decode
  
  → D2 继续生成 token 1531, 1532, ...
  → 客户端（通过 previously_emitted_tokens）跳过前 1500 个已发送的 token
```

**重放（replay）的含义**：不是重新 decode，而是将 `prompt + 已生成的 tokens` 作为一个长 prompt 重新 prefill。Prefill 是并行 attention 计算，比逐 token decode 快得多。成本约等于 prefill 1530 tokens 的时间。

**D1 的 KV Cache 去向**：migrate_out 调用 abort 后被**立即释放**。D1 的 GPU 显存中不再有该请求的 KV。

**D2 的正确性保证**：D2 完全重新计算了从 prompt 开始的所有 KV。数学上等价于该请求从一开始就在 D2 上运行。

### Phase B: NIXL KV Transfer（当前代码已实现但默认关闭）

```
步骤 1: POST D1/migrate_out {"request_id": "*"}
  → 同 Phase A，但额外：
  → D1 查找 block IDs: [10, 11, ..., 33]
  → D1 读取 NIXL meta: {engine_id, host, port}
  → D1 abort_request → blocks [10-33] 被释放 ← 问题！
  → 返回包含 kv_transfer_params 的完整状态:
    {
      "kv_transfer_params": {
        "do_remote_prefill": true,
        "remote_engine_id": "engine-D1",
        "remote_block_ids": [10, 11, ..., 33],
        "remote_host": "10.244.0.20",
        "remote_port": 12345,
        "remote_request_id": "req-abc"
      }
    }

步骤 2: POST D2/migrate_in {包含 kv_transfer_params}
  → D2 检查 cost-benefit (同上)
  → D2 将 kv_transfer_params 注入 sampling_params.extra_args
  → D2 调用 engine.generate(replay_prompt, sampling_params)
  
  → D2 的 vLLM/NixlConnector:
     ├─ 读取 kv_transfer_params
     ├─ NIXL RDMA READ: 从 D1:blocks[10-33] 拉取 KV 到 D2:blocks[50-73]
     ├─ ⚠️ 但 D1 的 blocks [10-33] 可能已被释放并重用！
     │   → RDMA 读到的可能是垃圾数据
     └─ decode 继续，但 KV 可能损坏 → 输出错误

⚠️ Block-Hold Race (块持有竞争):
  t1: migrate_out 读取 block_ids = [10-33]
  t2: migrate_out abort → D1 释放 blocks [10-33]
  t3: D1 可能将 block[10] 分配给新请求，写入新 KV
  t4: D2 NIXL READ block[10] → 读到的是新请求的 KV，不是原始的！
```

### Phase A vs Phase B 对比

| 维度 | Phase A (recompute) | Phase B (NIXL transfer) |
|------|-------|---------|
| KV 传输 | 无 — 重新计算 | GPU-to-GPU RDMA |
| 计算成本 | prefill 1530 tokens (~10-50ms) | RDMA transfer (~1-5ms) |
| 安全性 | 完全安全 | 有 block-hold race |
| 正确性 | 数学上等价 | 需要 block-hold 协议 |
| D1 释放时机 | abort 后立即释放 | 需等 D2 确认收到 |
| 实现复杂度 | 低 | 高（需新协议） |
| prefix cache | 可利用（降低成本） | 不适用 |
| D1 能否销毁 | 是（abort 后立即） | 需等 D2 NIXL READ 完成 |

### 为什么当前用 Phase A

1. **安全**：没有 race condition
2. **Prefix cache 优化**：vLLM 的 prefix cache 使 replay 成本大幅降低
3. **实现简单**：不需要跨 pod 协调
4. **D1 可以立即释放**：abort 后 GPU 显存立即可用

### Phase B 需要的 Block-Hold 协议

要安全实现 Phase B，需要：

```
步骤 1: migrate_out (修改版):
  → D1 lookup block_ids
  → D1 标记 blocks 为 "held" (不释放，不重用)
  → D1 abort_request (但 blocks 保持 held)
  → 返回 block_ids + NIXL coords

步骤 2: migrate_in:
  → D2 NIXL READ from D1:held_blocks
  → D2 确认 KV 已接收
  → D2 发送 ACK 到 D1

步骤 3: D1 收到 ACK:
  → D1 释放 held blocks
  → D1 GPU 显存完全释放
```

这需要修改 KVBM 层添加 block-hold API，以及在 D1 和 D2 之间添加 ACK 协议。

---

## 关键组件汇总表

| 组件 | 位置 | 语言 | 职责 |
|------|------|------|------|
| HTTP Server | `lib/llm/src/http/service/openai.rs` | Rust | 接收 OpenAI 格式请求 |
| Preprocessor | `lib/llm/src/preprocessor.rs` | Rust | Chat template + Tokenization |
| PrefillRouter | `lib/llm/src/kv_router/prefill_router.rs` | Rust | Prefill worker 选择 + 编排 |
| KvRouter | `lib/llm/src/kv_router.rs` | Rust | KV-aware worker 选择（cost function） |
| KvScheduler | `lib/llm/src/kv_router/scheduler.rs` | Rust | 负载追踪 + softmax 采样 |
| Indexer | `lib/kv-router/src/indexer.rs` | Rust | Radix tree — 追踪每个 worker 的 KV 缓存 |
| PushRouter | `lib/llm/src/kv_router/push_router.rs` | Rust | TCP push 到选中的 worker |
| Backend | `lib/llm/src/backend.rs` | Rust | Detokenization |
| Migration | `lib/llm/src/migration.rs` | Rust | Worker 故障重试 |
| ModelWatcher | `lib/runtime/src/discovery/kube.rs` | Rust | Watch DynamoWorkerMetadata CR |
| PrefillHandler | `components/src/dynamo/vllm/handlers.py` | Python | vLLM prefill 执行 |
| DecodeHandler | `components/src/dynamo/vllm/handlers.py` | Python | vLLM decode 执行 |
| DualModeWorker | `components/src/dynamo/vllm/dual_mode.py` | Python | PD 角色切换编排 |
| MigrationHandler | `components/src/dynamo/vllm/migration.py` | Python | 请求迁移（migrate_out/in） |
| RL-Scaling Sidecar | `components/src/dynamo/vllm/rl_scaling_sidecar.py` | Python | HTTP sidecar (9091) |
| NixlConnector | vLLM built-in | Python/C++ | GPU-to-GPU KV 传输（RDMA） |
| KVBM | `lib/llm/src/block_manager/` | Rust | KV block 管理（多层缓存） |
| DynamoWorkerMetadata | K8s CRD | YAML | Worker 注册与发现 |
