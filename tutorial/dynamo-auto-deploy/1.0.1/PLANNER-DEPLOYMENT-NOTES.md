# Dynamo 1.0.1 Planner 部署后状态 & 注意事项

> 适用脚本：[`01-deploy-dynamo-1.0.1.sh`](01-deploy-dynamo-1.0.1.sh) `--planner`
> Manifest：[`manifests/dgd-vllm-disagg-planner.yaml`](manifests/dgd-vllm-disagg-planner.yaml)
> Namespace：`dynamo-system`（默认）

## 1. 部署完成后的预期状态

### 1.1 Pod 清单（4 + 2 平台）

```
NAMESPACE       NAME                                                              READY   STATUS
dynamo-system   dynamo-platform-dynamo-operator-controller-manager-...            1/1     Running
dynamo-system   dynamo-platform-nats-0                                            2/2     Running
dynamo-system   vllm-disagg-planner-frontend-...                                  1/1     Running
dynamo-system   vllm-disagg-planner-planner-...                                   1/1     Running
dynamo-system   vllm-disagg-planner-vllmdecodeworker-<digest>-...                 1/1     Running
dynamo-system   vllm-disagg-planner-vllmprefillworker-<digest>-...                1/1     Running
```

### 1.2 DGD 状态

```
NAME                  READY   BACKEND   AGE
vllm-disagg-planner   True              ~5m
```

`READY=True` 是 Operator 完成 reconcile + 所有子组件 ready 的标志。

### 1.3 Service / Ingress

```
vllm-disagg-planner-frontend                ClusterIP   :8000
vllm-disagg-planner-planner                 ClusterIP   :9090
vllm-disagg-planner-vllmdecodeworker-...    ClusterIP   :9090
vllm-disagg-planner-vllmprefillworker-...   ClusterIP   :9090
```

Ingress `dynamo-frontend-ingress` (class=nginx) → `vllm-disagg-planner-frontend:8000`，
节点入口 `http://<node-ip>/v1/{models,completions,chat/completions}`。

### 1.4 端到端冒烟测试

```bash
curl -s http://<node-ip>/v1/models | jq .
# {"object":"list","data":[{"id":"Qwen/Qwen3-0.6B","object":"model",...}]}

curl -s http://<node-ip>/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen3-0.6B","prompt":"Hello","max_tokens":20}'
# 返回正常 completion，延迟 ~200ms
```

### 1.5 GPU 占用

部署完成后会占用 **2 张 GPU**（默认 `prefill_replicas=1` + `decode_replicas=1`，每 worker 1 GPU）。
RTX 3090 24GB 上 Qwen3-0.6B 模型 + KV cache 每张约 22GB。

### 1.6 Planner 控制环

每 60 s（`throughput_adjustment_interval`）执行一轮决策，日志样例：

```
INFO disagg_planner._throughput_loop: New throughput adjustment interval started!
INFO planner_core.observe_traffic_stats: Observed num_req: X.XX isl: X.XX osl: X.XX
INFO prefill_planner._compute_replica_requirements: Prefill calculation: ... = N(num_p)
INFO decode_planner._compute_replica_requirements: Decode calculation: ... = N(num_d)
INFO kubernetes_connector.set_component_replicas: prefill component VllmPrefillWorker already at desired replica count N, skipping
```

通过 PATCH `dgd/<name>` 的 `spec.services.<comp>.replicas` 字段实现扩缩容。

## 2. Planner 关键参数（dgd-vllm-disagg-planner.yaml）

| 参数 | 值 | 作用 |
| ---- | --- | --- |
| `throughput_adjustment_interval` | 60 s | Planner 决策间隔 |
| `ttft` SLA | 500 ms | TTFT 目标，超出会扩容 prefill |
| `itl` SLA | 50 ms | Inter-token latency 目标，超出会扩容 decode |
| `max_gpu_budget` | 8 | 全集群最大允许使用 GPU 数 |
| `min_endpoint` | 1 | 每组件最少副本 |
| `connector` | kubernetes | 通过 K8s API 直接 PATCH DGD/DGDSA |

调优建议：
- 如需更快响应，降低 `throughput_adjustment_interval` 到 30 s（注意 Prometheus rate 窗口要相应调整）。
- 如希望更激进扩容，把 `ttft` / `itl` SLA 调到生产值；测试时可调到 100 ms / 10 ms 强制触发。
- `max_gpu_budget` 必须 ≤ 节点可分配 GPU 数。

## 3. 必须的依赖（Prometheus）

Planner 用 Prometheus 计算 5 个 frontend 指标的均值：
`dynamo_frontend_time_to_first_token_seconds`、`..._inter_token_latency_seconds`、`..._request_duration_seconds`、`..._input_sequence_tokens`、`..._output_sequence_tokens`。

部署 Prometheus 的方法：
```bash
bash tutorial/dynamo-auto-deploy/k8s/deploy-Prometheus-Grafana.sh
```

注意事项：
1. **必须 helm upgrade dynamo-platform 一次**（脚本会自动做）：dynamo-operator 的 helm 模板会在 PodMonitor CRD 存在时才渲染 PodMonitor 资源；如果先装 Dynamo 再装 Prometheus，需 `helm upgrade dynamo-platform <chart> -n dynamo-system --reuse-values` 触发渲染。
2. PodMonitor 名字：`dynamo-frontend / dynamo-planner / dynamo-worker / dynamo-router`。
3. 期望 Prometheus targets 状态：`UP`，pool 名 `podMonitor/dynamo-system/dynamo-{frontend,planner,worker}/0`。
4. NIXL 端口（dynamo-worker/1）若未启用 disagg-NIXL transfer 会显示 `down`，**这是正常的**。
5. 缺少 Prometheus 时 Planner 会持续打 `WARN ... No prometheus metric data available, use 0 instead`，不会扩容但也不会崩溃。

## 4. 部署脚本中已修复的坑

| 问题 | 现象 | 修复 |
| ---- | --- | --- |
| `sudo crictl info` 阻塞 | 预飞挂起等待密码 | 改为读 `/etc/containerd/conf.d/99-nvidia.toml` |
| Worker 等待循环死锁 | 用 0.7.x 标签 `dynamo.nvidia.com/component=worker` 永远 0 | 改为 1.0.1 标签 `nvidia.com/dynamo-component-type=worker` |
| `[[: 0 0: syntax error` | `grep -c \| echo "0"` 双行输出 | 改为 `awk '$3=="Running"' \| wc -l` |
| Ingress 404 | `nginx.ingress.kubernetes.io/rewrite-target: /` 把 `/v1/*` 重写成 `/` | 删除该 annotation |
| 三种模式 svc 名不同 | router/planner/mocker frontend svc 名不一样 | 模板变量 `${FRONTEND_SVC}` |
| 旧 ns 无法删除 | 残留 apiservice `v1beta1.metrics.k8s.io` 阻塞 finalizer | `kubectl delete apiservice v1beta1.metrics.k8s.io` 然后清 finalizer |

## 5. 故障排查速查

```bash
# DGD 状态
kubectl get dgd -n dynamo-system

# Operator 日志
kubectl logs -n dynamo-system deploy/dynamo-platform-dynamo-operator-controller-manager --tail=80

# Planner 日志（关注 _throughput_loop / set_component_replicas）
kubectl logs -n dynamo-system -l nvidia.com/dynamo-component-type=planner --tail=100

# Worker 日志（vLLM 启动 / 模型加载）
kubectl logs -n dynamo-system -l nvidia.com/dynamo-component-type=worker --tail=100

# Prometheus targets
kubectl exec -n monitoring prometheus-prometheus-kube-prometheus-prometheus-0 -c prometheus -- \
  wget -qO- http://localhost:9090/api/v1/targets | grep -i dynamo

# 强制触发 PodMonitor 重建
helm upgrade dynamo-platform ~/dynamo-charts-1.0.1/dynamo-platform-1.0.1.tgz \
  -n dynamo-system --reuse-values
```
