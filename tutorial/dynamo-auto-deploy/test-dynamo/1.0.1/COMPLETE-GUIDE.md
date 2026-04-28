# Dynamo 1.0.1 测试完整指南

测试脚本位置: `tutorial/dynamo-auto-deploy/test-dynamo/1.0.1/`

| 脚本                              | 用途                                        | 是否需要 GPU |
| --------------------------------- | ------------------------------------------- | :---: |
| [`test-mocker.sh`](test-mocker.sh)                       | Mocker (无 GPU) 验证控制平面 + Frontend     |   ❌  |
| [`test-planner-feasibility.sh`](test-planner-feasibility.sh) | 验证 Planner DGD 8 项可行性指标             |   ✅  |
| [`test-real-gpu-scaling.sh`](test-real-gpu-scaling.sh)        | 真实 GPU 端到端扩缩容测试 (router / planner) |   ✅  |

> **强制要求**: 所有测试都将关键指标暴露到 Prometheus, 并提示 Grafana 端口转发 —
> 测试结束前**不要关闭脚本**, 在浏览器打开 http://localhost:3000 查看仪表盘后再 Ctrl+C 退出。

---

## 0. 前置条件

```bash
# 1. 部署 Dynamo 1.0.1 (按需选择一种模式)
cd tutorial/dynamo-auto-deploy/1.0.1
# 先通过安全渠道获取并设置以下变量
export HF_TOKEN=<从密钥管理工具获取>
export NGC_API_KEY=<从密钥管理工具获取>

bash 01-deploy-dynamo-1.0.1.sh --router    # 真实 vLLM + KV Router (默认)
# 或
bash 01-deploy-dynamo-1.0.1.sh --planner   # Planner 自动扩缩容
# 或
bash 01-deploy-dynamo-1.0.1.sh --mocker    # 无 GPU mocker

# 2. 监控栈会被自动部署 (除非加了 --skip-monitoring)
#    - kube-prometheus-stack in ns/monitoring
#    - 4 个 Grafana ConfigMap dashboard

# 3. 验证 4 个 dashboard ConfigMap 已就绪
kubectl get cm -n monitoring | grep grafana-
# 期望:
#   grafana-disagg-dashboard
#   grafana-planner-dashboard
#   grafana-dynamo-dashboard
#   grafana-operator-dashboard
```

---

## 1. Mocker 测试 (无 GPU, 5 分钟)

适合: 在没有 GPU 的开发机 / CI 环境验证控制平面、Router、API contract.

```bash
# 部署 mocker DGD
cd ../1.0.1
bash 01-deploy-dynamo-1.0.1.sh --mocker

# 跑测试
cd ../test-dynamo/1.0.1
bash test-mocker.sh
```

测试做了什么:
1. 检查所有 mocker pod Running
2. 探测 Frontend endpoint (Ingress → port-forward fallback)
3. `GET /v1/models` 验证模型注册成功
4. `POST /v1/completions` 冒烟 (mocker 返回模拟 token)
5. 启动异步并发负载 (默认 10 并发 × 100 请求, 用 `CONCURRENCY` / `TOTAL_REQUESTS` 调整)
6. 采样 Prometheus 关键指标:
   - `dynamo_frontend_requests_total`
   - `dynamo_worker_active_requests`
   - `dynamo_worker_requests_total` per-worker rate
7. 启动 Grafana port-forward, 提示用户去看 dashboard

**Grafana 验证点**:
- **Dynamo Disaggregation**: requests / decode tokens / prefill TTFT 都应有数据
- **Dynamo Planner**: mocker 模式下 Planner 不在场, 应为空
- **Dynamo Operator**: DGD count = 1

---

## 2. Planner 可行性测试 (需要 GPU, 10 分钟)

适合: 验证 Planner 这个 1.0.1 新组件能否在你的 K8s 环境中正常工作.

```bash
# 部署 planner DGD
cd ../1.0.1
bash 01-deploy-dynamo-1.0.1.sh --planner

# 跑测试
cd ../test-dynamo/1.0.1
bash test-planner-feasibility.sh
```

8 项检查:

| #  | 检查项                                           | 失败原因排查                                 |
| -- | ------------------------------------------------ | -------------------------------------------- |
| 1  | Planner Pod 存在且 Running                       | DGD `componentType: planner` 是否声明        |
| 2  | profile data ConfigMap 已挂载                    | `volumeMounts` / `configMap` 名字            |
| 3  | ServiceAccount + (Cluster)RoleBinding            | Operator 是否安装完整 (检查 operator 日志)   |
| 4  | SA 有权 PATCH `dgdsa/scale`                       | 检查 `clusterrole/dynamo-planner-role`       |
| 5  | Planner 日志中出现 scaling 决策                   | 等 1-2 个 `throughput_adjustment_interval`   |
| 6  | `PROMETHEUS_ENDPOINT` 已注入                      | `dynamo-platform-values.yaml` 中 `dynamo.metrics.prometheusEndpoint` |
| 7  | Prometheus 中存在 `dynamo_planner_*` metrics      | PodMonitor 自动创建是否成功 (`kubectl get podmonitor -A`) |
| 8  | `grafana-planner-dashboard` ConfigMap 已加载      | 重新跑 deploy 确保 dashboard ConfigMap 已应用 |

**Grafana 验证点 (Dashboard "Dynamo Planner")**:
- Replicas 时间线 (prefill / decode)
- Decision intervals
- Scaling actions count
- Throughput target vs actual

---

## 3. 真实 GPU 端到端扩缩容测试 (需要 ≥3 GPU 空闲, 15-25 分钟)

适合: 全链路验证 RL Scaling Controller (router 模式) 或 Planner (planner 模式) 触发的真实扩容.

```bash
# Router 模式 (默认): 模拟 RL 控制器手动 PATCH dgdsa/scale
bash test-real-gpu-scaling.sh --mode router --target-replicas 3

# Planner 模式: 等 Planner 自动决策
bash test-real-gpu-scaling.sh --mode planner --concurrency 60 --wave-duration 240
```

测试 6 个阶段:

| Stage | 操作                                                      |
| :---: | --------------------------------------------------------- |
| 0     | 检查 GPU / DGD / DGDSA / Prometheus 就绪                  |
| 1     | 预热 10 个请求, 让 Prometheus 开始采样                    |
| 2     | Wave 1: 高并发持续 `WAVE_DURATION` (默认 180s)            |
| 3     | 触发或等待扩容 (router=PATCH; planner=等)                 |
| 4     | 等新 Decode Pod Running (GPU init, 最多 8min)             |
| 5     | Wave 2: 60s 验证负载, 确认新 pod 接收请求                 |
| 6     | 查询 Prometheus per-pod request rate 显示分布             |

**Grafana 验证点 (Dashboard "Dynamo Disaggregation")**:
- Decode replicas 数量从初始值 → 目标值 (有阶跃)
- Per-pod request rate: 多个 pod 都有非零速率 (说明 router 真的在分流)
- KV cache hit rate / TTFT / ITL 时间序列
- Planner 模式还应观察 "Dynamo Planner" dashboard 上的 decision events

---

## 4. 常用 env 覆盖

所有脚本通过 `lib/common.sh` 读取以下环境变量 (有合理默认值):

| 变量                  | 默认值                                                  | 说明                                |
| --------------------- | ------------------------------------------------------- | ----------------------------------- |
| `NAMESPACE`           | `dynamo-system`                            | Dynamo 命名空间                     |
| `MONITORING_NS`       | `monitoring`                                            | kube-prometheus-stack 命名空间      |
| `MODEL_NAME`          | `Qwen/Qwen3-0.6B`                                       | HuggingFace 模型 ID                 |
| `DGD_NAME`            | `vllm-v1-disagg-router`                                 | router 模式 DGD                     |
| `DGD_PLANNER_NAME`    | `vllm-disagg-planner`                                   | planner 模式 DGD                    |
| `DGD_MOCKER_NAME`     | `mocker-disagg`                                         | mocker 模式 DGD                     |
| `CONCURRENCY`         | `10`                                                    | 异步负载并发                        |
| `TOTAL_REQUESTS`      | `100`                                                   | 总请求数                            |
| `MAX_TOKENS`          | `100`                                                   | 每请求 max_tokens                   |
| `WAVE_DURATION`       | `180`                                                   | Wave 1 持续秒数                     |
| `PROM_ENDPOINT`       | `http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090` | Prometheus URL (cluster-internal)   |
| `GRAFANA_SVC`         | `kube-prometheus-stack-grafana`                         | Grafana svc 名字                    |

例:
```bash
NAMESPACE=my-dynamo MODEL_NAME=meta-llama/Llama-3.2-1B \
  CONCURRENCY=40 bash test-real-gpu-scaling.sh
```

---

## 5. 故障排查速查

| 现象                                | 排查                                                       |
| ----------------------------------- | ---------------------------------------------------------- |
| `port-forward` 失败                 | `pkill -f 'kubectl port-forward'` 后重试                   |
| Grafana 中无 `dynamo_*` metric      | `kubectl get podmonitor -A`; 看 Prometheus targets 是否 up  |
| Dashboard 不出现                    | `kubectl describe cm grafana-disagg-dashboard -n monitoring`; 检查 `grafana_dashboard: "1"` label |
| Planner 无调度日志                  | `kubectl logs <planner-pod> -n <ns>`; 增大 `throughput_adjustment_interval` 等下一周期 |
| `dgdsa/scale` PATCH 403             | `kubectl get clusterrole dynamo-planner-role -o yaml`; 重装 dynamo-platform |
| Mocker pod CrashLoopBackOff         | 检查 mocker 镜像 tag (1.0.1 vs 1.0.0); `kubectl describe pod` |
| 扩容触发但新 pod Pending            | GPU 不足; `kubectl describe pod` 看 `Insufficient nvidia.com/gpu` |
| 新 pod Running 但无流量             | 检查 frontend `DYN_ROUTER_MODE=kv` 是否生效; KV events ZMQ 连通性 |

---

## 6. 与 0.7.1 测试套件的差异

| 项目                          | 0.7.1                                       | 1.0.1                                                    |
| ----------------------------- | ------------------------------------------- | -------------------------------------------------------- |
| 扩容触发方式                  | `kubectl scale deploy` (HPA)                | `kubectl patch dgdsa/<x> --type=merge -p {replicas:N}`    |
| Planner 测试                  | 不存在                                       | **新增** `test-planner-feasibility.sh`                   |
| Mocker 测试                   | 不存在                                       | **新增** `test-mocker.sh` (无 GPU)                       |
| Grafana dashboard             | 自维护一份                                  | 复用官方 4 个                                            |
| Per-pod metric query          | `dynamo_handle_*`                           | `dynamo_worker_requests_total` + `dynamo_planner_*`      |
