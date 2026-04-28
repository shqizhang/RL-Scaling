# Dynamo 0.7.1 HPA 自动扩容 & Router 功能验证测试文档

> **前提**：已按照 `dynamo-0.7.1.md` 完成部署，所有 Pod Running，推理 API 可用。  
> **目标**：部署 Ingress 流量入口 → 配置 Prometheus 指标采集 → 启用 HPA 自动扩容 → 模拟负载 → 验证 HPA 扩容行为 & Dynamo Router 路由正确性。

---

## 目录

- [环境现状确认](#环境现状确认)
- [Step 1：部署 NGINX Ingress Controller](#step-1部署-nginx-ingress-controller)
- [Step 2：创建 Ingress 资源指向 Dynamo Frontend](#step-2创建-ingress-资源指向-dynamo-frontend)
- [Step 3：确认 Prometheus 指标采集链路](#step-3确认-prometheus-指标采集链路)
- [Step 4：安装 Prometheus Adapter（自定义指标 → HPA）](#step-4安装-prometheus-adapter自定义指标--hpa)
- [Step 5：配置 HPA 自动扩容策略](#step-5配置-hpa-自动扩容策略)
- [Step 6：模拟负载脚本](#step-6模拟负载脚本)
- [Step 7：执行测试 & 验证 HPA 扩容](#step-7执行测试--验证-hpa-扩容)
- [Step 8：验证 Dynamo Router 路由正确性](#step-8验证-dynamo-router-路由正确性)
- [Step 9：Grafana Dashboard 可视化验证](#step-9grafana-dashboard-可视化验证)
- [清理 & 回滚](#清理--回滚)
- [故障排查](#故障排查)

---

## 环境现状确认

在开始测试之前，先确认所有前置组件已就绪。

```bash
# 设置环境变量（与 dynamo-0.7.1.md 保持一致）
export NAMESPACE=dynamo-system
export MODEL_NAME="Qwen/Qwen3-0.6B"
```

```bash
# 1. 确认推理 Pod 全部 Running
kubectl get pods -n ${NAMESPACE}

# 预期输出（6 个 Pod 全部 Running）：
# dynamo-platform-dynamo-operator-controller-manager-*   2/2  Running
# dynamo-platform-etcd-0                                 1/1  Running
# dynamo-platform-nats-0                                 2/2  Running
# vllm-v1-disagg-router-frontend-*                       1/1  Running
# vllm-v1-disagg-router-vllmdecodeworker-*               1/1  Running
# vllm-v1-disagg-router-vllmprefillworker-*              1/1  Running

# 2. 确认 Prometheus & Grafana 正常
kubectl get pods -n monitoring | grep -E 'prometheus|grafana'

# 预期：prometheus-grafana-*  3/3  Running

# 3. 确认 DGD 就绪
kubectl get dynamographdeployment -n ${NAMESPACE}

# 预期：READY=True

# 4. 快速验证推理能力
kubectl port-forward svc/vllm-v1-disagg-router-frontend 8000:8000 -n ${NAMESPACE} &
sleep 3
curl -s http://localhost:8000/v1/models | python3 -m json.tool
# 预期：返回包含 Qwen/Qwen3-0.6B 的模型列表
kill %1 2>/dev/null  # 清理 port-forward
```

> ✅ 以上全部通过后继续下一步。

---

## Step 1：部署 NGINX Ingress Controller

> **目的**：在 K8s 集群中部署一个 Ingress Controller 作为统一流量入口，替代 `kubectl port-forward`。单节点部署使用 `hostPort` 模式直接监听节点 80/443 端口。

### 1.1 添加 ingress-nginx Helm 仓库

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
```

### 1.2 安装 ingress-nginx（单节点 hostPort 模式）

```bash
cat > /tmp/ingress-nginx-values.yaml << 'EOF'
controller:
  kind: DaemonSet
  hostPort:
    enabled: true
  service:
    type: ClusterIP    # 单节点无需 LoadBalancer
  # 允许调度到 control-plane 节点（单节点集群必须）
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
  # Prometheus 指标
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
      namespace: monitoring
  # 允许 SSE 流式响应（推理长请求）
  config:
    proxy-read-timeout: "3600"
    proxy-send-timeout: "3600"
    proxy-buffering: "off"
EOF

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --values /tmp/ingress-nginx-values.yaml \
  --wait
```

### 1.3 验证

```bash
kubectl get pods -n ingress-nginx
# 预期：ingress-nginx-controller-*  1/1  Running

kubectl get svc -n ingress-nginx
# 预期：看到 ingress-nginx-controller 的 ClusterIP Service

# 测试 Ingress Controller 是否监听在节点 80 端口
curl -s -o /dev/null -w "%{http_code}" http://localhost:80
# 预期返回：404（Ingress Controller 默认返回 404，说明已在监听）
```

> ✅ 返回 `404` 表示 Ingress Controller 正常运行。
![alt text](image-10.png)
---

## Step 2：创建 Ingress 资源指向 Dynamo Frontend

> **目的**：创建 Ingress 规则，将外部流量通过 NGINX Ingress Controller 路由到 Dynamo Frontend Service。

### 2.1 确认 Frontend Service 名称和端口

```bash
kubectl get svc -n ${NAMESPACE} | grep frontend
# 预期输出示例：
# vllm-v1-disagg-router-frontend   ClusterIP   10.x.x.x   <none>   8000/TCP   6d
```

### 2.2 创建 Ingress 资源

```bash
cat > /tmp/dynamo-ingress.yaml << EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dynamo-frontend-ingress
  namespace: ${NAMESPACE}
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-buffering: "off"
    # 推理请求可能较大
    nginx.ingress.kubernetes.io/proxy-body-size: "100m"
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /v1
        pathType: Prefix
        backend:
          service:
            name: vllm-v1-disagg-router-frontend
            port:
              number: 8000
EOF

kubectl apply -f /tmp/dynamo-ingress.yaml
```

### 2.3 验证 Ingress 流量路径

```bash
# 查看 Ingress 状态
kubectl get ingress -n ${NAMESPACE}
# 预期：dynamo-frontend-ingress  nginx  *  /v1  80
![alt text](image-11.png)
# 通过 Ingress 调用推理 API（不需要 port-forward）
curl -s http://localhost/v1/models | python3 -m json.tool
# 预期：返回模型列表
![alt text](image-12.png)
# 通过 Ingress 发送推理请求
curl http://localhost/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "'"${MODEL_NAME}"'",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 50
  }'
# 预期：正常返回推理结果
```
![alt text](image-13.png)
> ✅ 通过 `http://<节点IP>/v1/...` 可直接访问推理 API，不再需要 port-forward。

---

## Step 3：确认 Prometheus 指标采集链路

> **目的**：确认 Prometheus 已正确采集 Dynamo 组件的指标（`dynamo_component_*`），这是后续 HPA 依赖的数据源。

### 3.1 Dynamo 指标暴露端口说明

> 以下端口信息已通过 `kubectl get pods -o jsonpath` 实际验证，而非来自官方文档假设。

| 组件 | 指标端口 | 指标路径 | 指标前缀 | 验证方式 |
|------|---------|---------|---------|---------|
| Frontend | **8000** | `/metrics` | `dynamo_*`、`http_*` | 容器 `main` 端口 8000 |
| PrefillWorker | **9090** | `/metrics` | `dynamo_component_*` | 容器 `main` 端口 9090 |
| DecodeWorker | **9090** | `/metrics` | `dynamo_component_*` | 容器 `main` 端口 9090 |

### 3.2 验证 PodMonitor 是否存在

Dynamo Operator 在部署推理服务时应自动创建 PodMonitor（供 Prometheus 自动发现 Pod 指标端口）。

```bash
kubectl get podmonitor -n ${NAMESPACE}
# 实际输出：
# NAME              AGE
# dynamo-frontend   6d8h
# dynamo-planner    6d8h
# dynamo-worker     6d8h
```

> ✅ Dynamo Operator 已自动创建 PodMonitor，无需手动创建。

### 3.3 PodMonitor 与 Pod Label 匹配关系（已验证）

PodMonitor 通过以下 label 选中 Pod：

| PodMonitor | selector | 匹配的 Pod |
|-----------|----------|-----------|
| `dynamo-frontend` | `nvidia.com/dynamo-component-type: frontend` + `nvidia.com/metrics-enabled: true` | Frontend |
| `dynamo-worker` | `nvidia.com/dynamo-component-type: worker` + `nvidia.com/metrics-enabled: true` | PrefillWorker、DecodeWorker |

验证命令：

```bash
# Worker Pod（Prefill + Decode）
kubectl get pods -n ${NAMESPACE} \
  -l nvidia.com/dynamo-component-type=worker,nvidia.com/metrics-enabled=true
# 预期：返回 prefillworker 和 decodeworker 两个 Pod

# Frontend Pod
kubectl get pods -n ${NAMESPACE} \
  -l nvidia.com/dynamo-component-type=frontend,nvidia.com/metrics-enabled=true
# 预期：返回 frontend Pod
```

### 3.4 验证 Prometheus 采集状态

```bash
# 端口转发 Prometheus
kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n monitoring &
sleep 3

# 方法1：查看 Prometheus Targets 页面
echo "浏览器访问：http://localhost:9090/targets"
echo "搜索 'dynamo' 或 'podMonitor'，确认所有 endpoint 状态为 UP"

# 方法2：直接查询 Dynamo 指标
curl -s "http://localhost:9090/api/v1/query?query=up{namespace='${NAMESPACE}'}" \
  | python3 -m json.tool

# 方法3：查询 dynamo_component 指标是否已采集
curl -s 'http://localhost:9090/api/v1/query?query=dynamo_component_inflight_requests' \
  | python3 -m json.tool
![alt text](image-15.png)
# 方法4：列出所有 dynamo 相关指标名
curl -s 'http://localhost:9090/api/v1/label/__name__/values' \
  | python3 -c "import sys,json; names=json.load(sys.stdin)['data']; [print(n) for n in names if 'dynamo' in n.lower()]"
```
```
dynamo_component_inflight_requests
dynamo_component_kvstats_active_blocks
dynamo_component_kvstats_gpu_cache_usage_percent
dynamo_component_kvstats_gpu_prefix_cache_hit_rate
dynamo_component_kvstats_total_blocks
dynamo_component_nats_client_connection_state
dynamo_component_nats_client_current_connections
dynamo_component_nats_client_in_messages
dynamo_component_nats_client_in_total_bytes
dynamo_component_nats_client_out_messages
dynamo_component_nats_client_out_overhead_bytes
dynamo_component_nats_service_active_endpoints
dynamo_component_nats_service_active_services
dynamo_component_nats_service_errors_total
dynamo_component_nats_service_processing_ms_avg
dynamo_component_nats_service_processing_ms_total
dynamo_component_nats_service_requests_total
dynamo_component_request_bytes_total
dynamo_component_request_duration_seconds_bucket
dynamo_component_request_duration_seconds_count
dynamo_component_request_duration_seconds_sum
dynamo_component_requests_total
dynamo_component_response_bytes_total
dynamo_component_uptime_seconds
dynamo_frontend_disconnected_clients
dynamo_frontend_inflight_requests
dynamo_frontend_input_sequence_tokens_bucket
dynamo_frontend_input_sequence_tokens_count
dynamo_frontend_input_sequence_tokens_sum
dynamo_frontend_inter_token_latency_seconds_bucket
dynamo_frontend_inter_token_latency_seconds_count
dynamo_frontend_inter_token_latency_seconds_sum
dynamo_frontend_model_context_length
dynamo_frontend_model_kv_cache_block_size
dynamo_frontend_model_max_num_batched_tokens
dynamo_frontend_model_max_num_seqs
dynamo_frontend_model_migration_limit
dynamo_frontend_model_total_kv_blocks
dynamo_frontend_output_sequence_tokens_bucket
dynamo_frontend_output_sequence_tokens_count
dynamo_frontend_output_sequence_tokens_sum
dynamo_frontend_output_tokens_total
dynamo_frontend_queued_requests
dynamo_frontend_request_duration_seconds_bucket
dynamo_frontend_request_duration_seconds_count
dynamo_frontend_request_duration_seconds_sum
dynamo_frontend_requests_total
dynamo_frontend_time_to_first_token_seconds_bucket
dynamo_frontend_time_to_first_token_seconds_count
dynamo_frontend_time_to_first_token_seconds_sum
```

> ✅ **验收标准**：
> 1. `http://localhost:9090/targets` 页面可看到 dynamo Pod 的 scrape target，状态 `UP`
> 2. `dynamo_component_inflight_requests` 查询有返回数据
> 3. 指标名列表中出现 `dynamo_component_*` 开头的指标

### 3.5 关键指标说明（已根据实际 `/metrics` 输出确认）

| 指标名 | 类型 | 含义 | 用途 |
|--------|------|------|------|
| `dynamo_component_inflight_requests` | Gauge | 当前正在处理的请求数（按 endpoint 分） | **HPA 扩缩容依据** |
| `dynamo_component_kvstats_active_blocks` | Gauge | 活跃 KV Cache block 数量 | 容量监控 |
| `dynamo_component_kvstats_gpu_cache_usage_percent` | Gauge | GPU Cache 使用率（0.0~1.0） | 容量规划 |
| `dynamo_component_nats_client_connection_state` | Gauge | NATS 连接状态（0=断开, 1=连接, 2=重连） | 健康检查 |

> ⚠️ **注意**：Dynamo 0.7.1 的 Worker 指标以 `dynamo_component_*` 为前缀，而非官方文档中提到的 `vllm:*`。`vllm:*` 指标可能在更高版本或不同配置下才暴露。请运行以下命令获取完整指标列表：
> ```bash
> kubectl exec -n ${NAMESPACE} <worker-pod-name> -- sh -c "curl -s http://localhost:9090/metrics | grep '^# HELP'"
> ```

```bash
kill %1 2>/dev/null  # 清理 port-forward
```

---

## Step 4：安装 Prometheus Adapter（自定义指标 → HPA）

> **目的**：K8s 原生 HPA 只支持 CPU/Memory 指标。要基于推理业务指标（如排队请求数、KV Cache 使用率）自动扩容，需要通过 `prometheus-adapter` 将 Prometheus 指标暴露为 K8s Custom Metrics API。

### 4.1 安装 prometheus-adapter

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

cat > /tmp/prom-adapter-values.yaml << 'EOF'
prometheus:
  url: http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local
  port: 9090

rules:
  custom:
    # 规则1：当前正在处理的推理请求数（每个 Worker Pod 的 generate endpoint）
    - seriesQuery: 'dynamo_component_inflight_requests{namespace!="",pod!=""}'
      resources:
        overrides:
          namespace: {resource: "namespace"}
          pod: {resource: "pod"}
      name:
        matches: "^(.*)"
        as: "dynamo_inflight_requests"
      metricsQuery: 'sum(<<.Series>>{<<.LabelMatchers>>,dynamo_endpoint="generate"}) by (<<.GroupBy>>)'

    # 规则2：GPU Cache 使用率
    - seriesQuery: 'dynamo_component_kvstats_gpu_cache_usage_percent{namespace!="",pod!=""}'
      resources:
        overrides:
          namespace: {resource: "namespace"}
          pod: {resource: "pod"}
      name:
        matches: "^(.*)"
        as: "dynamo_gpu_cache_usage"
      metricsQuery: 'avg(<<.Series>>{<<.LabelMatchers>>}) by (<<.GroupBy>>)'

    # 规则3：活跃 KV Cache block 数量
    - seriesQuery: 'dynamo_component_kvstats_active_blocks{namespace!="",pod!=""}'
      resources:
        overrides:
          namespace: {resource: "namespace"}
          pod: {resource: "pod"}
      name:
        matches: "^(.*)"
        as: "dynamo_kv_active_blocks"
      metricsQuery: 'avg(<<.Series>>{<<.LabelMatchers>>}) by (<<.GroupBy>>)'
EOF

# 检查是否已安装
if helm status prometheus-adapter -n monitoring &>/dev/null; then
  echo "prometheus-adapter already installed, upgrading..."
  helm upgrade prometheus-adapter \
    prometheus-community/prometheus-adapter \
    --namespace monitoring \
    --values /tmp/prom-adapter-values.yaml \
    --wait
else
  helm install prometheus-adapter \
    prometheus-community/prometheus-adapter \
    --namespace monitoring \
    --values /tmp/prom-adapter-values.yaml \
    --wait
fi
```

### 4.2 验证 Custom Metrics API

```bash
# 等待 adapter Pod 就绪
kubectl get pods -n monitoring | grep adapter
# 预期：prometheus-adapter-*  1/1  Running

# 验证 Custom Metrics API 已注册
kubectl get apiservice | grep custom.metrics
# 预期：v1beta1.custom.metrics.k8s.io   monitoring/prometheus-adapter   True
![alt text](image-16.png)
# 查询实际暴露的自定义指标
kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1" | python3 -m json.tool | head -40

# 查询特定指标的值（需要先发送过推理请求以产生数据）
kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/${NAMESPACE}/pods/*/dynamo_inflight_requests" 2>/dev/null | python3 -m json.tool
```

> ✅ **验收标准**：
> 1. `v1beta1.custom.metrics.k8s.io` APIService 存在且 `Available=True`
> 2. 查询自定义指标有返回（发送推理请求后）

> ⚠️ **如果指标查不到**：可能是 Prometheus 尚未采集到 `vllm:*` 指标。先执行 Step 3.4 确认 Prometheus 已有数据，再回来验证。

---

## Step 5：配置 HPA 自动扩容策略

> **目的**：为 Frontend、PrefillWorker、DecodeWorker 分别创建 HPA，基于推理业务指标自动扩缩 Pod 数量。

### 5.1 HPA 方案选择

由于 Dynamo 使用 DGD（DynamoGraphDeployment）管理 Pod，底层实际是 Deployment，HPA 需要绑定到对应的 Deployment：

```bash
# 查看 DGD 创建的 Deployment 名称
kubectl get deployment -n ${NAMESPACE}
# 预期输出：
# vllm-v1-disagg-router-frontend             1/1   1   1   6d
# vllm-v1-disagg-router-vllmdecodeworker      1/1   1   1   6d
# vllm-v1-disagg-router-vllmprefillworker     1/1   1   1   6d
```
![alt text](image-17.png)

### 5.2 方案 A：基于 CPU 使用率的 HPA（简单方案，推荐先验证）

此方案不依赖 prometheus-adapter，可以先用来验证 HPA 机制本身是否工作：

```bash
# 确认 metrics-server 已安装（HPA 基于 CPU/Memory 需要它）
kubectl get deployment metrics-server -n kube-system
# 如果不存在，安装：
# kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Frontend HPA（基于 CPU）
cat > /tmp/hpa-frontend-cpu.yaml << EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: hpa-frontend
  namespace: ${NAMESPACE}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: vllm-v1-disagg-router-frontend
  minReplicas: 1
  maxReplicas: 3
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 60
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30    # 快速扩容
      policies:
      - type: Pods
        value: 1
        periodSeconds: 30
    scaleDown:
      stabilizationWindowSeconds: 300   # 缩容冷却 5 分钟
      policies:
      - type: Pods
        value: 1
        periodSeconds: 60
EOF

kubectl apply -f /tmp/hpa-frontend-cpu.yaml
```

### 5.3 方案 B：基于推理指标的 HPA（生产推荐，需要 Step 4 完成）

```bash
# DecodeWorker HPA：基于 inflight generate 请求数
cat > /tmp/hpa-decode-custom.yaml << EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: hpa-decode-worker
  namespace: ${NAMESPACE}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: vllm-v1-disagg-router-vllmdecodeworker
  minReplicas: 1
  maxReplicas: 2
  metrics:
  - type: Pods
    pods:
      metric:
        name: dynamo_inflight_requests
      target:
        type: AverageValue
        averageValue: "5"      # 每个 Pod 平均 inflight 请求数超过 5 触发扩容
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30
      policies:
      - type: Pods
        value: 1
        periodSeconds: 30
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Pods
        value: 1
        periodSeconds: 60
EOF

# PrefillWorker HPA：同样基于 inflight 请求数
cat > /tmp/hpa-prefill-custom.yaml << EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: hpa-prefill-worker
  namespace: ${NAMESPACE}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: vllm-v1-disagg-router-vllmprefillworker
  minReplicas: 1
  maxReplicas: 2
  metrics:
  - type: Pods
    pods:
      metric:
        name: dynamo_inflight_requests
      target:
        type: AverageValue
        averageValue: "5"
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30
      policies:
      - type: Pods
        value: 1
        periodSeconds: 30
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Pods
        value: 1
        periodSeconds: 60
EOF

# Frontend HPA：基于 inflight 请求数
cat > /tmp/hpa-frontend-custom.yaml << EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: hpa-frontend
  namespace: ${NAMESPACE}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: vllm-v1-disagg-router-frontend
  minReplicas: 1
  maxReplicas: 3
  metrics:
  - type: Pods
    pods:
      metric:
        name: dynamo_inflight_requests
      target:
        type: AverageValue
        averageValue: "10"    # inflight 超过 10 个请求触发扩容
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30
      policies:
      - type: Pods
        value: 1
        periodSeconds: 30
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Pods
        value: 1
        periodSeconds: 60
EOF

kubectl apply -f /tmp/hpa-decode-custom.yaml
kubectl apply -f /tmp/hpa-prefill-custom.yaml
kubectl apply -f /tmp/hpa-frontend-custom.yaml
```

### 5.4 验证 HPA 已创建

```bash
kubectl get hpa -n ${NAMESPACE}
# 预期输出：
# NAME                 REFERENCE                                        TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
# hpa-frontend         Deployment/vllm-v1-disagg-router-frontend        0/10      1         3         1          10s
# hpa-decode-worker    Deployment/vllm-v1-disagg-router-vllmdecodeworker 0/5       1         2         1          10s
# hpa-prefill-worker   Deployment/vllm-v1-disagg-router-vllmprefillworker 0/5      1         2         1          10s
![alt text](image-18.png)
# 如果 TARGETS 显示 <unknown>/5，说明指标尚未就绪，检查 Step 3 和 Step 4
kubectl describe hpa -n ${NAMESPACE}
# 查看 Events 和 Conditions 中的详细信息
```

> ✅ **验收标准**：TARGETS 列显示实际数值（如 `0/5`），而非 `<unknown>/5`。

---

## Step 6：模拟负载脚本

> **目的**：生成持续的推理请求负载，触发 HPA 扩容，并同时观察 Dynamo Router 的路由行为。

### 6.1 创建负载测试脚本

```bash
cat > /tmp/load-test-dynamo.sh << 'SCRIPT'
#!/bin/bash
# ============================================================
# Dynamo 负载测试脚本
# 用途：向推理 API 发送持续并发请求，触发 HPA 扩容
# ============================================================

ENDPOINT="${DYNAMO_ENDPOINT:-http://localhost/v1/chat/completions}"
MODEL="${MODEL_NAME:-Qwen/Qwen3-0.6B}"
CONCURRENCY="${CONCURRENCY:-10}"        # 并发数
TOTAL_REQUESTS="${TOTAL_REQUESTS:-200}" # 总请求数
MAX_TOKENS="${MAX_TOKENS:-100}"          # 每个请求生成的 token 数

echo "============================================"
echo "Dynamo 负载测试"
echo "============================================"
echo "Endpoint:       ${ENDPOINT}"
echo "Model:          ${MODEL}"
echo "Concurrency:    ${CONCURRENCY}"
echo "Total Requests: ${TOTAL_REQUESTS}"
echo "Max Tokens:     ${MAX_TOKENS}"
echo "============================================"
echo ""

# 计数器
SUCCESS=0
FAIL=0
START_TIME=$(date +%s)

# 不同的 prompt 模拟不同的请求（测试 KV Router 缓存命中）
PROMPTS=(
  "Explain the theory of relativity in detail"
  "Write a Python function to sort a list"
  "What is Kubernetes and how does it work"
  "Describe the architecture of a neural network"
  "Tell me about the history of computing"
  "How does HTTP/2 differ from HTTP/1.1"
  "Explain quantum computing in simple terms"
  "Write a REST API design for a todo app"
  "What are the benefits of microservices"
  "Describe the MapReduce programming model"
)

# 重复使用部分 prompt（测试 KV Cache 命中率）
REPEATED_PROMPTS=(
  "Explain the theory of relativity in detail"
  "Write a Python function to sort a list"
  "What is Kubernetes and how does it work"
)

send_request() {
  local req_id=$1

  # 70% 使用重复 prompt（测试缓存命中），30% 随机
  if (( RANDOM % 10 < 7 )); then
    local prompt="${REPEATED_PROMPTS[$((RANDOM % ${#REPEATED_PROMPTS[@]}))]}"
  else
    local prompt="${PROMPTS[$((RANDOM % ${#PROMPTS[@]}))]}"
  fi

  local response
  response=$(curl -s -w "\n%{http_code}" --max-time 120 "${ENDPOINT}" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "'"${MODEL}"'",
      "messages": [{"role": "user", "content": "'"${prompt}"'"}],
      "max_tokens": '"${MAX_TOKENS}"'
    }' 2>/dev/null)

  local http_code=$(echo "$response" | tail -1)
  local body=$(echo "$response" | sed '$d')

  if [[ "$http_code" == "200" ]]; then
    echo "[$(date +%H:%M:%S)] Request #${req_id} ✅ (HTTP ${http_code})"
    return 0
  else
    echo "[$(date +%H:%M:%S)] Request #${req_id} ❌ (HTTP ${http_code})"
    return 1
  fi
}

# 并发发送请求
echo "开始发送请求..."
echo ""

PIDS=()
for ((i=1; i<=TOTAL_REQUESTS; i++)); do
  send_request $i &
  PIDS+=($!)

  # 控制并发数
  while (( $(jobs -rp | wc -l) >= CONCURRENCY )); do
    sleep 0.1
  done
done

# 等待所有请求完成
for pid in "${PIDS[@]}"; do
  wait $pid
  if [[ $? -eq 0 ]]; then
    ((SUCCESS++))
  else
    ((FAIL++))
  fi
done

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo "============================================"
echo "测试完成"
echo "============================================"
echo "总请求数:  ${TOTAL_REQUESTS}"
echo "成功:      ${SUCCESS}"
echo "失败:      ${FAIL}"
echo "总耗时:    ${DURATION}s"
echo "QPS:       $(echo "scale=2; ${TOTAL_REQUESTS}/${DURATION}" | bc)"
echo "============================================"
SCRIPT

chmod +x /tmp/load-test-dynamo.sh
```

### 6.2 创建 Python 版本负载脚本（更精准的指标统计）

```bash
cat > /tmp/load-test-dynamo2.py << 'PYEOF'
#!/usr/bin/env python3
"""
Dynamo 负载测试脚本（Python 版）
功能：并发发送推理请求，统计 TTFT/ITL/吞吐量，支持流式响应
"""

import argparse
import asyncio
import json
import time
import aiohttp
import statistics
import sys

DEFAULT_PROMPTS = [
    "How does garbage collection work in modern programming languages",
    "Explain the difference between TCP and UDP protocols",
    "What are the main principles of object-oriented programming",
    "Describe how a distributed hash table works",
    "Write a brief overview of the MapReduce programming model",
]

# 重复 prompt 用于测试 KV Cache 命中
REPEATED_PROMPTS = [
    "How does garbage collection work in modern programming languages",
    "Explain the difference between TCP and UDP protocols",
]

async def send_request(session, endpoint, model, prompt, max_tokens, request_id, stream=False):
    """发送单个推理请求并返回指标"""
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "stream": stream,
    }
    start_time = time.monotonic()
    ttft = None
    token_times = []

    try:
        async with session.post(endpoint, json=payload, timeout=aiohttp.ClientTimeout(total=120)) as resp:
            if stream:
                async for line in resp.content:
                    line = line.decode("utf-8").strip()
                    if line.startswith("data: ") and line != "data: [DONE]":
                        now = time.monotonic()
                        if ttft is None:
                            ttft = now - start_time
                        token_times.append(now)
            else:
                body = await resp.json()
                ttft = time.monotonic() - start_time

            e2e = time.monotonic() - start_time
            status = resp.status

            itl_list = []
            for i in range(1, len(token_times)):
                itl_list.append(token_times[i] - token_times[i - 1])

            result = {
                "request_id": request_id,
                "status": status,
                "ttft": ttft,
                "e2e": e2e,
                "itl_avg": statistics.mean(itl_list) if itl_list else None,
                "success": status == 200,
            }
            tag = "✅" if status == 200 else "❌"
            print(f"[{time.strftime('%H:%M:%S')}] #{request_id:04d} {tag}  TTFT={ttft:.3f}s  E2E={e2e:.3f}s")
            return result

    except Exception as e:
        e2e = time.monotonic() - start_time
        print(f"[{time.strftime('%H:%M:%S')}] #{request_id:04d} ❌  ERROR: {e}")
        return {"request_id": request_id, "status": 0, "ttft": None, "e2e": e2e, "success": False}

async def run_load_test(endpoint, model, concurrency, total, max_tokens, stream):
    """执行并发负载测试"""
    import random

    semaphore = asyncio.Semaphore(concurrency)
    results = []

    async def bounded_request(req_id):
        async with semaphore:
            # 70% 重复 prompt，30% 随机
            if random.random() < 0.7:
                prompt = random.choice(REPEATED_PROMPTS)
            else:
                prompt = random.choice(DEFAULT_PROMPTS)
            async with aiohttp.ClientSession() as session:
                result = await send_request(session, endpoint, model, prompt, max_tokens, req_id, stream)
                results.append(result)

    print("=" * 60)
    print("Dynamo 负载测试 (Python)")
    print("=" * 60)
    print(f"Endpoint:        {endpoint}")
    print(f"Model:           {model}")
    print(f"Concurrency:     {concurrency}")
    print(f"Total Requests:  {total}")
    print(f"Max Tokens:      {max_tokens}")
    print(f"Stream:          {stream}")
    print("=" * 60)
    print()

    start = time.monotonic()
    tasks = [bounded_request(i) for i in range(1, total + 1)]
    await asyncio.gather(*tasks)
    duration = time.monotonic() - start

    # 统计
    successes = [r for r in results if r["success"]]
    failures = [r for r in results if not r["success"]]
    ttfts = [r["ttft"] for r in successes if r["ttft"] is not None]
    e2es = [r["e2e"] for r in successes]

    print()
    print("=" * 60)
    print("测试结果")
    print("=" * 60)
    print(f"总请求数:     {total}")
    print(f"成功:         {len(successes)}")
    print(f"失败:         {len(failures)}")
    print(f"总耗时:       {duration:.2f}s")
    print(f"QPS:          {total / duration:.2f}")
    if ttfts:
        print(f"TTFT P50:     {statistics.median(ttfts):.3f}s")
        print(f"TTFT P90:     {sorted(ttfts)[int(len(ttfts) * 0.9)]:.3f}s")
        print(f"TTFT P99:     {sorted(ttfts)[int(len(ttfts) * 0.99)]:.3f}s")
    if e2es:
        print(f"E2E P50:      {statistics.median(e2es):.3f}s")
        print(f"E2E P90:      {sorted(e2es)[int(len(e2es) * 0.9)]:.3f}s")
    print("=" * 60)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Dynamo Load Test")
    parser.add_argument("--endpoint", default="http://localhost/v1/chat/completions")
    parser.add_argument("--model", default="Qwen/Qwen3-0.6B")
    parser.add_argument("--concurrency", type=int, default=10)
    parser.add_argument("--total", type=int, default=200)
    parser.add_argument("--max-tokens", type=int, default=100)
    parser.add_argument("--stream", action="store_true")
    args = parser.parse_args()

    asyncio.run(run_load_test(args.endpoint, args.model, args.concurrency, args.total, args.max_tokens, args.stream))
PYEOF
```

---

## Step 7：执行测试 & 验证 HPA 扩容

> **目的**：运行负载测试，实时观察 HPA 是否正确触发扩容。

### 7.1 准备监控终端

**打开 3 个终端窗口**，分别执行以下监控命令：

**终端 1：实时监控 HPA 状态**
```bash
export NAMESPACE=dynamo-system
watch -n 5 kubectl get hpa -n ${NAMESPACE}
# 观察 TARGETS 值和 REPLICAS 列的变化
```

**终端 2：实时监控 Pod 数量**
```bash
export NAMESPACE=dynamo-system
watch -n 5 kubectl get pods -n ${NAMESPACE}
# 观察是否有新 Pod 被创建
```

**终端 3：实时查看 HPA 事件日志**
```bash
export NAMESPACE=dynamo-system
kubectl get events -n ${NAMESPACE} --watch --field-selector reason=SuccessfulRescale
# 当 HPA 触发扩缩容时，这里会实时显示事件
```
![alt text](image-19.png)
### 7.2 执行负载测试

在第 4 个终端中运行：

```bash
export MODEL_NAME="Qwen/Qwen3-0.6B"

# 方法1：使用 bash 脚本
CONCURRENCY=20 TOTAL_REQUESTS=300 MAX_TOKENS=200 bash /tmp/load-test-dynamo.sh

# 方法2：使用 Python 脚本（需要 pip install aiohttp）
pip install aiohttp
python3 /tmp/load-test-dynamo2.py \
  --endpoint http://localhost/v1/chat/completions \
  --model "Qwen/Qwen3-0.6B" \
  --concurrency 20 \
  --total 300 \
  --max-tokens 200
```

### 7.3 验证 HPA 扩容行为

在负载测试运行过程中（约 1~3 分钟后），观察终端 1 的 HPA 变化：

```bash
# 手动检查
kubectl get hpa -n ${NAMESPACE}
# 预期：REPLICAS 从 1 变为 2 或更多
![alt text](image-20.png)

kubectl describe hpa hpa-decode-worker -n ${NAMESPACE}
# 查看 Events 部分，应看到类似：
# Events:
#   Type     Reason             Age   From                       Message
#   ----     ------             ----  ----                       -------
#   Normal   SuccessfulRescale  1m    horizontal-pod-autoscaler  New size: 2; reason: pods metric vllm_num_requests_running above target

# 查看是否有新 Pod 创建
kubectl get pods -n ${NAMESPACE} | grep -E 'decode|prefill|frontend'
# 预期：Worker Pod 数量增加
![alt text](image-21.png)
```

### 7.4 验证缩容行为

停止负载测试后，等待 5 分钟（`stabilizationWindowSeconds: 300`）：

```bash
# 持续观察 HPA
watch -n 10 'kubectl get hpa -n dynamo-system && echo "---" && kubectl get pods -n dynamo-system | grep -E "decode|prefill|frontend"'
# 预期：5 分钟后 REPLICAS 逐渐回到 1
```

> ✅ **验收标准**：
> 1. 负载增加时，HPA REPLICAS 从 1 增长到 2+
> 2. HPA Events 中有 `SuccessfulRescale` 事件
> 3. 新 Pod 创建并进入 Running 状态
> 4. 负载停止后 5 分钟内，Pod 缩容回 1

> ⚠️ **单节点 GPU 限制**：如果节点只有 2 张 GPU（Prefill + Decode 各占 1 张），Worker 的 HPA 扩容会因为 GPU 资源不足而无法调度新 Pod。此时可以先验证 Frontend（不需要 GPU）的扩容行为。

---

## Step 8：验证 Dynamo Router 路由正确性

> **目的**：确认 Dynamo 的 KV Router 确实按 Disaggregated 模式将请求分配给 Prefill 和 Decode Worker，且缓存命中路由正常工作。

### 8.1 观察 Worker 日志

```bash
# 终端A：观察 PrefillWorker 日志
kubectl logs -l nvidia.com/dynamo-component-type=worker \
  -n ${NAMESPACE} --prefix=true -f --tail=20 2>&1 | grep -i 'prefill'

# 终端B：观察 DecodeWorker 日志
kubectl logs -l nvidia.com/dynamo-component-type=worker \
  -n ${NAMESPACE} --prefix=true -f --tail=20 2>&1 | grep -i 'decode'

# 终端C：观察 Frontend/Router 日志
kubectl logs -l nvidia.com/dynamo-component-type=frontend \
  -n ${NAMESPACE} -f --tail=20
```

### 8.2 发送测试请求并验证路由

```bash
# 发送多个不同请求
for i in $(seq 1 5); do
  echo "=== Request $i ==="
  curl -s http://localhost/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
      "model": "'"${MODEL_NAME}"'",
      "messages": [{"role": "user", "content": "Count to '"$i"'"}],
      "max_tokens": 30
    }' | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'][:80])"
  echo ""
done
```

### 8.3 验证 KV Cache 命中率（发送重复请求）

```bash
# 发送相同 prompt 多次，触发 KV Cache 命中
for i in $(seq 1 10); do
  curl -s http://localhost/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
      "model": "'"${MODEL_NAME}"'",
      "messages": [{"role": "user", "content": "What is Kubernetes?"}],
      "max_tokens": 30
    }' > /dev/null
  echo "Request $i sent"
done

# 检查 Prometheus 中的缓存命中率指标
kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n monitoring &
sleep 2

# 查询 KV Cache 活跃 block 数（重复请求后应有变化）
curl -s 'http://localhost:9090/api/v1/query?query=dynamo_component_kvstats_active_blocks' | python3 -m json.tool

# 查询 GPU Cache 使用率
curl -s 'http://localhost:9090/api/v1/query?query=dynamo_component_kvstats_gpu_cache_usage_percent' | python3 -m json.tool

# 查询 inflight 请求数变化
curl -s 'http://localhost:9090/api/v1/query?query=dynamo_component_inflight_requests{dynamo_endpoint="generate"}' \
  | python3 -m json.tool

kill %1 2>/dev/null
```

### 8.4 HPA 扩容后验证 Router 自动发现新 Worker

当 HPA 扩容出新的 Worker Pod 后，验证 Router 是否自动将请求分配到新 Pod：

```bash
# 查看当前所有 Worker Pod
kubectl get pods -n ${NAMESPACE} | grep -E 'decode|prefill'

# 查看所有 Worker 的日志，确认新 Pod 也收到了请求
kubectl logs -l nvidia.com/dynamo-component-type=worker \
  -n ${NAMESPACE} --prefix=true --tail=5

# 预期：所有 Worker Pod（包括新创建的）都有请求处理日志
```

> ✅ **验收标准**：
> 1. PrefillWorker 和 DecodeWorker 日志均有活动，说明 Disaggregated 路由正常
> 2. 重复请求后 `dynamo_component_kvstats_active_blocks` 有变化，说明 KV Cache 在工作
> 3. 扩容后新 Worker 也能收到并处理请求

---

## Step 9：Grafana Dashboard 可视化验证

> **目的**：通过 Grafana 看板直观验证整个测试过程中的指标变化。

### 9.1 访问 Grafana

```bash
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring &
echo "浏览器访问：http://localhost:3000"
echo "默认账号：admin"
echo "默认密码："
```

> 获取默认密码：
> ```bash
> kubectl get secret prometheus-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d && echo
> ```


### 9.2 导入 Dynamo Dashboard

如果 Grafana 中没有 Dynamo Dashboard：

```bash
# 检查是否有 Dynamo Dashboard ConfigMap
kubectl get configmap -n monitoring | grep dynamo

# 如果不存在，从 Dynamo 源码下载并导入
# 或者手动创建一个基础 Dashboard
```

### 9.3 手动创建推理监控面板（如果没有预制 Dashboard）

在 Grafana 中创建新 Dashboard，添加以下面板：

| 面板名称 | PromQL 查询 | 面板类型 |
|---------|------------|---------|
| Inflight Requests | `dynamo_component_inflight_requests{namespace="dynamo-system",dynamo_endpoint="generate"}` | Time Series |
| KV Active Blocks | `dynamo_component_kvstats_active_blocks{namespace="dynamo-system"}` | Time Series |
| GPU Cache Usage | `dynamo_component_kvstats_gpu_cache_usage_percent{namespace="dynamo-system"}` | Gauge |
| NATS Connection | `dynamo_component_nats_client_connection_state{namespace="dynamo-system"}` | Stat |
| HPA Replicas | `kube_horizontalpodautoscaler_status_current_replicas{namespace="dynamo-system"}` | Time Series |
| HPA Desired vs Current | `kube_horizontalpodautoscaler_status_desired_replicas{namespace="dynamo-system"}` | Time Series |

### 9.4 验证看板数据

在负载测试期间观察 Grafana Dashboard：

> ✅ **验收标准**：
> 1. Running Requests 在负载测试期间有明显上升
> 2. TTFT 和 token 生成率有数据
> 3. KV Cache 使用率在 0~1 之间变化
> 4. HPA Replicas 面板显示副本数变化
![alt text](image-22.png)
![alt text](image-23.png)
---

## 清理 & 回滚

测试完成后，清理测试资源：

```bash
# 删除 HPA
kubectl delete hpa hpa-frontend hpa-decode-worker hpa-prefill-worker -n ${NAMESPACE} 2>/dev/null

# 删除 Ingress
kubectl delete ingress dynamo-frontend-ingress -n ${NAMESPACE}

# （可选）卸载 Ingress Controller
# helm uninstall ingress-nginx -n ingress-nginx
# kubectl delete namespace ingress-nginx

# （可选）卸载 Prometheus Adapter
# helm uninstall prometheus-adapter -n monitoring

# 确认 Pod 回到初始状态
kubectl get pods -n ${NAMESPACE}
kubectl get deployment -n ${NAMESPACE}
# 预期：所有 Deployment 的 REPLICAS 回到 1/1
```

---

## 故障排查

### HPA 相关

| 问题 | 排查命令 | 可能原因 |
|------|---------|---------|
| HPA TARGETS 显示 `<unknown>` | `kubectl describe hpa <name> -n ${NAMESPACE}` | prometheus-adapter 未安装，或指标名不匹配 |
| HPA 不扩容 | `kubectl get hpa -n ${NAMESPACE} -o yaml` | 指标值未超过阈值，或 `stabilizationWindowSeconds` 太长 |
| 新 Pod Pending | `kubectl describe pod <pod> -n ${NAMESPACE}` | GPU 资源不足（单节点常见） |
| 缩容太慢 | 检查 HPA `behavior.scaleDown.stabilizationWindowSeconds` | 冷却窗口设置过长 |

### Prometheus 相关

| 问题 | 排查命令 | 可能原因 |
|------|---------|---------|
| 无 Dynamo 指标 | `http://localhost:9090/targets` | PodMonitor 未创建或 label 不匹配 |
| 指标值为 0 | 先发送推理请求再查询 | 没有推理流量时指标自然为 0 |
| adapter 无法读取指标 | `kubectl logs -l app.kubernetes.io/name=prometheus-adapter -n monitoring` | adapter rules 配置错误 |

### Ingress 相关

| 问题 | 排查命令 | 可能原因 |
|------|---------|---------|
| 502 Bad Gateway | `kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx` | Backend Service 不可达 |
| 504 Gateway Timeout | 检查 `proxy-read-timeout` annotation | 推理请求超时（增加超时时间） |
| 请求直接返回 404 | `kubectl get ingress -n ${NAMESPACE}` | Ingress path 配置错误 |

### 日志查看速查

```bash
# Ingress Controller 日志
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=50

# Dynamo Operator 日志
kubectl logs -l app.kubernetes.io/name=dynamo-operator -n ${NAMESPACE} --tail=50

# Frontend 日志
kubectl logs -l nvidia.com/dynamo-component-type=frontend -n ${NAMESPACE} --tail=50

# Worker 日志（Prefill + Decode）
kubectl logs -l nvidia.com/dynamo-component-type=worker -n ${NAMESPACE} --prefix=true --tail=50

# HPA 事件
kubectl get events -n ${NAMESPACE} --sort-by='.lastTimestamp' | grep -i 'hpa\|scale\|replica'

# Prometheus Adapter 日志
kubectl logs -l app.kubernetes.io/name=prometheus-adapter -n monitoring --tail=50
```

---

## 端口速查表

| 服务 | 端口 | 访问方式 | 用途 |
|------|------|---------|------|
| Dynamo Frontend API | 8000 | `kubectl port-forward svc/vllm-v1-disagg-router-frontend 8000:8000 -n ${NAMESPACE}` | 推理 API（直接） |
| Ingress（HTTP） | 80 | `http://<节点IP>/v1/...` | 推理 API（通过 Ingress） |
| Prometheus | 9090 | `kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n monitoring` | 指标查询 & Targets |
| Grafana | 3000 | `kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring` | 监控看板 |
| Worker Metrics | 9090 | Pod 内部，Prometheus 自动抓取 | `dynamo_component_*` 指标 |

---
