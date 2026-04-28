#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# test.sh — Dynamo 一体化负载测试
#
# 一个脚本同时验证：
#   1. HPA 在负载增加时正确 scale-up（观察 Pod 副本数变化）
#   2. 新扩容的 Pod 实际承接处理流量（非仅启动不分流）
#   3. Router 将请求分发到多个 Prefill/Decode Pod（Grafana 可观测）
#
# 默认所有基础设施（Ingress/HPA/Prometheus/Grafana）已部署就绪。
#
# 流程（多波次持续负载）：
#   Stage 0: 快速检测自定义指标是否可用（非阻塞，仅警告）
#   Stage 1: 预热 — 发少量请求让 Prometheus 开始采集指标
#   Stage 2: Wave 1 — 持续高并发（~3分钟），触发 HPA 扩容
#   Stage 3: 等待新 Pod Ready（模型加载完成，可接收流量）
#   Stage 4: Wave 2 — 验证负载，确认新老 Pod 都处理了流量
#   Stage 5: 结果汇总 + Per-Pod 流量分布 + Grafana 引导
#
# 用法：
#   bash test.sh                                # 默认参数
#   bash test.sh --concurrency 50 --wave1 1000  # 更大压力
#   bash test.sh --max-tokens 800               # 更长生成 → 更高 inflight
#   bash test.sh --endpoint http://host/v1      # 手动指定端点
#
# 参数：
#   --concurrency N        Wave 1 并发数（默认 40）
#   --wave1 N              Wave 1 请求数（默认 800）
#   --wave2 N              Wave 2 请求数（默认 200）
#   --max-tokens N         每请求最大 token（默认 500）
#   --endpoint URL         手动指定推理端点
#   --watch-timeout N      HPA 扩容观察超时秒数（默认 600）
#   --pod-ready-timeout N  等待新 Pod Ready 超时秒数（默认 180）
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_cmds kubectl curl

# ─── 参数默认值（多波次持续负载优化） ────────────────────────────
# Wave 1: 高并发持续压力（~3分钟） → 触发 HPA 扩容
# Wave 2: 等新 Pod Ready 后验证负载 → 确认所有 Pod 都处理流量
CONCURRENCY=40
WAVE1_REQUESTS=800
WAVE2_REQUESTS=200
MAX_TOKENS=500
WATCH_TIMEOUT=600
POD_READY_TIMEOUT=180

while [[ $# -gt 0 ]]; do
  case "$1" in
    --concurrency)       CONCURRENCY="$2"; shift 2 ;;
    --wave1)             WAVE1_REQUESTS="$2"; shift 2 ;;
    --wave2)             WAVE2_REQUESTS="$2"; shift 2 ;;
    --max-tokens)        MAX_TOKENS="$2"; shift 2 ;;
    --endpoint)          ENDPOINT="$2"; shift 2 ;;
    --watch-timeout)     WATCH_TIMEOUT="$2"; shift 2 ;;
    --pod-ready-timeout) POD_READY_TIMEOUT="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,2\}//'
      exit 0 ;;
    *) echo "未知参数：$1"; exit 1 ;;
  esac
done

trap cleanup_portforwards EXIT

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  test.sh — Dynamo 一体化负载测试                            ║"
echo "║  HPA 扩容验证 + Router 分发观测                             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
printf "  %-18s %s\n" "NAMESPACE:"       "${NAMESPACE}"
printf "  %-18s %s\n" "Wave 1 并发:"     "${CONCURRENCY}"
printf "  %-18s %s\n" "Wave 1 请求数:"   "${WAVE1_REQUESTS}"
printf "  %-18s %s\n" "Wave 2 请求数:"   "${WAVE2_REQUESTS}"
printf "  %-18s %s\n" "Max Tokens:"       "${MAX_TOKENS}"
printf "  %-18s %s\n" "Pod Ready 超时:"  "${POD_READY_TIMEOUT}s"
echo ""

# ─── 端点检测 ──────────────────────────────────────────────────
setup_endpoint
CHAT_URL="${ENDPOINT}/chat/completions"

# ═══════════════════════════════════════════════════════════════════
# Stage 0: 快速健康检查（非阻塞 — 仅打印状态和警告）
#
# 检查 Custom Metrics API 是否能返回 dynamo_inflight_requests。
# 如果返回 404，说明 prometheus-adapter 配置有问题，需要先修复。
# ═══════════════════════════════════════════════════════════════════
section "Stage 0：指标健康检查"

info "Pod 列表："
kubectl get pods -n "${NAMESPACE}" -o wide 2>/dev/null || true
echo ""
info "HPA 状态："
kubectl get hpa -n "${NAMESPACE}" 2>/dev/null || true
echo ""

# 检查自定义指标是否可用
METRICS_OK=0
if kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/${NAMESPACE}/pods/*/dynamo_inflight_requests" &>/dev/null; then
  ok "Custom Metrics API 返回 dynamo_inflight_requests ✓"
  METRICS_OK=1
else
  warn "Custom Metrics API 无法返回 dynamo_inflight_requests（HPA 将显示 <unknown>）"
  echo ""
  echo "  可能原因："
  echo "    1. prometheus-adapter 未连接到 Prometheus"
  echo "       → 检查：kubectl logs -n ${MONITORING_NS} -l app.kubernetes.io/name=prometheus-adapter --tail=10"
  echo "    2. Dynamo Worker 尚未生成过 inflight 指标（从未收到请求）"
  echo "       → 需要先发几个预热请求，让 Prometheus 开始采集"
  echo "    3. prometheus-adapter 需要重新部署"
  echo "       → 执行：bash setup.sh"
  echo ""
  info "继续执行测试（预热请求可能让指标出现）..."
fi
echo ""

DECODE_DEPLOY="${DGD_NAME}-vllmdecodeworker"
PREFILL_DEPLOY="${DGD_NAME}-vllmprefillworker"
FRONTEND_DEPLOY="${DGD_NAME}-frontend"
REPLICAS_DECODE_BEFORE=$(kubectl get deployment "${DECODE_DEPLOY}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
REPLICAS_PREFILL_BEFORE=$(kubectl get deployment "${PREFILL_DEPLOY}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
REPLICAS_FRONTEND_BEFORE=$(kubectl get deployment "${FRONTEND_DEPLOY}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
info "初始副本数: Frontend=${REPLICAS_FRONTEND_BEFORE}  Decode=${REPLICAS_DECODE_BEFORE}  Prefill=${REPLICAS_PREFILL_BEFORE}"
echo ""

# ═══════════════════════════════════════════════════════════════════
# Prompt 库 — 40 条完全不同的长 prompt，最大化路由分散
#
# 设计要点：
#   - 40 种不同主题 → 无公共前缀 → KV Cache 无亲和性
#   - 每请求附唯一 ID → 杰绝缓存命中
#   - 较长 prompt → Prefill 阶段计算量大 → inflight 更久
#   - max_tokens=500 → Decode 阶段持续 15~40s → inflight 窗口宽
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
  "Explain garbage collection algorithms in depth: reference counting, mark-and-sweep, generational GC in Java (Young/Old/Permanent generation, minor/major/full GC), the G1 collector's region-based approach, and Go's concurrent tri-color mark-and-sweep with write barriers."
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
  "Describe WebAssembly's architecture and use cases: the stack-based virtual machine, linear memory model, type system, compilation from C/Rust/Go, the component model for composability, WASI for system interfaces, and real-world applications in serverless computing and browser-based applications."
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
  "Explain functional programming concepts with practical examples: pure functions, immutability, algebraic data types, pattern matching, higher-order functions, monads (Option, Either, IO), and how Haskell's type system prevents side effects while allowing IO through the IO monad."
  "Describe the complete TCP congestion control mechanism: slow start, congestion avoidance, fast retransmit and fast recovery, AIMD behavior, and modern algorithms like BBR that use bandwidth-delay product estimation instead of loss-based signals for better performance on modern networks."
  "Write an explanation of quantum computing fundamentals: qubits and superposition, entanglement and Bell states, quantum gates (Hadamard, CNOT, Toffoli), quantum circuits, Shor's algorithm for factoring, Grover's search algorithm, and current quantum hardware limitations (decoherence, error rates)."
  "Explain the complete lifecycle of a DNS query: recursive versus iterative resolution, root servers and TLD servers, DNS caching at multiple levels, DNSSEC chain of trust with DS and DNSKEY records, DNS over HTTPS and DNS over TLS for privacy, and anycast routing for DNS infrastructure."
)
PROMPT_COUNT=${#PROMPTS[@]}

# ═══════════════════════════════════════════════════════════════════
# Stage 1: 预热 — 发 5 个串行请求让 Prometheus 开始采集指标
#
# 在 Worker 从未收到过请求时，dynamo_component_inflight_requests
# 指标可能不存在。发几个预热请求让 Worker 暴露指标。
# ═══════════════════════════════════════════════════════════════════
section "Stage 1：预热（5 个串行请求）"

info "发送 5 个预热请求..."
WARMUP_OK=0
for i in 1 2 3 4 5; do
  PROMPT="${PROMPTS[$((i - 1))]}"
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 120 \
    "${CHAT_URL}" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${MODEL_NAME}\",
      \"messages\": [{\"role\": \"user\", \"content\": \"${PROMPT}\"}],
      \"max_tokens\": 50
    }" 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" == "200" ]]; then
    echo -e "  预热 ${i}/5: ${GREEN}HTTP 200${NC}"
    WARMUP_OK=$((WARMUP_OK + 1))
  else
    echo -e "  预热 ${i}/5: ${RED}HTTP ${HTTP_CODE}${NC}"
  fi
done

if [[ $WARMUP_OK -eq 0 ]]; then
  fatal "所有预热请求失败！推理服务不可用。"
fi
ok "${WARMUP_OK}/5 个预热请求成功"
echo ""

# 预热后再检查一次指标
info "等待 15s 让 Prometheus 采集指标..."
sleep 15
if kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/${NAMESPACE}/pods/*/dynamo_inflight_requests" &>/dev/null; then
  ok "Custom Metrics API 已能返回 dynamo_inflight_requests ✓"
  METRIC_VALUE=$(kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/${NAMESPACE}/pods/*/dynamo_inflight_requests" 2>/dev/null \
    | python3 -c "import sys,json; items=json.load(sys.stdin).get('items',[]); [print(f'  {i[\"describedObject\"][\"name\"]}: {i[\"value\"]}') for i in items]" 2>/dev/null || echo "  (解析失败)")
  echo "${METRIC_VALUE}"
  METRICS_OK=1
else
  warn "预热后 Custom Metrics 仍然不可用"
  echo "  prometheus-adapter 可能需要重新部署（bash setup.sh）"
  echo "  继续发送负载..."
fi
echo ""

# ═══════════════════════════════════════════════════════════════════
# Stage 2 / Wave 1: 持续高负载 — 触发 HPA 扩容
#
# 发送逻辑：
#   - 40 条不同的长 prompt 循环，每请求附唯一 ID（杰绝 KV Cache 亲和性）
#   - 并发 40 + max_tokens 500 → 每请求 Decode 持续 15~40s
#   - 持续 inflight ~30+ → 远超 HPA 阈值 → 触发扩容
#   - 持续时间 ~3-4 分钟 → 足够新 Pod 启动并接收流量
# ═════════════════════════════════════════════════════════════════
section "Stage 2 / Wave 1：持续高负载（${WAVE1_REQUESTS} 请求 × 并发 ${CONCURRENCY} × max_tokens ${MAX_TOKENS}）"

TMPDIR_RESULTS=$(mktemp -d /tmp/dynamo-test-XXXXXX)

send_one() {
  local id="$1"
  local max_tok="${2:-${MAX_TOKENS}}"
  local base_prompt="${PROMPTS[$((id % PROMPT_COUNT))]}"
  # Cache-busting: 每个请求附带唯一 ID，防止 KV Cache 亲和性
  local uid="rid${id}t$(date +%s)r${RANDOM}"
  local prompt="[${uid}] ${base_prompt}"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 300 \
    "${CHAT_URL}" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${MODEL_NAME}\",
      \"messages\": [{\"role\": \"user\", \"content\": \"${prompt}\"}],
      \"max_tokens\": ${max_tok}
    }" 2>/dev/null || echo "000")
  if [[ "$code" == "200" ]]; then
    echo "ok" > "${TMPDIR_RESULTS}/${id}.ok"
  else
    echo "$code" > "${TMPDIR_RESULTS}/${id}.fail"
  fi
}

START_TIME=$(date +%s)

# 启动后台发送进程
for ((i=1; i<=WAVE1_REQUESTS; i++)); do
  send_one "$i" &
  # 控制并发：等待至少一个槽位空出来
  while (( $(jobs -rp | wc -l) >= CONCURRENCY )); do
    sleep 0.1
  done
  # 每 50 个请求打印进度
  if (( i % 50 == 0 )); then
    echo -e "  已提交 ${i}/${WAVE1_REQUESTS} 个请求..."
  fi
done

info "Wave 1: 全部 ${WAVE1_REQUESTS} 个请求已提交，等待完成中..."
echo ""

# ═══════════════════════════════════════════════════════════════════
# 等待同时观察 HPA 扩容
# ═══════════════════════════════════════════════════════════════════
section "观察 HPA 与 Pod 变化（负载运行中）"

DECODE_SCALED=0
PREFILL_SCALED=0
FRONTEND_SCALED=0
ELAPSED=0
INTERVAL=10
while true; do
  RUNNING_JOBS=$(jobs -rp | wc -l)

  # 打印时间 + 运行中请求数
  echo -e "  ${BOLD}[$(date +%H:%M:%S)] inflight_jobs=${RUNNING_JOBS}${NC}"

  # 打印 HPA 状态（完整行输出，避免 awk 列偏移 bug）
  kubectl get hpa -n "${NAMESPACE}" --no-headers 2>/dev/null | sed 's/^/    /' || true

  # 打印当前 Pod 列表（简洁版）
  kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | grep -E "(prefill|decode|frontend)" \
    | awk '{printf "    Pod %-55s STATUS=%s\n", $1, $3}' || true
  echo ""

  # 检查是否扩容
  REPLICAS_DECODE_NOW=$(kubectl get deployment "${DECODE_DEPLOY}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "${REPLICAS_DECODE_BEFORE}")
  REPLICAS_PREFILL_NOW=$(kubectl get deployment "${PREFILL_DEPLOY}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "${REPLICAS_PREFILL_BEFORE}")

  if [[ "$REPLICAS_DECODE_NOW" -gt "$REPLICAS_DECODE_BEFORE" && "$DECODE_SCALED" -eq 0 ]]; then
    ok "DecodeWorker 已扩容：${REPLICAS_DECODE_BEFORE} → ${REPLICAS_DECODE_NOW} 副本"
    DECODE_SCALED=1
  fi
  if [[ "$REPLICAS_PREFILL_NOW" -gt "$REPLICAS_PREFILL_BEFORE" && "$PREFILL_SCALED" -eq 0 ]]; then
    ok "PrefillWorker 已扩容：${REPLICAS_PREFILL_BEFORE} → ${REPLICAS_PREFILL_NOW} 副本"
    PREFILL_SCALED=1
  fi

  # 检查 Frontend 扩容
  REPLICAS_FRONTEND_NOW=$(kubectl get deployment "${FRONTEND_DEPLOY}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "${REPLICAS_FRONTEND_BEFORE}")
  if [[ "$REPLICAS_FRONTEND_NOW" -gt "$REPLICAS_FRONTEND_BEFORE" && "$FRONTEND_SCALED" -eq 0 ]]; then
    ok "Frontend 已扩容：${REPLICAS_FRONTEND_BEFORE} → ${REPLICAS_FRONTEND_NOW} 副本"
    FRONTEND_SCALED=1
  fi

  # 如果指标可用，打印当前 inflight 值
  if [[ $METRICS_OK -eq 1 ]]; then
    kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/${NAMESPACE}/pods/*/dynamo_inflight_requests" 2>/dev/null \
      | python3 -c "import sys,json; items=json.load(sys.stdin).get('items',[]); [print(f'    Metric {i[\"describedObject\"][\"name\"]}: inflight={i[\"value\"]}') for i in items]" 2>/dev/null || true
  fi

  # 全部请求完成 → 退出
  if [[ "$RUNNING_JOBS" -eq 0 ]]; then
    break
  fi

  ELAPSED=$((ELAPSED + INTERVAL))
  if [[ $ELAPSED -ge $WATCH_TIMEOUT ]]; then
    warn "观察超时 ${WATCH_TIMEOUT}s，停止监控循环（请求仍在后台运行）"
    break
  fi

  sleep $INTERVAL
done

# 等待所有后台请求彻底完成
wait 2>/dev/null || true

WAVE1_END=$(date +%s)
WAVE1_DURATION=$((WAVE1_END - START_TIME))
WAVE1_SUCCESS=$(find "${TMPDIR_RESULTS}" -name "*.ok" 2>/dev/null | wc -l)
WAVE1_FAIL=$(find "${TMPDIR_RESULTS}" -name "*.fail" 2>/dev/null | wc -l)

info "Wave 1 完成：成功=${WAVE1_SUCCESS} 失败=${WAVE1_FAIL} 耗时=${WAVE1_DURATION}s"
echo ""

# ═══════════════════════════════════════════════════════════════════
# Stage 3: 等待新 Pod Ready
#
# HPA 扩容后，新 Pod 需要：拉取镜像→启动容器→加载模型→初始化 CUDA→通过健康检查
# 对于 Qwen3-0.6B 约需 60-90s，较大模型可能需要数分钟。
# 必须等待新 Pod Ready 后再发验证流量，否则新 Pod 无法分到请求。
# ═══════════════════════════════════════════════════════════════════
section "Stage 3：等待扩容 Pod Ready"

REPLICAS_DECODE_FINAL=$(kubectl get deployment "${DECODE_DEPLOY}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
REPLICAS_PREFILL_FINAL=$(kubectl get deployment "${PREFILL_DEPLOY}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
REPLICAS_FRONTEND_FINAL=$(kubectl get deployment "${FRONTEND_DEPLOY}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")

ANY_SCALED=0
[[ "$REPLICAS_DECODE_FINAL" -gt "$REPLICAS_DECODE_BEFORE" ]] && ANY_SCALED=1
[[ "$REPLICAS_PREFILL_FINAL" -gt "$REPLICAS_PREFILL_BEFORE" ]] && ANY_SCALED=1
[[ "$REPLICAS_FRONTEND_FINAL" -gt "$REPLICAS_FRONTEND_BEFORE" ]] && ANY_SCALED=1

if [[ $ANY_SCALED -eq 1 ]]; then
  info "检测到扩容：Frontend=${REPLICAS_FRONTEND_FINAL} Decode=${REPLICAS_DECODE_FINAL} Prefill=${REPLICAS_PREFILL_FINAL}"
  info "等待所有 Pod Ready（最多 ${POD_READY_TIMEOUT}s）— 模型加载中..."
  echo ""
  READY_ELAPSED=0
  ALL_READY=0
  while [[ $READY_ELAPSED -lt $POD_READY_TIMEOUT ]]; do
    NOT_READY=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
      | grep -E "(prefill|decode|frontend)" \
      | grep -v "1/1" | grep -v "Completed" | wc -l)
    if [[ "$NOT_READY" -eq 0 ]]; then
      ALL_READY=1
      break
    fi
    echo -e "  等待 ${NOT_READY} 个 Pod Ready... (${READY_ELAPSED}s/${POD_READY_TIMEOUT}s)"
    kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
      | grep -E "(prefill|decode|frontend)" \
      | grep -v "1/1" | awk '{printf "    %-55s READY=%-5s STATUS=%s\n", $1, $2, $3}' || true
    sleep 15
    READY_ELAPSED=$((READY_ELAPSED + 15))
  done
  echo ""
  if [[ $ALL_READY -eq 1 ]]; then
    ok "所有 Worker Pod 已 Ready ✓"
  else
    warn "部分 Pod 未在 ${POD_READY_TIMEOUT}s 内 Ready（继续验证）"
  fi
  echo ""
  kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | grep -E "(prefill|decode|frontend)" | sed 's/^/  /' || true
else
  info "Wave 1 未触发扩容，跳过等待"
fi
echo ""

# ═══════════════════════════════════════════════════════════════════
# Stage 4 / Wave 2: 验证性负载
#
# 在所有 Pod（包括新扩容的）都 Ready 后，再发一轮请求。
# 如果 Router 正常工作，新老 Pod 都应该处理流量。
# 在 Prometheus/Grafana 中可以观察到 per-pod 指标分布。
# ═══════════════════════════════════════════════════════════════════
WAVE2_CONCURRENCY=$((CONCURRENCY / 2))
section "Stage 4 / Wave 2：验证负载（${WAVE2_REQUESTS} 请求 × 并发 ${WAVE2_CONCURRENCY}）"

WAVE2_START=$(date +%s)

for ((i=1; i<=WAVE2_REQUESTS; i++)); do
  send_one "$((WAVE1_REQUESTS + i))" "${MAX_TOKENS}" &
  while (( $(jobs -rp | wc -l) >= WAVE2_CONCURRENCY )); do
    sleep 0.1
  done
  if (( i % 50 == 0 )); then
    echo -e "  Wave 2: 已提交 ${i}/${WAVE2_REQUESTS}..."
  fi
done

info "Wave 2: 全部 ${WAVE2_REQUESTS} 个请求已提交，等待完成..."

# Wave 2 期间观察
while [[ $(jobs -rp | wc -l) -gt 0 ]]; do
  RUNNING=$(jobs -rp | wc -l)
  echo -e "  ${BOLD}[$(date +%H:%M:%S)] 剩余 ${RUNNING} 个请求${NC}"
  kubectl get hpa -n "${NAMESPACE}" --no-headers 2>/dev/null | sed 's/^/    /' || true
  sleep 10
done

wait 2>/dev/null || true

WAVE2_END=$(date +%s)
WAVE2_DURATION=$((WAVE2_END - WAVE2_START))
echo ""

# ═══════════════════════════════════════════════════════════════════
# Stage 5: 测试结果汇总
# ═══════════════════════════════════════════════════════════════════
section "Stage 5：测试结果"

TOTAL_REQUESTS=$((WAVE1_REQUESTS + WAVE2_REQUESTS))
TOTAL_DURATION=$((WAVE2_END - START_TIME))
SUCCESS_COUNT=$(find "${TMPDIR_RESULTS}" -name "*.ok" 2>/dev/null | wc -l)
FAIL_COUNT=$(find "${TMPDIR_RESULTS}" -name "*.fail" 2>/dev/null | wc -l)
rm -rf "${TMPDIR_RESULTS}"

echo -e "${BOLD}────────────────────────────────────────────────────────────${NC}"
printf "  %-20s %s\n" "Wave 1:" "${WAVE1_REQUESTS} 请求（成功 ${WAVE1_SUCCESS}，耗时 ${WAVE1_DURATION}s）"
printf "  %-20s %s\n" "Wave 2:" "${WAVE2_REQUESTS} 请求（耗时 ${WAVE2_DURATION}s）"
printf "  %-20s %s\n" "总请求:" "${TOTAL_REQUESTS}"
printf "  %-20s %s\n" "总成功:" "${SUCCESS_COUNT}"
printf "  %-20s %s\n" "总失败:" "${FAIL_COUNT}"
printf "  %-20s %ss\n" "总耗时:" "${TOTAL_DURATION}"
if [[ $TOTAL_DURATION -gt 0 ]]; then
  QPS=$(awk "BEGIN{printf \"%.2f\", ${TOTAL_REQUESTS}/${TOTAL_DURATION}}")
  printf "  %-20s %s\n" "平均 QPS:" "${QPS}"
fi
echo -e "${BOLD}────────────────────────────────────────────────────────────${NC}"
echo ""

# HPA 最终状态
info "最终 HPA 状态："
kubectl get hpa -n "${NAMESPACE}" 2>/dev/null || true
echo ""
info "最终 Pod 列表："
kubectl get pods -n "${NAMESPACE}" -o wide 2>/dev/null || true
echo ""

# ─── Per-Pod 流量分布（通过 Prometheus 查询） ──────────────────
info "Per-Pod 负载分布（max_over_time inflight，最近 15 分钟）："
PROM_RESULT=$(curl -sG "http://localhost:9090/api/v1/query" \
  --data-urlencode "query=max_over_time(dynamo_component_inflight_requests{namespace=\"${NAMESPACE}\"}[15m])" \
  2>/dev/null || echo "")
if [[ -n "$PROM_RESULT" ]]; then
  echo "$PROM_RESULT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    results = data.get('data', {}).get('result', [])
    if not results:
        print('  (无数据 — Prometheus 可能未采集到足够数据)')
    else:
        for r in sorted(results, key=lambda x: float(x['value'][1]), reverse=True):
            pod = r['metric'].get('pod', 'unknown')
            val = float(r['value'][1])
            bar_len = min(int(val), 30)
            bar = '█' * bar_len + '░' * max(0, 20 - bar_len)
            print(f'  {pod:60s} peak_inflight={val:6.1f}  {bar}')
except Exception as e:
    print(f'  (解析失败: {e})')
" 2>/dev/null || echo "  (Prometheus 不可达，请确认 port-forward 运行中)"
else
  echo "  (Prometheus 不可达，请确认 port-forward 运行中)"
fi
echo ""

# ─── 扩容事件 + 诊断 ──────────────────────────────────────────
if [[ $DECODE_SCALED -eq 1 || $PREFILL_SCALED -eq 1 || $FRONTEND_SCALED -eq 1 ]]; then
  ok "HPA 扩容已触发 ✓"
  info "扩容事件："
  kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' 2>/dev/null \
    | grep -iE "SuccessfulRescale|ScalingReplicaSet" | tail -10 || true
  echo ""
  info "缩容将在负载停止约 300s 后自动发生"
  echo "  观察命令：watch -n 10 'kubectl get hpa,pods -n ${NAMESPACE}'"
else
  warn "负载期间未观察到 HPA 扩容"
  echo ""
  echo "  诊断步骤："
  echo "    1. kubectl logs -n ${MONITORING_NS} -l app.kubernetes.io/name=prometheus-adapter --tail=20"
  echo "    2. kubectl describe hpa -n ${NAMESPACE}"
  echo "    3. kubectl get --raw '/apis/custom.metrics.k8s.io/v1beta1/namespaces/${NAMESPACE}/pods/*/dynamo_inflight_requests'"
  echo "    4. 如需重新部署 adapter：bash setup.sh"
fi

echo ""
info "Grafana 完整时序数据："
echo "  http://localhost:3000 → Dashboard: 'Dynamo — HPA & Router Monitor'"
echo "  重点面板："
echo "    - HPA Replicas:      观察扩容/缩容时间线"
echo "    - Inflight per Pod:  观察 Router 将请求分发到不同 Pod"
echo "    - Request Rate:      确认新 Pod 在 Wave 2 中处理了流量"
