#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# complete-test.sh — Dynamo 全组件 HPA 扩容 + Router 分发完整验证
#
# 与 test.sh 的区别：
#   test.sh        → 标准负载，主要验证 Decode 扩容（快速，~5 min）
#   complete-test   → 验证 Frontend + Prefill + Decode 全部扩容
#                     并确认每个新 Pod 实际处理了流量（完整，~15 min）
#
# 核心策略（针对 0.6B 小模型）：
#   1. 临时调整 HPA 阈值为"小模型测试友好"值：
#      - Frontend CPU:    60% → 30%
#      - Prefill inflight: 2  → 300m (0.3)
#      - Decode maxReplicas: → 3（确保有扩容空间）
#   2. 确保 Frontend Deployment 有 cpu requests
#   3. 使用超长 Prompt (~1000 tokens) 增加 Prefill 阶段耗时
#   4. 用高并发 (80) 确保 Frontend CPU 和 Prefill inflight 突破阈值
#   5. 多阶段持续负载 + 等待新 Pod Ready + 验证分流
#
# 脚本流程：
#   Phase 0: 前置检查 + 调整 HPA 阈值 + 预热
#   Phase 1: Decode 扩容（并发 40，500 请求，标准 prompt）
#   Phase 2: 等待新 Decode Pod Ready
#   Phase 3: 全组件压力（并发 80，1500 请求，超长 prompt）
#   Phase 4: 等待所有新 Pod Ready
#   Phase 5: 验证分流（并发 50，300 请求）
#   Phase 6: 结果汇总 + Per-Pod 流量分析
#
# 用法：
#   bash complete-test.sh                    # 完整测试（~15 分钟）
#   bash complete-test.sh --reset            # 先缩回 1 副本再测试
#   bash complete-test.sh --restore          # 测试后恢复原始 HPA 阈值
#   bash complete-test.sh --reset --restore  # 两者都启用
#
# 前提：
#   bash setup.sh --background   # 已部署 Ingress/Adapter/HPA/Grafana
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_cmds kubectl curl python3

# ─── 参数 ─────────────────────────────────────────────────────────
OPT_RESET=0
OPT_RESTORE=0
POD_READY_TIMEOUT=180
MAX_TOKENS=500

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset)             OPT_RESET=1; shift ;;
    --restore)           OPT_RESTORE=1; shift ;;
    --pod-ready-timeout) POD_READY_TIMEOUT="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,2\}//'
      exit 0 ;;
    *) echo "未知参数：$1"; exit 1 ;;
  esac
done

trap cleanup_portforwards EXIT

# ─── 核心变量 ──────────────────────────────────────────────────────
DECODE_DEPLOY="${DGD_NAME}-vllmdecodeworker"
PREFILL_DEPLOY="${DGD_NAME}-vllmprefillworker"
FRONTEND_DEPLOY="${DGD_NAME}-frontend"
DECODE_SCALED=0
PREFILL_SCALED=0
FRONTEND_SCALED=0

# ─── 小模型测试 HPA 阈值（Qwen3-0.6B 专用）──────────────────────
# 为什么需要调整：
#   0.6B 模型的 Prefill 极快 (~20ms/request)，inflight 很难超过 1
#   Frontend 是轻量 Python 路由，CPU 也不容易到 60%
#   降低阈值使 0.6B 模型在合理负载下也能触发扩容
TEST_FRONTEND_CPU_PCT=30
TEST_PREFILL_INFLIGHT="300m"   # 0.3 inflight
TEST_DECODE_MAX_REPLICAS=3
TEST_PREFILL_MAX_REPLICAS=2

# ═══════════════════════════════════════════════════════════════════
# Prompt 库
# ═══════════════════════════════════════════════════════════════════
PROMPTS=(
  "Explain in great detail how the multi-head attention mechanism in transformer models computes query, key and value matrices, applies scaled dot-product attention, and concatenates the heads. Include mathematical formulas and why this approach enables capturing different types of relationships in parallel."
  "Describe the complete architecture of a production Kubernetes cluster including the control plane components (API server, etcd, scheduler, controller manager), node components (kubelet, kube-proxy, container runtime), and explain how a pod deployment flows through the entire system from kubectl apply to running containers."
  "Write a comprehensive explanation of the CAP theorem in distributed systems, providing concrete examples of CP systems (like ZooKeeper), AP systems (like Cassandra), and CA systems. Discuss why you cannot have all three properties simultaneously and the real-world trade-offs engineers must make."
  "Explain the mathematical foundations of gradient descent optimization, starting from the basic update rule, then covering momentum, RMSprop, and Adam optimizer. Derive the Adam update equations step by step and explain why adaptive learning rates help with sparse gradients and saddle points."
  "Describe how the Linux kernel virtual memory subsystem works in detail: page tables, TLB, page faults, demand paging, copy-on-write, memory-mapped files, the slab allocator, and the OOM killer. Explain how these components interact when a process allocates and accesses memory."
  "Write a detailed comparison of microservices versus monolithic architectures covering service decomposition strategies, inter-service communication patterns (synchronous REST vs asynchronous messaging), data management challenges (saga pattern, CQRS), distributed tracing, and circuit breaker patterns."
  "Explain the complete lifecycle of an HTTPS request: DNS resolution, TCP three-way handshake, TLS 1.3 handshake with key exchange, certificate validation, HTTP/2 multiplexing, server processing, and response delivery. Include details about ALPN negotiation and 0-RTT resumption."
  "Describe the Raft consensus algorithm in complete detail: leader election with randomized timeouts, log replication with append entries, safety properties, cluster membership changes, and log compaction via snapshots. Compare it with Paxos and explain why Raft was designed to be more understandable."
  "Write a comprehensive explanation of how convolutional neural networks process images: convolutional layers with filters, activation functions (ReLU variants), pooling layers, batch normalization, skip connections in ResNet, and the intuition behind what each layer learns from edges to complex features."
  "Explain garbage collection algorithms in depth: reference counting, mark-and-sweep, generational GC in Java (Young/Old/Permanent generation, minor/major/full GC), the G1 collector region-based approach, and Go concurrent tri-color mark-and-sweep with write barriers."
  "Describe the Byzantine fault tolerance problem: the Byzantine Generals analogy, impossibility results (need 3f+1 nodes), practical BFT (PBFT) protocol with pre-prepare, prepare, and commit phases, and modern approaches like Tendermint and HotStuff used in blockchain consensus."
  "Explain how a modern content delivery network works end-to-end: anycast routing, DNS-based load balancing, edge caching strategies (TTL, cache invalidation, stale-while-revalidate), origin shield, TLS termination at the edge, and consistency challenges with cache purging."
  "Write a detailed explanation of database transaction isolation levels: Read Uncommitted, Read Committed, Repeatable Read, and Serializable. For each level, explain what anomalies are prevented (dirty reads, non-repeatable reads, phantom reads) and how they are implemented using locks, MVCC, and snapshot isolation."
  "Describe the MapReduce programming model comprehensively: the map phase, shuffle and sort, reduce phase, combiner optimization, partitioning strategies, speculative execution, and failure handling. Provide examples of word count, inverted index, and page rank implemented in MapReduce."
  "Explain the Python Global Interpreter Lock in depth: why CPython has it, how it affects CPU-bound vs IO-bound multi-threading, the GIL release mechanism during IO operations, the new per-interpreter GIL in Python 3.12, and alternative approaches (multiprocessing, asyncio, subinterpreters)."
  "Describe a production recommendation system architecture: candidate generation using collaborative filtering and content-based methods, feature engineering pipeline, two-tower models for retrieval, ranking models using deep learning, A/B testing framework, and real-time feature serving with feature stores."
  "Explain eventual consistency versus strong consistency in distributed databases: the spectrum from linearizability to eventual consistency, vector clocks for conflict detection, CRDTs for automatic conflict resolution, anti-entropy protocols, read-your-writes guarantees, and causal consistency."
  "Write a comprehensive guide to container security: image scanning, rootless containers, seccomp profiles, AppArmor/SELinux policies, read-only root filesystems, network policies, pod security standards, supply chain security with Sigstore, and runtime threat detection with Falco."
  "Explain the theory of relativity and its practical applications: special relativity with time dilation and length contraction, the equivalence principle in general relativity, gravitational time dilation, how GPS satellites correct for relativistic effects, and gravitational wave detection by LIGO."
  "Describe how to build a real-time streaming data pipeline: Apache Kafka for event streaming, exactly-once semantics, stream processing with Apache Flink (event time, watermarks, windows), state management with RocksDB, and sink connectors for databases, data lakes, and search engines."
  "Explain the complete internals of a B+ tree index in a relational database: node structure, search algorithm, insertion with node splitting, deletion with merging and redistribution, range queries using leaf node linked lists, and how the buffer pool interacts with the index during queries."
  "Describe WebAssembly architecture and use cases: the stack-based virtual machine, linear memory model, type system, compilation from C/Rust/Go, the component model for composability, WASI for system interfaces, and real-world applications in serverless computing and browser-based applications."
  "Write a detailed explanation of how modern GPUs execute workloads: the SIMT execution model, streaming multiprocessors, warp scheduling, shared memory and L1/L2 cache hierarchy, memory coalescing, occupancy optimization, and how CUDA kernels map to the hardware."
  "Explain the OAuth 2.0 and OpenID Connect protocols in full detail: authorization code flow with PKCE, client credentials flow, token types (access, refresh, ID tokens), JWT structure and validation, token introspection, and security best practices for browser-based applications."
  "Describe the design and implementation of a distributed key-value store like etcd: the Raft consensus layer, write-ahead log, MVCC with revision-based versioning, watch mechanism for change notifications, lease-based TTL, range queries, and linearizable reads via read index."
  "Explain how HTTP/2 and HTTP/3 improve web performance: binary framing, header compression with HPACK, stream multiplexing, server push, flow control, the head-of-line blocking problem, how QUIC solves it with UDP-based transport, and connection migration for mobile clients."
  "Write a comprehensive explanation of zero-knowledge proofs: the concept of proving knowledge without revealing information, interactive proofs, Schnorr protocol, non-interactive proofs via Fiat-Shamir heuristic, zk-SNARKs, zk-STARKs, and practical applications in privacy-preserving authentication."
  "Describe the architecture of a large-scale search engine: web crawling with politeness policies, document parsing and index building (inverted index), BM25 ranking algorithm, PageRank for authority scoring, query processing with query expansion, personalization, and live index updates."
  "Explain the principles and practice of chaos engineering: the discipline of experimenting on distributed systems, Chaos Monkey and its successors, game days and steady state hypothesis, blast radius control, automated chaos experiments with Litmus and Chaos Mesh in Kubernetes environments."
  "Write an in-depth explanation of compiler optimization passes: SSA form conversion, constant folding and propagation, dead code elimination, loop-invariant code motion, strength reduction, register allocation via graph coloring, instruction scheduling, and auto-vectorization."
  "Describe the complete TLS 1.3 protocol: the handshake with Diffie-Hellman key exchange, EdDSA or ECDSA certificate authentication, 0-RTT resumption with replay attack mitigation, record protocol encryption with AEAD ciphers, and why TLS 1.3 removed RSA key exchange and CBC ciphers."
  "Explain operational database migration strategies in production systems: blue-green deployments, rolling migrations with backward compatibility, the expand-contract pattern, dual-write with reconciliation, feature flags for gradual rollout, and rollback procedures when migrations fail."
  "Describe how to implement a rate limiter for a high-throughput API: token bucket and sliding window algorithms, distributed rate limiting with Redis, hierarchical rate limits (per-user, per-API-key, global), graceful degradation, retry-after headers, and fairness guarantees."
  "Write a detailed explanation of the Linux networking stack: socket buffers (sk_buff), the Netfilter framework and iptables/nftables, conntrack for stateful firewalling, traffic control (tc) with queueing disciplines, XDP for high-performance packet processing, and eBPF for custom packet filtering."
  "Explain service mesh architecture with Istio: the data plane (Envoy sidecar proxies) and control plane (istiod), traffic management with virtual services and destination rules, mutual TLS between services, observability with distributed tracing, and canary deployments with traffic splitting."
  "Describe the design of a time-series database (like Prometheus or InfluxDB): the TSDB storage engine with time-structured merge trees, compaction strategies, downsampling for long-term retention, label-based indexing, the query engine for aggregation functions, and write-ahead logs for durability."
  "Explain functional programming concepts with practical examples: pure functions, immutability, algebraic data types, pattern matching, higher-order functions, monads (Option, Either, IO), and how Haskell type system prevents side effects while allowing IO through the IO monad."
  "Describe the complete TCP congestion control mechanism: slow start, congestion avoidance, fast retransmit and fast recovery, AIMD behavior, and modern algorithms like BBR that use bandwidth-delay product estimation instead of loss-based signals for better performance on modern networks."
  "Write an explanation of quantum computing fundamentals: qubits and superposition, entanglement and Bell states, quantum gates (Hadamard, CNOT, Toffoli), quantum circuits, Shor algorithm for factoring, Grover search algorithm, and current quantum hardware limitations (decoherence, error rates)."
  "Explain the complete lifecycle of a DNS query: recursive versus iterative resolution, root servers and TLD servers, DNS caching at multiple levels, DNSSEC chain of trust with DS and DNSKEY records, DNS over HTTPS and DNS over TLS for privacy, and anycast routing for DNS infrastructure."
)
PROMPT_COUNT=${#PROMPTS[@]}

# ─── 长 Prompt 生成 ────────────────────────────────────────────────
# 组合 15 个基础 prompt（~1000 tokens input），增加 Prefill 阶段耗时
# 从 ~20ms 增加到 ~100-200ms per request（0.6B 模型）
LONG_PROMPTS=()
for ((i=0; i<PROMPT_COUNT; i++)); do
  combined="${PROMPTS[$i]}"
  for ((j=1; j<=14; j++)); do
    idx=$(( (i + j * 3) % PROMPT_COUNT ))
    combined+=" Furthermore, elaborate on: ${PROMPTS[$idx]}"
  done
  LONG_PROMPTS+=("$combined")
done
LONG_PROMPT_COUNT=${#LONG_PROMPTS[@]}

# ─── 发送函数 ──────────────────────────────────────────────────────
TMPDIR_RESULTS=$(mktemp -d /tmp/dynamo-complete-XXXXXX)

send_one() {
  local id="$1"
  local prompt_type="${2:-short}"
  local uid="rid${id}t$(date +%s)r${RANDOM}"
  local prompt
  if [[ "$prompt_type" == "long" ]]; then
    prompt="[${uid}] ${LONG_PROMPTS[$((id % LONG_PROMPT_COUNT))]}"
  else
    prompt="[${uid}] ${PROMPTS[$((id % PROMPT_COUNT))]}"
  fi
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 600 \
    "${CHAT_URL}" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${MODEL_NAME}\",
      \"messages\": [{\"role\": \"user\", \"content\": \"${prompt}\"}],
      \"max_tokens\": ${MAX_TOKENS}
    }" 2>/dev/null || echo "000")
  if [[ "$code" == "200" ]]; then
    echo "ok" > "${TMPDIR_RESULTS}/${id}.ok"
  else
    echo "$code" > "${TMPDIR_RESULTS}/${id}.fail"
  fi
}

fire_wave() {
  local total=$1
  local concurrency=$2
  local prompt_type=${3:-short}
  local id_offset=${4:-0}
  for ((i=1; i<=total; i++)); do
    send_one "$((id_offset + i))" "$prompt_type" &
    while (( $(jobs -rp | wc -l) >= concurrency )); do
      sleep 0.1
    done
    if (( i % 100 == 0 )); then
      echo -e "  已提交 ${i}/${total}..."
    fi
  done
}

count_ok()   { find "${TMPDIR_RESULTS}" -name "*.ok"   2>/dev/null | wc -l; }
count_fail() { find "${TMPDIR_RESULTS}" -name "*.fail" 2>/dev/null | wc -l; }

wait_all_ready() {
  local timeout=$1
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local not_ready
    not_ready=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
      | grep -E "(prefill|decode|frontend)" \
      | grep -v "1/1" | grep -v "Completed" | wc -l)
    if [[ "$not_ready" -eq 0 ]]; then
      ok "所有 Worker Pod 已 Ready ✓"
      return 0
    fi
    echo -e "  等待 ${not_ready} Pod Ready... (${elapsed}s/${timeout}s)"
    kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
      | grep -E "(prefill|decode|frontend)" | grep -v "1/1" | grep -v "Completed" \
      | awk '{printf "    %-55s READY=%-5s STATUS=%s\n", $1, $2, $3}' || true
    sleep 15
    elapsed=$((elapsed + 15))
  done
  warn "等待超时 ${timeout}s"
  return 1
}

check_scaling() {
  local d p f
  d=$(kubectl get deployment "${DECODE_DEPLOY}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  p=$(kubectl get deployment "${PREFILL_DEPLOY}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  f=$(kubectl get deployment "${FRONTEND_DEPLOY}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  if [[ "$d" -gt "$INIT_DECODE" && "$DECODE_SCALED" -eq 0 ]]; then
    ok "DecodeWorker 扩容：${INIT_DECODE} → ${d}"
    DECODE_SCALED=1
  fi
  if [[ "$p" -gt "$INIT_PREFILL" && "$PREFILL_SCALED" -eq 0 ]]; then
    ok "PrefillWorker 扩容：${INIT_PREFILL} → ${p}"
    PREFILL_SCALED=1
  fi
  if [[ "$f" -gt "$INIT_FRONTEND" && "$FRONTEND_SCALED" -eq 0 ]]; then
    ok "Frontend 扩容：${INIT_FRONTEND} → ${f}"
    FRONTEND_SCALED=1
  fi
}

# ═══════════════════════════════════════════════════════════════════
#                        Banner
# ═══════════════════════════════════════════════════════════════════
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  complete-test.sh — Dynamo 全组件 HPA 扩容完整验证          ║"
echo "║  Frontend + Prefill + Decode Scale + 全 Pod 流量分发验证    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""
echo "  策略：临时调整 HPA 阈值以适配 Qwen3-0.6B 小模型"
echo "    Frontend CPU:     60% → ${TEST_FRONTEND_CPU_PCT}%"
echo "    Prefill inflight: 2   → ${TEST_PREFILL_INFLIGHT}"
echo "    Decode maxReplicas:   → ${TEST_DECODE_MAX_REPLICAS}"
echo ""
echo "  预计运行时间：~15 分钟"
echo ""

# ─── 检测端点 ──────────────────────────────────────────────────────
setup_endpoint
CHAT_URL="${ENDPOINT}/chat/completions"

# ═══════════════════════════════════════════════════════════════════
# Phase 0: 前置检查 + 调整 HPA 阈值
# ═══════════════════════════════════════════════════════════════════
section "Phase 0：前置检查 + HPA 阈值调整"

info "当前 Pod 状态："
kubectl get pods -n "${NAMESPACE}" -o wide 2>/dev/null || true
echo ""

# 可选：重置到 1 副本
if [[ $OPT_RESET -eq 1 ]]; then
  info "重置所有组件到 1 副本（--reset）..."
  kubectl scale deployment "${DECODE_DEPLOY}" --replicas=1 -n "${NAMESPACE}" 2>/dev/null || true
  kubectl scale deployment "${PREFILL_DEPLOY}" --replicas=1 -n "${NAMESPACE}" 2>/dev/null || true
  kubectl scale deployment "${FRONTEND_DEPLOY}" --replicas=1 -n "${NAMESPACE}" 2>/dev/null || true
  info "等待缩容完成（60s）..."
  sleep 60
  kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | grep -E "(prefill|decode|frontend)" | sed 's/^/  /' || true
  echo ""
fi

# 记录初始副本数
INIT_DECODE=$(kubectl get deployment "${DECODE_DEPLOY}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
INIT_PREFILL=$(kubectl get deployment "${PREFILL_DEPLOY}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
INIT_FRONTEND=$(kubectl get deployment "${FRONTEND_DEPLOY}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
info "初始副本数: Frontend=${INIT_FRONTEND}  Decode=${INIT_DECODE}  Prefill=${INIT_PREFILL}"
echo ""

# 保存原始 HPA 阈值（用于 --restore）
ORIG_DECODE_MAX=$(kubectl get hpa hpa-decode-worker -n "${NAMESPACE}" \
  -o jsonpath='{.spec.maxReplicas}' 2>/dev/null || echo "2")
ORIG_PREFILL_THRESHOLD=$(kubectl get hpa hpa-prefill-worker -n "${NAMESPACE}" \
  -o jsonpath='{.spec.metrics[0].pods.target.averageValue}' 2>/dev/null || echo "5")
ORIG_FRONTEND_CPU=$(kubectl get hpa hpa-frontend -n "${NAMESPACE}" \
  -o jsonpath='{.spec.metrics[0].resource.target.averageUtilization}' 2>/dev/null || echo "60")
info "当前 HPA 阈值（将保存并在 --restore 时恢复）："
echo "  Frontend CPU: ${ORIG_FRONTEND_CPU}%"
echo "  Prefill inflight: ${ORIG_PREFILL_THRESHOLD}"
echo "  Decode maxReplicas: ${ORIG_DECODE_MAX}"
echo ""

# 确保 Frontend 有 CPU requests（否则 CPU-based HPA 永远 <unknown>）
info "确保 Frontend 有 cpu requests..."
kubectl set resources deployment "${FRONTEND_DEPLOY}" -n "${NAMESPACE}" \
  --requests=cpu=100m --limits=cpu=2000m 2>/dev/null \
  && ok "Frontend cpu requests=100m 已设置" \
  || warn "无法设置 Frontend CPU requests"
info "等待 Frontend rollout..."
kubectl rollout status "deployment/${FRONTEND_DEPLOY}" \
  -n "${NAMESPACE}" --timeout=120s 2>/dev/null || warn "Frontend rollout 超时"
echo ""

# Patch HPA 到测试友好阈值
info "调整 HPA 阈值..."
kubectl patch hpa hpa-frontend -n "${NAMESPACE}" --type='json' \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/metrics/0/resource/target/averageUtilization\",\"value\":${TEST_FRONTEND_CPU_PCT}}]" 2>/dev/null \
  && ok "Frontend HPA: CPU ${ORIG_FRONTEND_CPU}% → ${TEST_FRONTEND_CPU_PCT}%" \
  || warn "无法 patch Frontend HPA"

kubectl patch hpa hpa-prefill-worker -n "${NAMESPACE}" --type='json' \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/metrics/0/pods/target/averageValue\",\"value\":\"${TEST_PREFILL_INFLIGHT}\"}]" 2>/dev/null \
  && ok "Prefill HPA: inflight ${ORIG_PREFILL_THRESHOLD} → ${TEST_PREFILL_INFLIGHT}" \
  || warn "无法 patch Prefill HPA"

kubectl patch hpa hpa-decode-worker -n "${NAMESPACE}" --type='json' \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/maxReplicas\",\"value\":${TEST_DECODE_MAX_REPLICAS}}]" 2>/dev/null \
  && ok "Decode HPA: maxReplicas ${ORIG_DECODE_MAX} → ${TEST_DECODE_MAX_REPLICAS}" \
  || warn "无法 patch Decode HPA"

echo ""
info "调整后 HPA："
kubectl get hpa -n "${NAMESPACE}"
echo ""

# 预热
info "预热（3 个串行请求）..."
for i in 1 2 3; do
  send_one "$i" "short"
  wait
done
WARMUP_OK=$(count_ok)
[[ $WARMUP_OK -gt 0 ]] && ok "预热 ${WARMUP_OK}/3 成功" || fatal "预热全部失败！推理服务不可用"
info "等待 15s 让 Prometheus 采集指标..."
sleep 15
# 清理预热结果
rm -f "${TMPDIR_RESULTS}"/*.ok "${TMPDIR_RESULTS}"/*.fail

# ═══════════════════════════════════════════════════════════════════
# Phase 1: Decode 扩容（标准负载）
#
# Decode 是最容易触发的：
#   40 并发 × max_tokens 500 → 每请求 Decode 持续 15-40s
#   inflight ~20-40/Pod → 远超阈值 5 → 立即触发扩容
# ═══════════════════════════════════════════════════════════════════
section "Phase 1：Decode 扩容（500 请求 × 并发 40 × 标准 Prompt）"

PRE_OK=$(count_ok)
START_P1=$(date +%s)
fire_wave 500 40 "short" 0
info "Phase 1 全部提交，等待完成..."

ELAPSED_MON=0
while true; do
  RUNNING=$(jobs -rp | wc -l)
  echo -e "  ${BOLD}[$(date +%H:%M:%S)] inflight_jobs=${RUNNING}${NC}"
  kubectl get hpa -n "${NAMESPACE}" --no-headers 2>/dev/null | sed 's/^/    /' || true
  kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | grep -E "(prefill|decode|frontend)" | sed 's/^/    /' || true
  check_scaling
  echo ""
  [[ $RUNNING -eq 0 ]] && break
  sleep 10
  ELAPSED_MON=$((ELAPSED_MON + 10))
  [[ $ELAPSED_MON -ge 300 ]] && { warn "Phase 1 监控超时"; break; }
done

wait 2>/dev/null || true
END_P1=$(date +%s)
P1_OK=$(($(count_ok) - PRE_OK))
P1_FAIL=$(count_fail)
info "Phase 1 完成：成功=${P1_OK} 失败=${P1_FAIL} 耗时=$((END_P1 - START_P1))s"
echo ""

# ═══════════════════════════════════════════════════════════════════
# Phase 2: 等待新 Decode Pod Ready
# ═══════════════════════════════════════════════════════════════════
section "Phase 2：等待新 Decode Pod Ready"

if [[ $DECODE_SCALED -eq 1 ]]; then
  wait_all_ready "$POD_READY_TIMEOUT"
else
  info "此阶段未检测到 Decode 扩容，跳过等待"
  info "（可能已经 >1 副本，或阈值未触发 — Phase 3 会继续尝试）"
fi
echo ""

# ═══════════════════════════════════════════════════════════════════
# Phase 3: 全组件压力测试（超长 Prompt + 高并发）
#
# 策略：
#   - 超长 Prompt (~1000 tokens input)：
#     增加每次 Prefill 耗时到 ~100-200ms（0.6B 模型）
#     80 并发的初始 burst：80 个请求同时进入 Prefill 队列
#     峰值 Prefill inflight ~10-40 → 远超阈值 300m
#
#   - 高并发 80：
#     Frontend 作为轻量 Python HTTP 路由，处理 80 并发时
#     CPU 使用超过 30m（30% of requests.cpu=100m）→ 触发 HPA
#
#   - 持续 1500 请求：
#     总耗时 ~5-8 分钟，足够 HPA 检测 + 扩容 + 新 Pod Ready
# ═══════════════════════════════════════════════════════════════════
section "Phase 3：全组件压力（1500 请求 × 并发 80 × 超长 Prompt ~1000 tokens）"

echo "  策略要点："
echo "    - 超长 Prompt → Prefill 耗时增加 5-10x → inflight 突破 ${TEST_PREFILL_INFLIGHT}"
echo "    - 高并发 80 → Frontend CPU 突破 ${TEST_FRONTEND_CPU_PCT}%"
echo "    - 持续 ~6 分钟 → 足够新 Pod 完成模型加载"
echo ""

PRE_OK_P3=$(count_ok)
PRE_FAIL_P3=$(count_fail)
START_P3=$(date +%s)
fire_wave 1500 80 "long" 500
info "Phase 3 全部提交，监控全部 HPA..."

ELAPSED_MON=0
while true; do
  RUNNING=$(jobs -rp | wc -l)
  echo -e "  ${BOLD}[$(date +%H:%M:%S)] inflight_jobs=${RUNNING}${NC}"
  kubectl get hpa -n "${NAMESPACE}" --no-headers 2>/dev/null | sed 's/^/    /' || true
  kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | grep -E "(prefill|decode|frontend)" | sed 's/^/    /' || true
  check_scaling

  # 打印各 Pod inflight
  kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/${NAMESPACE}/pods/*/dynamo_inflight_requests" 2>/dev/null \
    | python3 -c "
import sys,json
items=json.load(sys.stdin).get('items',[])
for i in items:
    print(f'    Metric {i[\"describedObject\"][\"name\"]}: inflight={i[\"value\"]}')
" 2>/dev/null || true
  echo ""

  [[ $RUNNING -eq 0 ]] && break
  sleep 15
  ELAPSED_MON=$((ELAPSED_MON + 15))
  [[ $ELAPSED_MON -ge 600 ]] && { warn "Phase 3 监控超时 600s"; break; }
done

wait 2>/dev/null || true
END_P3=$(date +%s)
P3_OK=$(($(count_ok) - PRE_OK_P3))
P3_FAIL=$(($(count_fail) - PRE_FAIL_P3))
info "Phase 3 完成：成功=${P3_OK} 失败=${P3_FAIL} 耗时=$((END_P3 - START_P3))s"
echo ""

# ═══════════════════════════════════════════════════════════════════
# Phase 4: 等待所有新 Pod Ready
# ═══════════════════════════════════════════════════════════════════
section "Phase 4：等待所有新 Pod Ready"

ANY_NEW_SCALING=$((DECODE_SCALED + PREFILL_SCALED + FRONTEND_SCALED))
if [[ $ANY_NEW_SCALING -gt 0 ]]; then
  wait_all_ready "$POD_READY_TIMEOUT"
else
  info "未检测到任何新扩容事件，跳过等待"
fi
echo ""
info "当前 Pod 列表："
kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
  | grep -E "(prefill|decode|frontend)" | sed 's/^/  /' || true
echo ""

# ═══════════════════════════════════════════════════════════════════
# Phase 5: 验证分流（所有 Pod 都 Ready 后再发一轮请求）
#
# 目的：确认新扩容的 Pod 实际承接了处理流量，而不仅仅是启动了。
# 使用标准 prompt + 中等并发，在 Prometheus 中可观察到 per-pod 分布。
# ═══════════════════════════════════════════════════════════════════
section "Phase 5：验证分流（300 请求 × 并发 50 × 标准 Prompt）"

PRE_OK_P5=$(count_ok)
PRE_FAIL_P5=$(count_fail)
START_P5=$(date +%s)
fire_wave 300 50 "short" 2000
info "Phase 5 全部提交，等待完成..."

while [[ $(jobs -rp | wc -l) -gt 0 ]]; do
  RUNNING=$(jobs -rp | wc -l)
  echo -e "  [$(date +%H:%M:%S)] 剩余 ${RUNNING} 请求"
  kubectl get hpa -n "${NAMESPACE}" --no-headers 2>/dev/null | sed 's/^/    /' || true
  sleep 10
done

wait 2>/dev/null || true
END_P5=$(date +%s)
P5_OK=$(($(count_ok) - PRE_OK_P5))
P5_FAIL=$(($(count_fail) - PRE_FAIL_P5))
info "Phase 5 完成：成功=${P5_OK} 失败=${P5_FAIL} 耗时=$((END_P5 - START_P5))s"
echo ""

# ═══════════════════════════════════════════════════════════════════
# Phase 6: 结果汇总
# ═══════════════════════════════════════════════════════════════════
section "Phase 6：测试结果"

TOTAL_OK=$(count_ok)
TOTAL_FAIL=$(count_fail)
TOTAL_DURATION=$(( $(date +%s) - START_P1 ))

echo -e "${BOLD}────────────────────────────────────────────────────────────${NC}"
printf "  %-22s %s\n" "Phase 1 (Decode):"   "${P1_OK} 成功 / ${P1_FAIL} 失败 / $((END_P1 - START_P1))s"
printf "  %-22s %s\n" "Phase 3 (All):"       "${P3_OK} 成功 / ${P3_FAIL} 失败 / $((END_P3 - START_P3))s"
printf "  %-22s %s\n" "Phase 5 (Verify):"    "${P5_OK} 成功 / ${P5_FAIL} 失败 / $((END_P5 - START_P5))s"
echo -e "${BOLD}────────────────────────────────────────────────────────────${NC}"
printf "  %-22s %s\n" "总成功:" "${TOTAL_OK}"
printf "  %-22s %s\n" "总失败:" "${TOTAL_FAIL}"
printf "  %-22s %ss\n" "总耗时:" "${TOTAL_DURATION}"
if [[ $TOTAL_DURATION -gt 0 ]]; then
  QPS=$(awk "BEGIN{printf \"%.2f\", ${TOTAL_OK}/${TOTAL_DURATION}}")
  printf "  %-22s %s\n" "平均 QPS:" "${QPS}"
fi
echo -e "${BOLD}────────────────────────────────────────────────────────────${NC}"
echo ""

rm -rf "${TMPDIR_RESULTS}"

# ─── 扩容结果 ──────────────────────────────────────────────────────
info "最终 HPA 状态："
kubectl get hpa -n "${NAMESPACE}" 2>/dev/null || true
echo ""
info "最终 Pod 列表："
kubectl get pods -n "${NAMESPACE}" -o wide 2>/dev/null || true
echo ""

# ─── 扩容评分 ──────────────────────────────────────────────────────
SCORE=0
echo -e "${BOLD}═══ 扩容评分 ═══${NC}"
if [[ $DECODE_SCALED -eq 1 ]]; then
  ok "✓ Decode 扩容成功"
  SCORE=$((SCORE + 1))
else
  warn "✗ Decode 未扩容"
fi
if [[ $PREFILL_SCALED -eq 1 ]]; then
  ok "✓ Prefill 扩容成功"
  SCORE=$((SCORE + 1))
else
  warn "✗ Prefill 未扩容（0.6B 模型 Prefill 极快，可能需要更高并发）"
fi
if [[ $FRONTEND_SCALED -eq 1 ]]; then
  ok "✓ Frontend 扩容成功"
  SCORE=$((SCORE + 1))
else
  warn "✗ Frontend 未扩容（可能 CPU 未达到 ${TEST_FRONTEND_CPU_PCT}% 阈值）"
fi
echo ""
echo -e "${BOLD}  扩容评分: ${SCORE}/3 组件触发了 HPA 扩容${NC}"
echo ""

# ─── Per-Pod 流量分布 ──────────────────────────────────────────────
info "Per-Pod 负载分布（max_over_time inflight，最近 20 分钟）："
PROM_RESULT=$(curl -sG "http://localhost:9090/api/v1/query" \
  --data-urlencode "query=max_over_time(dynamo_component_inflight_requests{namespace=\"${NAMESPACE}\"}[20m])" \
  2>/dev/null || echo "")
if [[ -n "$PROM_RESULT" ]]; then
  echo "$PROM_RESULT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    results = data.get('data', {}).get('result', [])
    if not results:
        print('  (无数据)')
    else:
        for r in sorted(results, key=lambda x: float(x['value'][1]), reverse=True):
            pod = r['metric'].get('pod', 'unknown')
            val = float(r['value'][1])
            # 只显示 val > 0 的
            if val > 0:
                bar_len = min(int(val), 40)
                bar = '#' * bar_len
                print(f'  {pod:60s} peak_inflight={val:7.1f}  {bar}')
except Exception as e:
    print(f'  (解析失败: {e})')
" 2>/dev/null || echo "  (Prometheus 不可达)"
else
  echo "  (Prometheus 不可达，请确认 port-forward 运行中)"
fi
echo ""

# ─── 扩容事件 ──────────────────────────────────────────────────────
info "近期 HPA 扩容事件："
kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' 2>/dev/null \
  | grep -iE "SuccessfulRescale|ScalingReplicaSet" | tail -15 || echo "  (无事件)"
echo ""

# ─── Grafana 引导 ──────────────────────────────────────────────────
info "Grafana 全程监控数据："
echo "  http://localhost:3000 → Dashboard: 'Dynamo — HPA & Router Monitor'"
echo ""
echo "  重点面板："
echo "    - HPA Replicas:        观察三个组件的扩容时间线"
echo "    - Inflight per Pod:    确认新 Pod 在 Phase 5 中处理了流量"
echo "    - Request Rate:        各 Pod 请求速率分布"
echo ""

# ═══════════════════════════════════════════════════════════════════
# 恢复原始 HPA 阈值（可选）
# ═══════════════════════════════════════════════════════════════════
if [[ $OPT_RESTORE -eq 1 ]]; then
  section "恢复原始 HPA 阈值（--restore）"
  kubectl patch hpa hpa-frontend -n "${NAMESPACE}" --type='json' \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/metrics/0/resource/target/averageUtilization\",\"value\":${ORIG_FRONTEND_CPU}}]" 2>/dev/null \
    && ok "Frontend HPA 恢复: CPU ${ORIG_FRONTEND_CPU}%" \
    || warn "恢复失败"
  kubectl patch hpa hpa-prefill-worker -n "${NAMESPACE}" --type='json' \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/metrics/0/pods/target/averageValue\",\"value\":\"${ORIG_PREFILL_THRESHOLD}\"}]" 2>/dev/null \
    && ok "Prefill HPA 恢复: inflight ${ORIG_PREFILL_THRESHOLD}" \
    || warn "恢复失败"
  kubectl patch hpa hpa-decode-worker -n "${NAMESPACE}" --type='json' \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/maxReplicas\",\"value\":${ORIG_DECODE_MAX}}]" 2>/dev/null \
    && ok "Decode HPA 恢复: maxReplicas ${ORIG_DECODE_MAX}" \
    || warn "恢复失败"
  echo ""
  kubectl get hpa -n "${NAMESPACE}"
fi

echo ""
ok "complete-test.sh 全部完成 ✓"
