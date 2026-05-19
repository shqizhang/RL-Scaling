# RL-Driven Elastic Scaling for Disaggregated LLM Inference: Implementing Dynamic PD Role Switch and Request Consolidation on NVIDIA Dynamo

**Subtopic: RL-Scaling-Elastic-PD-Switch-and-Consolidation**

Shengqi ZHANG

## ABSTRACT

Reinforcement Learning (RL) training pipelines exhibit highly bursty inference demands during sampling phases, followed by prolonged idle periods during gradient updates. Traditional static provisioning of GPU inference clusters leads to severe resource waste. This work presents RL-Scaling, an elastic inference scaling system built atop NVIDIA Dynamo's disaggregated Prefill-Decode (PD) architecture, enabling three progressive capabilities: (i) signal-driven pre-warm and scale-to-zero lifecycle management, (ii) runtime Prefill↔Decode role switching without engine restart, and (iii) request consolidation via live KV-cache migration for graceful scale-down. The system achieves end-to-end correctness by maintaining consistency across four layers—Kubernetes service discovery, Dynamo's KV-aware router, vLLM's KV Block Manager (KVBM), and NVIDIA's NIXL interconnect—during dynamic topology changes. We implement and validate the complete system on a production Kubernetes cluster with real GPU workloads, demonstrating successful role switches in under 5 seconds and per-request migration with sub-10ms block-hold overhead.

## 1 INTRODUCTION

### 1.1 Background: RL Training and Inference Co-scheduling

Modern Reinforcement Learning from Human Feedback (RLHF) and online RL training pipelines—such as PPO, GRPO, and DAPO—alternate between two computationally distinct phases:

1. **Sampling Phase**: The policy model generates rollouts for a batch of prompts, requiring high-throughput LLM inference with multiple GPUs serving prefill and decode workloads.
2. **Training Phase**: Gradient computation proceeds on training GPUs while inference GPUs sit completely idle.

This temporal asymmetry creates a fundamental resource utilization problem. In a typical training loop with batch size 64 and 512 average input sequence length, the sampling phase may require 4–8 inference GPUs for 30–60 seconds, followed by minutes of training where those GPUs produce zero useful work.

### 1.2 The Disaggregated PD Architecture

NVIDIA Dynamo implements a disaggregated Prefill-Decode (PD) architecture that physically separates the two phases of autoregressive generation:

- **Prefill Workers**: Compute the full Key-Value (KV) cache for the input prompt in a single forward pass. This is compute-bound and benefits from high batch throughput.
- **Decode Workers**: Generate tokens one at a time using the cached KV states. This is memory-bandwidth-bound and benefits from high concurrency.

This separation enables independent scaling of each role, but introduces the challenge of KV-cache transfer between prefill and decode workers—addressed by NVIDIA's NIXL (NVIDIA Inference eXchange Library) for direct GPU-to-GPU RDMA transport.

### 1.3 Problem Statement

Given the bursty inference pattern of RL training, we identify three escalating requirements:

| Requirement | Challenge |
|---|---|
| **S1**: Elastic scale-up/down | GPU allocation must track sampling lifecycle; cold-start latency must be minimized via pre-warming |
| **S2**: Dynamic PD ratio adjustment | As sampling progresses, the prefill/decode load ratio shifts; fixed allocation wastes capacity |
| **S3**: Graceful consolidation | At batch tail, requests scatter across many partially-idle decoders; consolidation before scale-down avoids request drops |

Each requirement demands progressively deeper integration with Dynamo's routing, discovery, and KV management subsystems. The core technical challenge is **maintaining consistency** across all system layers during dynamic topology changes.

### 1.4 Contributions

This work makes the following contributions:

1. **A complete elastic inference lifecycle system** integrating signal SDK, capacity planner, and Kubernetes operator for RL-aware GPU management.
2. **The first runtime PD role switch** on Dynamo without engine restart, with a formally specified 9-step protocol that maintains router consistency, KV-cache coherence, and service discovery atomicity.
3. **A two-phase request migration protocol** supporting both recompute-prefill (fallback) and NIXL-based KV block transfer (optimal), with cost-benefit gating and stale-hold sweeping for reliability.
4. **End-to-end validation** on a production Kubernetes cluster with 140 unit tests and scripted E2E test suites demonstrating correctness under real GPU workloads.

## 2 RELATED WORK AND MOTIVATION

### 2.1 Disaggregated Inference Systems

**DistServe** [1] and **Splitwise** [2] first proposed separating prefill and decode into distinct resource pools, demonstrating throughput improvements via independent scaling. However, both assume a static PD ratio configured at deployment time.

**NVIDIA Dynamo** [3] extends this concept with a production-grade system featuring KV-aware routing (RadixTree-based prefix matching), NIXL for zero-copy GPU-to-GPU KV transfer, and a Kubernetes-native deployment model. Dynamo provides the infrastructure but does not include elastic scaling capabilities for RL workloads.

**Mooncake** [4] introduces KV-cache-centric disaggregation with distributed DRAM pooling, but focuses on storage efficiency rather than dynamic topology management.

### 2.2 Elastic Inference Scaling

**ServerlessLLM** [5] addresses cold-start optimization for serverless LLM serving but does not handle the PD disaggregation topology. **Spotserve** [6] provides spot instance management for LLM serving with migration capabilities, but operates at the instance level rather than the request level.

None of the existing systems address the specific requirements of RL training: predictable bursty patterns, the need for PD ratio adjustment during a single batch, and graceful request-level consolidation before scale-down.

### 2.3 Motivation: The RL Sampling Lifecycle

```
┌─────────────────────────────────────────────────────────────┐
│  RL Training Loop                                            │
│                                                              │
│  ┌──────────┐  ┌──────────────────┐  ┌──────────────────┐  │
│  │  Sampling │  │  Reward Compute  │  │  Policy Update   │  │
│  │  (30-60s) │  │  (5-10s)         │  │  (60-120s)       │  │
│  │  GPU×8    │  │  GPU×1           │  │  GPU×8 (train)   │  │
│  └──────────┘  └──────────────────┘  └──────────────────┘  │
│       ↑                                                      │
│  Inference GPUs needed ONLY here                             │
└─────────────────────────────────────────────────────────────┘
```

**Figure 1**: Temporal resource utilization in an RL training loop. Inference GPUs are needed only during the sampling phase (shaded), representing 15-30% of total training time.

The sampling phase itself exhibits internal load dynamics:
- **Early phase**: Prefill-heavy (all prompts arrive simultaneously)
- **Mid phase**: Balanced (prefill completing, decode starting)
- **Late phase**: Decode-heavy with declining load (most sequences completing)

This motivates dynamic PD ratio adjustment (S2) and request consolidation (S3) within a single sampling batch.

## 3 SYSTEM ARCHITECTURE OVERVIEW

### 3.1 Component Topology

```
┌──────────────────────────────────────────────────────────────────────┐
│  Kubernetes Cluster (namespace: dynamo-system)                        │
│                                                                        │
│  ┌─────────────────┐     ┌─────────────────────────────────────────┐ │
│  │ RL Training Pod  │     │  Dynamo Graph Deployment (DGD)          │ │
│  │                  │     │                                          │ │
│  │  ┌────────────┐ │ HTTP│  ┌──────────┐   ┌──────────────────┐   │ │
│  │  │Signal SDK  │─┼─────┼─→│Controller│   │   Frontend Pod    │   │ │
│  │  └────────────┘ │     │  │          │   │   (Axum :8000)    │   │ │
│  │                  │     │  │ State    │   │   PrefillRouter   │   │ │
│  │  Training Loop   │     │  │ Machine  │   │   KvRouter        │   │ │
│  │  (veRL/OpenRLHF) │     │  │          │   └────────┬─────────┘   │ │
│  └─────────────────┘     │  │ Capacity │            │              │ │
│                           │  │ Planner  │            │ NATS-RPC     │ │
│                           │  │          │            ▼              │ │
│                           │  │ Role     │   ┌──────────────────┐   │ │
│                           │  │ Switch   │──→│ Worker Pods ×N   │   │ │
│                           │  │          │   │ ┌──────────────┐ │   │ │
│                           │  │ Consoli- │   │ │vLLM Engine   │ │   │ │
│                           │  │ dation   │   │ │(AsyncLLM)    │ │   │ │
│                           │  └─────┬────┘   │ ├──────────────┤ │   │ │
│                           │        │        │ │Dynamo Handler│ │   │ │
│                           │        │ HTTP   │ ├──────────────┤ │   │ │
│                           │        └───────→│ │RL Sidecar    │ │   │ │
│                           │                 │ │(:9091)       │ │   │ │
│                           │                 │ └──────────────┘ │   │ │
│                           │                 └──────────────────┘   │ │
│                           │                                          │ │
│  ┌──────────┐            │  ┌─────────────┐                        │ │
│  │Prometheus│            │  │ DGDSA CR    │←── patch replicas       │ │
│  │(:9090)   │            │  │ (scaling)   │                         │ │
│  └──────────┘            │  └─────────────┘                        │ │
└──────────────────────────────────────────────────────────────────────┘
```

**Figure 2**: System component topology. The RL Signal SDK emits lifecycle signals to the Controller, which orchestrates scaling via DGDSA CRs and runtime operations via HTTP to worker sidecars.

### 3.2 Layered Architecture

The system operates across five distinct layers, each with specific consistency requirements:

| Layer | Component | Role | Consistency Requirement |
|-------|-----------|------|------------------------|
| L1 | RL Training | Signal emission | Temporal ordering of lifecycle events |
| L2 | Controller | Decision & orchestration | Monotonic state transitions, idempotent actions |
| L3 | Kubernetes | Resource management | DGDSA replicas ↔ actual pods |
| L4 | Dynamo Runtime | Routing & discovery | MDC registry ↔ active workers |
| L5 | vLLM Engine | Inference execution | KV-cache state ↔ router's radix tree |

**Key Insight**: A PD role switch or request migration must maintain consistency across L3–L5 simultaneously. Partial updates (e.g., MDC updated but KV-cache stale) lead to routing errors or data corruption.

### 3.3 Communication Protocols

| Path | Protocol | Purpose |
|------|----------|---------|
| SDK → Controller | HTTP (sync) | Signal delivery |
| Controller → DGDSA | K8s API (PATCH) | Replica scaling |
| Controller → Sidecar | HTTP (:9091) | Role switch / migration commands |
| Frontend → Workers | NATS-RPC | Inference requests |
| Workers → Router | ZMQ → NATS Core | KV-cache events |
| Workers → etcd | gRPC | MDC registration/discovery |
| Workers → Workers | NIXL (RDMA/NVLink) | KV-block transfer |

## 4 KV-AWARE ROUTING AND PREFIX TREE

### 4.1 KvRouter Architecture

The KvRouter is the central routing decision engine in Dynamo's disaggregated inference pipeline. It selects the optimal decode worker for each request based on KV-cache overlap, minimizing redundant computation.

```
Request Tokens ──→ compute_block_hash_for_seq()
                        │
                        ▼
                   Block Hashes [h₀, h₁, ..., hₙ]
                        │
                        ▼
              Indexer.find_matches()
              ┌─────────────────────────┐
              │      RadixTree          │
              │  root                   │
              │   ├─[h₀]→{W1,W2,W3}   │
              │   │  ├─[h₁]→{W1,W2}   │
              │   │  │  └─[h₂]→{W1}   │
              │   │  └─[h₃]→{W3}      │
              │   └─[h₄]→{W4}         │
              └─────────────────────────┘
                        │
                        ▼
              OverlapScores: {W1:3, W2:2, W3:1, W4:0}
                        │
                        ▼
              KvScheduler.schedule()
              logit(w) = α·overlap + β·queue + γ·capacity
                        │
                        ▼
              Best Worker: W1 (3 blocks cached)
```

**Figure 3**: KvRouter request routing flow. Block hashes are matched against the RadixTree to find KV-cache overlap per worker, then combined with load metrics for final selection.

### 4.2 RadixTree Implementation

The RadixTree (located in `lib/kv-router/src/radix_tree.rs`) is a prefix-match data structure mapping token block hash sequences to worker sets:

```rust
struct RadixBlock {
    children: FxHashMap<LocalBlockHash, SharedRadixBlock>,
    workers: FxHashSet<WorkerWithDpRank>,
    block_hash: Option<ExternalSequenceBlockHash>,
    recent_uses: VecDeque<Instant>,  // frequency tracking
}
```

**Matching Algorithm** (`find_matches`):
1. Lookup `sequence[0]` in root children → initialize `active_workers`
2. For each subsequent hash, follow children; workers drop out when they lack the next block
3. Workers surviving to depth N score N matched blocks
4. **Early-exit**: when only 1 worker remains, immediately return
5. **Stale-entry detection**: if child workers exceed active set, a Remove event hasn't propagated → full membership check

### 4.3 Prefix Hit Patterns

| Scenario | Hit Pattern | Routing Effect |
|----------|------------|----------------|
| Same system prompt | First N blocks match | Sticky routing to same worker |
| Multi-turn dialogue | History prefix hits | Conversation affinity |
| First request | No match | Falls back to load balancing |
| LoRA switch | Hash seed changes | Natural LoRA isolation |
| Post role-switch | `Cleared` event fired | Worker tree wiped, fresh start |

The last row is critical for S2: after a role switch, the switched worker's entire subtree in the RadixTree is cleared via a `KvCacheEventData::Cleared` event, ensuring the router does not route requests to a worker based on stale KV-cache state.

### 4.4 Event-Driven Tree Maintenance

```
vLLM Engine ──ZMQ PUB──→ ZMQ Listener (Rust)
                              │
                              ▼
                     KvEventPublisher
                     ├─ LocalKvIndexer [ring buffer, size=1024]
                     └─ EventPublisher ──NATS Core──→ Router
                                                       │
                                                       ▼
                                              EventSubscriber
                                              ├─ Gap detection (monotonic event_id)
                                              │   └─ Recovery from LocalKvIndexer
                                              └─ Indexer.apply_event()
                                                  └─ RadixTree update
```

**Figure 4**: KV-cache event propagation from vLLM engine to router's RadixTree. Gap detection and recovery ensure eventual consistency despite transient network issues.

**Consistency Guarantee**: Events use monotonic `event_id` per (worker, dp_rank). If `received_id > last_id + 1`, the router triggers gap recovery from the worker's ring buffer. This provides **eventual consistency** with bounded recovery time.

## 5 KV BLOCK MANAGER (KVBM)

### 5.1 Block Lifecycle State Machine

```
                    allocate_blocks()
    ResetPool ─────────────────────────→ MutableBlock (ActivePool)
        ▲                                       │
        │                               stage() / complete()
        │ drop                                  ▼
        │                               CompleteBlock
        │                                       │
        │                               register_block()
        │                                       ▼
        └──────────────────────── ImmutableBlock (InactivePool)
                                        │              ▲
                                downgrade()         upgrade()
                                        ▼              │
                                    WeakBlock ─────────┘
```

**Figure 5**: KVBM block state machine. All transitions are RAII-enforced—dropping any guard automatically returns the block to the appropriate pool.

### 5.2 Three-Tier Pool Architecture

| Pool | Contents | Evictable? | Role |
|------|----------|-----------|------|
| `ResetPool` | Free blocks | N/A | Available for allocation |
| `ActivePool` | In-use blocks (pinned) | No | Currently serving requests |
| `InactivePool` | Cached blocks (LRU) | Yes | Prefix reuse candidates |

**Allocation strategy** (`allocate_blocks(count)`):
1. Pull from ResetPool (free list)
2. If insufficient → evict from InactivePool (TinyLFU frequency-based)
3. If still insufficient → OOM (request rejected)

**Eviction policy**: TinyLFU (`FrequencyTrackingCapacity`) combines recency (LRU) with frequency information, providing better resistance to scan-induced cache thrashing than pure LRU.

### 5.3 KVBM and Role Switch (S2)

When a worker switches roles, `DualModeWorker._reconfig_kv_pool()` calls `engine.reset_prefix_cache()`, which triggers:

1. `InactivePool` → drain all blocks back to `ResetPool`
2. All registered block hashes are invalidated
3. `EventReleaseHandle::drop()` fires → broadcasts `KvCacheEvent::Remove` for each evicted block
4. Router receives bulk Remove events → prunes worker from RadixTree

This ensures the router's view is consistent with the worker's actual KV-cache state after role switch.

### 5.4 KVBM and Migration (S3)

During request migration, `RequestBlockIndex.get_block_ids(request_id)` retrieves the physical GPU block IDs for an in-flight request. These IDs are included in `kv_transfer_params` for NIXL-based D2D transfer. The block-hold protocol ensures these blocks remain in the `ActivePool` (non-evictable) until migration completes or times out.

## 6 NIXL: GPU-TO-GPU KV TRANSFER

### 6.1 Architecture

NIXL (NVIDIA Inference eXchange Library) provides high-performance data transport between GPU memories, supporting RDMA, NVLink, and TCP protocols. In Dynamo's PD disaggregation:

```
Prefill Worker                              Decode Worker
┌────────────────────┐                ┌────────────────────┐
│ GPU Memory         │                │ GPU Memory         │
│ ┌────────────────┐ │                │ ┌────────────────┐ │
│ │ KV Blocks      │ │   NIXL RDMA   │ │ KV Blocks      │ │
│ │ [B0][B1][B2]   │─┼──────────────→│ │ [B0][B1][B2]   │ │
│ └────────────────┘ │  (zero-copy)  │ └────────────────┘ │
│                    │                │                    │
│ NixlConnector      │                │ NixlConnector      │
│ (kv_role=kv_both)  │                │ (kv_role=kv_both)  │
└────────┬───────────┘                └────────┬───────────┘
         │                                     │
         │         TCP Side Channel            │
         └─────────────────────────────────────┘
              (metadata exchange: block descriptors,
               remote memory addresses)
```

**Figure 6**: NIXL architecture for KV-cache transfer. Data moves directly GPU-to-GPU via RDMA/NVLink. The TCP side channel only carries lightweight metadata.

### 6.2 Configuration

NIXL is configured at engine startup via `--kv-transfer-config`:
```json
{"kv_connector": "NixlConnector", "kv_role": "kv_both"}
```

**Critical constraint**: The connector must be specified at engine construction time. It cannot be added to a running engine. This is why `DYNAMO_RL_DUAL_MODE=1` requires pre-configuring the connector—the same engine must function in both prefill and decode roles.

### 6.3 NIXL in Role Switch (S2)

During role switch, `DualModeWorker._reconfig_nixl()`:
1. Sets `handler._nixl_connector = None`
2. Calls `shutdown()/close()` on the old connector handle
3. New role's first request triggers lazy re-initialization

The connector instance is per-role but shares the same underlying NIXL agent (which persists across switches). The side-channel endpoint remains stable.

### 6.4 NIXL in Migration (S3)

The `kv_transfer_params` dictionary passed during migration matches vLLM 0.16's `NixlConnectorScheduler` interface:

```python
kv_transfer_params = {
    "do_remote_prefill": True,
    "do_remote_decode": False,
    "remote_engine_id": "<source_engine_uuid>",
    "remote_block_ids": [12, 45, 78, ...],  # physical GPU block IDs
    "remote_host": "10.233.x.y",
    "remote_port": 14579,
    "remote_request_id": "req-abc-123",
}
```

The destination worker's `NixlConnectorScheduler.add_new_req_to_recv()` initiates an RDMA READ from the source worker's GPU memory, pulling the KV blocks directly without CPU involvement.

## 7 SERVICE DISCOVERY AND MDC

### 7.1 Model Deployment Card (MDC)

Each worker registers a Model Deployment Card in etcd describing its capabilities:

```rust
pub struct ModelDeploymentCard {
    name: String,              // model name
    model_type: ModelType,     // Chat | Prefill | Completions
    model_input: ModelInput,   // Tokens | Text
    runtime_config: ModelRuntimeConfig {
        total_kv_blocks: u32,
        max_num_seqs: u32,
        max_num_batched_tokens: u32,
        ...
    },
    kv_cache_block_size: u32,
    mdcsum: String,            // config checksum
}
```

**etcd path**: `v1/mdc/{namespace}/{component}/{endpoint}/{instance_id}`

### 7.2 Discovery in Role Switch (S2)

The `VllmReregistrar` manages MDC lifecycle during role switch:

```
switch_role(decode → prefill):
  1. unregister("decode")     → etcd DELETE old MDC
                              → Router receives DiscoveryEvent::Removed
                              → Worker removed from decode WorkerSet
  
  2. register("prefill")      → etcd PUT new MDC (ModelType::Prefill)
                              → Router receives DiscoveryEvent::Added
                              → Worker added to prefill WorkerSet
                              → PrefillRouter re-activation (if first prefill)
```

**Consistency**: The unregister→register sequence ensures the router never routes to a worker in the wrong role. The `sleep(level=2)` step preceding unregistration drains all in-flight requests first.

### 7.3 WorkerSet Isolation

Workers are grouped into `WorkerSet`s keyed by `(namespace, role)`:
- Decode: key = `"{namespace}"`
- Prefill: key = `"{namespace}:prefill"`

This prevents the KvRouter from mixing prefill and decode workers in the same routing decisions.

## 8 S2: ELASTIC PD ROLE SWITCH

### 8.1 Problem Statement

Given a running DGD with P prefill workers and D decode workers, dynamically change the ratio to P' prefill and D' decode workers without:
- Dropping in-flight requests
- Corrupting router state
- Leaving stale KV-cache references
- Requiring pod recreation or engine restart

### 8.2 Controller Decision Logic

The `ElasticRoleSwitchController` evaluates every control loop tick (5s), gated by `min_switch_interval_seconds` (30s):

**Decode → Prefill trigger**:
$$\text{prefill\_queue\_depth} \geq T_{\text{prefill}} \quad \wedge \quad \text{decode\_util} \leq T_{\text{idle}} \quad \wedge \quad D > D_{\min}$$

**Prefill → Decode trigger**:
$$\text{decode\_queue\_depth} \geq T_{\text{decode}} \quad \wedge \quad \text{prefill\_util} \leq T_{\text{idle}} \quad \wedge \quad P > P_{\min}$$

Worker selection: `find_most_idle_worker()` → worker with minimum `in_flight_requests`.

### 8.3 The 9-Step Switch Protocol

```
┌─────────────────────────────────────────────────────────────────┐
│  DualModeWorker.switch_role(target_role="prefill")              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Step 1: handler.sleep(level=2)                                 │
│          ├─ Unregister generate endpoint from discovery         │
│          ├─ Drain all in-flight requests (await completion)     │
│          └─ Release GPU memory (vLLM sleep)                     │
│                                                                  │
│  Step 2: Unregister partner endpoint (if exists)                │
│          └─ Remove dual-mode extra registration                 │
│                                                                  │
│  Step 3: reregistrar.unregister(old_role="decode")             │
│          └─ etcd DELETE MDC → Router removes from WorkerSet     │
│                                                                  │
│  Step 4: _reconfig_nixl(target_role)                           │
│          ├─ Shutdown old NixlConnector handle                   │
│          └─ Set handler._nixl_connector = None (lazy reinit)    │
│                                                                  │
│  Step 5: _reconfig_kv_pool(target_role)                        │
│          ├─ engine.reset_prefix_cache()                         │
│          ├─ InactivePool → drain all to ResetPool              │
│          └─ Fire KvCacheEvent::Remove for all evicted blocks    │
│                                                                  │
│  Step 6: handler.set_disaggregation_mode("prefill")            │
│          └─ Persist new role on handler state                   │
│                                                                  │
│  Step 7: reregistrar.register(new_role="prefill")              │
│          └─ etcd PUT new MDC → Router adds to prefill WorkerSet│
│                                                                  │
│  Step 8: handler.wake_up()                                      │
│          ├─ Restore GPU memory (vLLM wake_up)                   │
│          └─ Re-register generate endpoint                       │
│                                                                  │
│  Step 9: Register partner endpoint (if dual-partner mode)       │
│          └─ Additional prefill endpoint registration            │
│                                                                  │
│  Step 10: _emit_role_changed()                                  │
│           ├─ Patch pod label: nvidia.com/dynamo-current-role    │
│           └─ Publish role_changed event                         │
│                                                                  │
│  ⚠️ On ANY exception:                                           │
│     → reregistrar.register(old_role)                            │
│     → handler.wake_up()                                         │
│     → restore _disaggregation_mode                              │
│     (Worker never left stuck in broken state)                   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Figure 7**: The 9-step PD role switch protocol with failure recovery. Each step addresses a specific consistency layer.

### 8.4 Consistency Analysis

| Step | Layer Affected | Consistency Guarantee |
|------|---------------|----------------------|
| 1 | L4 (Router) | No new requests routed to this worker |
| 1 | L5 (Engine) | All in-flight requests complete before state change |
| 3 | L4 (Discovery) | Router removes worker from old-role WorkerSet |
| 4 | L5 (NIXL) | Old connector handles released; no dangling references |
| 5 | L5 (KVBM) | All cached blocks freed; Remove events propagated to router |
| 7 | L4 (Discovery) | Router adds worker to new-role WorkerSet |
| 8 | L5 (Engine) | GPU memory restored; ready for new-role requests |

**The critical invariant**: At no point during the switch can the router send a request to the worker. This is guaranteed by the sleep(level=2) → unregister → ... → register → wake_up sequence.

### 8.5 Kubernetes Integration

```
Controller                    K8s API              Pod
    │                            │                  │
    │  POST /switch_role         │                  │
    │──────────────────────────────────────────────→│
    │                            │                  │ (9-step protocol)
    │                            │                  │
    │                            │  PATCH pod label │
    │                            │←─────────────────│
    │                            │                  │
    │  ← {"status":"ok",        │                  │
    │     "switch_time_ms":4500} │                  │
    │←──────────────────────────────────────────────│
```

The switch is an **in-place operation**: no pod deletion or creation. The DGDSA replica count for each role is adjusted by the controller only when needed for actual scale-up/down (S1), not for role switches (S2). This avoids K8s scheduler involvement and achieves sub-5-second switch times.

### 8.6 The Partner-Prefill Fix

A critical vLLM integration issue was discovered and fixed: vLLM's `NixlConnector` only sets `kv_transfer_params` on the **last** streamed chunk, but Dynamo's Rust `PrefillRouter` reads `disaggregated_params` from the **first** chunk.

**Solution** (`_partner_prefill_generate` wrapper in `main.py`):
```python
async def _partner_prefill_generate(request):
    chunks = []
    async for chunk in handler.generate(request):
        chunks.append(chunk)
    # Capture kv_transfer_params from last chunk
    kv_params = chunks[-1].kv_transfer_params
    # Emit single consolidated chunk with params
    consolidated = merge(chunks)
    consolidated.kv_transfer_params = kv_params
    yield consolidated
```

This ensures the PrefillRouter correctly receives the NIXL transfer metadata regardless of which chunk vLLM places it on.

## 9 S3: REQUEST CONSOLIDATION

### 9.1 Problem Statement

At batch tail (e.g., 60%+ requests completed), remaining in-flight requests may be distributed across many decode workers, each with only 1–3 active requests. Scaling down would drop these requests. Consolidation migrates them to fewer workers, freeing workers for scale-down.

### 9.2 Controller Decision Engine

The `ConsolidationDecisionEngine` uses a two-pointer algorithm:

**Eligibility gates**:
$$\text{batch\_pct} \geq T_{\text{batch}} \quad \wedge \quad |\text{workers}| > D_{\min}$$

**Pairing algorithm**:
1. Sort workers by `in_flight_requests` ascending
2. Two pointers: `i` (source, low-load) and `j` (target, high-capacity)
3. Source eligible if `in_flight[i] ≤ T_{\text{consolidation}}` (default 3)
4. Migration issued only if: `migration_time < 0.5 × estimated_remaining_time`

### 9.3 Two-Phase Migration Protocol

```
┌────────────────────────────────────────────────────────────────┐
│  Phase 2.A: Recompute-Prefill (Fallback)                       │
├────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Source Worker              Orchestrator           Dest Worker  │
│       │                         │                      │       │
│       │← POST /migrate_out ─────│                      │       │
│       │  {request_id: "*"}      │                      │       │
│       │                         │                      │       │
│       │─ response: ─────────────│                      │       │
│       │  {prompt_tokens,        │                      │       │
│       │   generated_tokens,     │                      │       │
│       │   sampling_params}      │                      │       │
│       │                         │                      │       │
│       │  (request aborted       │                      │       │
│       │   immediately)          │                      │       │
│       │                         │── POST /migrate_in ─→│       │
│       │                         │  {new_prompt =       │       │
│       │                         │   prompt+generated}  │       │
│       │                         │                      │       │
│       │                         │←─ {status: ok,  ─────│       │
│       │                         │    path: recompute}  │       │
│       │                         │                      │       │
└────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────┐
│  Phase 2.B: NIXL Block Transfer (Optimal)                      │
├────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Source Worker              Orchestrator           Dest Worker  │
│       │                         │                      │       │
│       │← POST /migrate_out ─────│                      │       │
│       │  {request_id: "*"}      │                      │       │
│       │                         │                      │       │
│       │─ response: ─────────────│                      │       │
│       │  {prompt_tokens,        │                      │       │
│       │   generated_tokens,     │                      │       │
│       │   kv_transfer_params:   │                      │       │
│       │    {remote_block_ids,   │                      │       │
│       │     remote_host/port}}  │                      │       │
│       │                         │                      │       │
│       │  (blocks HELD, request  │                      │       │
│       │   NOT aborted yet)      │                      │       │
│       │                         │── POST /migrate_in ─→│       │
│       │                         │  {kv_transfer_params}│       │
│       │                         │                      │       │
│       │     ◄═══ NIXL RDMA READ ═══════════════════════│       │
│       │     (GPU-to-GPU, zero-copy)                    │       │
│       │                         │                      │       │
│       │                         │←─ {status: ok,  ─────│       │
│       │                         │    path: connector}  │       │
│       │                         │                      │       │
│       │← POST /migration_complete                      │       │
│       │  (abort source, free blocks)                   │       │
│       │                         │                      │       │
└────────────────────────────────────────────────────────────────┘
```

**Figure 8**: Two migration paths. Phase 2.A (recompute) is the universal fallback; Phase 2.B (NIXL) is the zero-copy optimal path requiring KVBM block IDs and NIXL connectivity.

### 9.4 Cost-Benefit Gate

The `MigrationPolicy` prevents counterproductive migrations:

```python
class MigrationPolicy:
    max_replay_tokens: int = 8192    # Don't recompute if too many tokens
    min_generated_tokens: int = 16   # Don't migrate nearly-new requests
    min_remaining_tokens: int = 32   # Don't migrate nearly-done requests
```

A migration is rejected if:
- Recompute cost (`prompt + generated tokens`) exceeds `max_replay_tokens`
- The request has generated too few tokens (not worth the overhead)
- The request is estimated to complete soon (remaining < threshold)

### 9.5 Block-Hold Consistency Protocol

The block-hold mechanism is the key to Phase 2.B correctness:

```
Timeline:
t0: migrate_out() → add to _pending_migrations
    │  Blocks remain in ActivePool (pinned, non-evictable)
    │  Request continues executing on source (generating tokens)
    │
t1: NIXL RDMA READ begins on destination
    │  Source blocks must remain stable during transfer
    │
t2: Transfer complete → migration_complete()
    │  Source request aborted → blocks released
    │  Blocks move Active → Reset pool
    │
t_timeout: If t2 never arrives within HOLD_TIMEOUT (10s)
    │  sweep_stale_migrations() fires
    │  Force-abort source request
    │  Blocks freed (prevents indefinite memory leak)
```

**Consistency guarantees**:
1. Source blocks never evicted during transfer (active pool pinned)
2. Stale holds automatically cleaned up (10s timeout + 2s sweep interval)
3. Rollback path restores source execution (request continues as if nothing happened)

### 9.6 InProcessRequestRegistry Design

A subtlety in the implementation: migrated-in requests do NOT appear in the source worker's `InProcessRequestRegistry`. The registry only tracks requests that entered through the normal handler routing path. Migrated requests are submitted directly to `EngineRequestTracker.submit_request()` → vLLM's `AsyncLLM.generate()`.

**Implication**: Migration verification cannot use registry membership on the destination. Instead, the system verifies:
- `left_D1 = true`: Request ID disappeared from source registry
- `D2_accepted = true`: `/migrate_in` response contains `path=recompute` or `path=connector`

## 10 RL-SCALING CONTROLLER

### 10.1 State Machine

```
         sampling_progress              ready >= target
  IDLE ───────────────────→ WARM_UP ─────────────────→ ACTIVE
   ▲                           │                          │
   │                           │ batch_complete           │ batch_complete
   │      cooldown +           ▼                          ▼
   └──── drain complete ── COOL_DOWN ←────────────────────┘
```

**Figure 9**: Controller state machine. Transitions are triggered by SDK signals (sampling_progress, batch_complete) and system observations (pod readiness, drain completion).

### 10.2 Capacity Planner

Translates batch metadata into scaling targets:

$$N_{\text{prefill}} = \left\lceil \frac{\text{batch\_size} \times \text{avg\_isl}}{\text{single\_prefill\_tps} \times \text{target\_prefill\_seconds}} \right\rceil$$

$$N_{\text{decode}} = \left\lceil \frac{\text{batch\_size}}{\text{max\_concurrent\_per\_decode}} \right\rceil$$

Subject to:
$$N_{\text{prefill}} + N_{\text{decode}} \leq \text{max\_gpus}$$

Priority: prefill gets first allocation; decode uses remainder.

### 10.3 Control Loop Architecture

```python
async def _control_loop():
    while True:
        # S1: State machine tick
        await state_machine.control_loop_tick()
        
        # S2: Role switch evaluation (if enabled)
        if role_switch_enabled:
            await role_switch_controller.tick()
        
        # S3: Consolidation evaluation (if enabled)  
        if consolidation_enabled:
            await consolidation_controller.tick()
        
        await asyncio.sleep(control_loop_interval)
```

## 11 TESTING AND VALIDATION

### 11.1 Test Architecture

The system employs a test pyramid with 140 total tests:

| Level | Count | Scope |
|-------|-------|-------|
| Unit Tests | 72 | Controller logic (state machine, planner, role switch, consolidation) |
| Unit Tests | 68 | Dynamo-side (dual_mode, migration, sidecar) |
| E2E Tests | 2 | Full-cluster scripted tests (S2, S3) |

### 11.2 E2E Test: S2 Elastic PD Switch

**Test script**: `test-s2-elastic.sh`

**Procedure**:
1. Verify initial state: 2 decode workers, 1 prefill worker
2. Send `/switch_role {"target_role":"prefill"}` to one decoder
3. Verify: worker appears in prefill WorkerSet (MDC check)
4. Send inference request → verify prefill routing includes switched worker
5. Switch back → verify decode routing restored
6. Assert: 0 HTTP errors during switch, 0 log 503s in test window

**Result**: PASS — switch completes in ~4.5s, zero request drops.

### 11.3 E2E Test: S3 Request Consolidation

**Test script**: `test-s3-consolidation.sh`

**Procedure**:
1. Send 6 long-running requests distributed across 2 decode workers
2. For each migration: `POST /migrate {"source": D1, "target": D2, "request_id": "*"}`
3. Verify per-request: `left_D1=true` (gone from source registry) AND `D2_accepted=true` (migration path confirmed)
4. Assert: all 6 migrations succeed, no orphaned blocks

**Result**: PASS — 6/6 MIG_OK, path=recompute (NIXL path validated separately via connector enabled configuration).

### 11.4 Correctness Criteria

| Property | Verification Method |
|----------|-------------------|
| No request drops during switch | HTTP error counter = 0 during test window |
| Router consistency | MDC presence in etcd matches worker role |
| KV-cache coherence | RadixTree `Cleared` event observed after switch |
| Block-hold safety | No OOM during concurrent migrations |
| Stale hold cleanup | Sweeper test: inject timeout → verify abort |

## 12 DISCUSSION AND FUTURE WORK

### 12.1 Current Limitations

1. **KV-cache size not resized on switch**: `reset_prefix_cache()` clears cached blocks but doesn't adjust the total KV-cache allocation. Prefill and decode share the same pool size, which is suboptimal (prefill benefits from larger blocks, decode from more concurrent slots).

2. **PrefillRouter one-time activation**: The PrefillRouter activates via a `oneshot::Receiver` when the first prefill MDC appears. If all prefill workers are removed and re-added, the router may not re-activate. This is a Dynamo upstream limitation.

3. **Recompute-prefill overhead**: Without NIXL block transfer, migration cost is proportional to `prompt_tokens + generated_tokens`. For long contexts (>8K tokens), this overhead may exceed the benefit.

4. **Single-node validation**: Current E2E tests run on a single-node cluster with one GPU. Multi-node RDMA transfer has been validated via NIXL metrics but not in the full migration E2E flow.

### 12.2 Future Work

**Short-term**:
- Implement KVBM block ID availability in dual-mode workers (currently returns None due to uninitialized block mapping)
- Add Prometheus-based metric-driven role switch decisions (currently queue-depth simulated)
- Enable true multi-node NIXL migration E2E testing

**Medium-term**:
- Dynamic KV-cache resizing on role switch (requires vLLM `_initialize_kv_caches` re-execution)
- Integration with veRL/OpenRLHF training frameworks for production signal emission
- Multi-DGD support (scale across multiple model deployments)

**Long-term**:
- Predictive scaling using RL training batch size forecasting
- Cross-cluster migration for geo-distributed training
- Integration with NVIDIA DGX Cloud orchestration APIs

### 12.3 Lessons Learned

1. **Consistency is the hard problem**: The actual role switch logic is straightforward; ensuring all system layers (router, KVBM, NIXL, discovery) remain consistent during transitions required understanding five separate codebases.

2. **vLLM integration requires pragmatic workarounds**: The chunk ordering bug (kv_transfer_params on last vs. first chunk) was not documented—it required reading both the Rust router and Python connector source.

3. **Block-hold is essential for correctness**: Initial migration designs aborted the source request immediately. This caused race conditions where NIXL read from freed GPU memory. The hold protocol eliminates this class of bugs.

4. **Kubernetes in-place updates are underutilized**: Role switching via pod label + discovery update is far faster than pod replacement. The K8s API was sufficient without custom CRDs for the switch itself.

## REFERENCES

[1] Y. Zhong, S. Liu, J. Chen, et al., "DistServe: Disaggregating Prefill and Decoding for Goodput-optimized Large Language Model Serving," in *OSDI*, 2024.

[2] P. Patel, E. Choukse, C. Zhang, et al., "Splitwise: Efficient Generative LLM Inference Using Phase Splitting," in *ISCA*, 2024.

[3] NVIDIA, "Dynamo: A Disaggregated Inference Serving Framework," GitHub, 2024. [Online]. Available: https://github.com/ai-dynamo/dynamo

[4] R. Qin, Z. Li, W. He, et al., "Mooncake: Trading More Storage for Less Computation—A KVCache-Centric Architecture for Serving LLM Chatbot," in *FAST*, 2025.

[5] Y. Fu, L. Xue, S. Huang, et al., "ServerlessLLM: Low-Latency Serverless Inference for Large Language Models," in *OSDI*, 2024.

[6] X. Miao, C. Shi, J. Duan, et al., "SpotServe: Serving Generative Large Language Models on Preemptible Instances," in *ASPLOS*, 2024.

[7] W. Kwon, Z. Li, S. Zhuang, et al., "Efficient Memory Management for Large Language Model Serving with PagedAttention," in *SOSP*, 2023.

[8] L. Zheng, L. Yin, Z. Xie, et al., "SGLang: Efficient Execution of Structured Language Model Programs," in *NeurIPS*, 2024.

[9] NVIDIA, "NIXL: NVIDIA Inference eXchange Library," GitHub, 2024. [Online]. Available: https://github.com/ai-dynamo/nixl

[10] L. Zheng, Z. Huang, C. H. Yu, et al., "vLLM: Easy, Fast, and Cheap LLM Serving with PagedAttention, Quantization, and Optimized CUDA Kernels," GitHub, 2024.

## APPENDIX A: ENVIRONMENT CONFIGURATION

| Component | Version/Configuration |
|-----------|----------------------|
| Kubernetes | 1.34.1 (single-node, containerd) |
| NVIDIA GPU Operator | Pre-installed |
| Dynamo | 1.0.1 (branch: rl-scaling) |
| vLLM | 0.16 (built-in with Dynamo image) |
| NIXL | Bundled in Dynamo container |
| Model | Qwen/Qwen3-0.6B |
| Python | 3.12 |
| Container Image | ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-2ec0978618 |
| Controller Image | ghcr.io/shqizhang/rl-scaling-controller:latest |

## APPENDIX B: SIDECAR HTTP API

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/healthz` | GET | Health check |
| `/v1/role` | GET | Current worker role |
| `/switch_role` | POST | Trigger role switch |
| `/migrate_out` | POST | Export request state |
| `/migrate_in` | POST | Import request state |
| `/migration_complete` | POST | Acknowledge successful migration |
| `/migration_rollback` | POST | Cancel pending migration |
| `/migrate` | POST | Full coordinated migration |
| `/v1/active_requests` | GET | List active request IDs |

## APPENDIX C: CONFIGURATION REFERENCE

### Controller Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PRE_WARM_THRESHOLD` | 0.8 | Sampling progress to trigger pre-warm |
| `COOLDOWN_SECONDS` | 30 | Grace period before scale-to-zero |
| `DRAIN_TIMEOUT_SECONDS` | 60 | Max drain wait |
| `CONTROL_LOOP_INTERVAL` | 5.0 | Control loop period (seconds) |
| `SINGLE_PREFILL_TPS` | 50000 | Tokens/sec per prefill worker |
| `MAX_CONCURRENT_PER_DECODE` | 64 | Max concurrent sequences per decode worker |
| `MAX_GPUS` | 8 | GPU ceiling |
| `ROLE_SWITCH_ENABLED` | false | Enable S2 |
| `CONSOLIDATION_ENABLED` | false | Enable S3 |
| `PREFILL_QUEUE_THRESHOLD` | 10 | Queue depth triggering decode→prefill |
| `DECODE_QUEUE_THRESHOLD` | 10 | Queue depth triggering prefill→decode |
| `MIN_SWITCH_INTERVAL` | 30.0 | Minimum interval between switches |
| `CONSOLIDATION_THRESHOLD` | 3 | Max in-flight on consolidation source |
| `MIN_BATCH_COMPLETION` | 0.6 | Batch completion % to start consolidation |

### Worker Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DYNAMO_RL_SIDECAR_PORT` | 9091 | Sidecar listen port |
| `DYNAMO_RL_DUAL_MODE` | unset | Enable dual-mode (set to 1) |
| `DYNAMO_RL_CONNECTOR_ENABLED` | unset | Enable NIXL migration path (set to 1) |
| `DYNAMO_RL_MIGRATION_HOLD_TIMEOUT` | 10.0 | Block-hold timeout (seconds) |
