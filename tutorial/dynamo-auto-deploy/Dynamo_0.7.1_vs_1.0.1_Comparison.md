# Dynamo 0.7.1 vs 1.0.1 — 部署对比

本文档总结从 `tutorial/dynamo-auto-deploy/0.7.1/` 升级到
`tutorial/dynamo-auto-deploy/1.0.1/` 的所有结构性变化，方便理解为什么
新版本可以**清理旧的**遗留资源、并在最少的 Helm Release 上同时支持
**Router / Planner / Mocker** 三种部署形态。

> 参考: 本仓库 `1.0.1/manifests/`、官方源码 tag **v1.0.1** at
> `examples/backends/{vllm,mocker}/deploy/`、`deploy/observability/k8s/`、
> `deploy/operator/api/v1alpha1/`。

---

## 1. 平台层 (Helm Charts)

| 维度                  | 0.7.1                                                     | 1.0.1                                                                    |
| --------------------- | --------------------------------------------------------- | ------------------------------------------------------------------------ |
| Helm Releases         | `dynamo-crds` + `dynamo-platform`                          | **仅 `dynamo-platform`** (CRDs 已并入 operator subchart)                |
| etcd                  | **必须**部署 (服务发现/租约)                              | **禁用** — 改用 K8s 原生 Discovery (CR + Endpoints)                      |
| NATS                  | 启用 (Event Plane)                                         | 启用 (subchart `nats` 1.3.2)                                             |
| Kai-Scheduler / Grove | 不存在                                                     | subchart 存在但默认 **禁用** (我们 values 显式 `enabled: false`)         |
| Webhook               | 可选                                                       | **强制**, 由 built-in cert-controller 自动管理 TLS                       |
| Operator 镜像         | `dynamo-api-store`, `dynamo-operator`, … 多个              | 单一 `nvcr.io/nvidia/ai-dynamo/kubernetes-operator`                       |
| 安装命令              | 两次 `helm install`                                       | 一次 `helm install dynamo-platform …`                                    |

**清理影响**: 旧的 `dynamo-crds` Helm release 必须手动 uninstall (见
[cleanup-old.sh](1.0.1/cleanup-old.sh))。

---

## 2. CRD 变化

| CRD                                       | 0.7.1 | 1.0.1 | 用途                                                |
| ----------------------------------------- | :---: | :---: | --------------------------------------------------- |
| `DynamoGraphDeployment` (DGD)             |  ✅   |  ✅   | 主部署 CR (格式有变化, 见 §3)                       |
| `DynamoGraphDeploymentScalingAdapter` (DGDSA) |  ❌   |  ✅   | **新增** — 暴露 `/scale` subresource，HPA / RL 接入 |
| `DynamoGraphDeploymentRollout` (DGDR)     |  ❌   |  ✅   | **新增** — 灰度/蓝绿发布                            |
| `DynamoCheckpoint`                        |  ❌   |  ✅   | **新增** — KV cache snapshot (实验性)               |
| `DynamoComponentDeployment`               |  ✅   |  ✅   | 单 service Deploy (低层, 通常不直接写)              |
| `DynamoWorkerMetadata`                    |  ❌   |  ✅   | **新增** — Worker → Operator 上行元数据             |

---

## 3. DGD YAML 格式变化 (重要)

### 3.1 字段差异

| 字段                                      | 0.7.1                                              | 1.0.1                                                          |
| ----------------------------------------- | -------------------------------------------------- | -------------------------------------------------------------- |
| `spec.dynamoNamespace`                    | 必填                                               | **删除** (Operator 直接用 K8s namespace)                       |
| GPU 资源声明                              | `extraPodSpec.mainContainer.resources.limits.nvidia.com/gpu` | **`spec.services.<Name>.resources.limits.gpu: "1"`** (顶层)   |
| `envFromSecret`                           | 在 `extraPodSpec`                                  | **在 service 顶层**                                            |
| `command` / `workingDir`                  | 可选                                               | **建议显式声明** (`python3 -m dynamo.vllm`)                    |
| Router 启用方式                           | DGD 字段 `dynamoNamespace` + DGD-level routing     | Frontend env **`DYN_ROUTER_MODE=kv`**                          |
| Disagg 模式选择                           | 通过 ServiceConfig.yaml                            | CLI 参数 **`--disaggregation-mode prefill\|decode`**           |
| KV 传输配置                               | `--enable-kv-cache-events --xpyd-host …`           | **`--kv-transfer-config '{"kv_connector":"NixlConnector",...}'`** (仅 Prefill) |
| KV Events 配置                            | (无独立字段)                                       | **`--kv-events-config '{"publisher":"zmq","topic":"kv-events","endpoint":"tcp://*:20080","enable_kv_cache_events":true}'`** (仅 Prefill) |

### 3.2 镜像

| 角色             | 0.7.1                                            | 1.0.1                                                  |
| ---------------- | ------------------------------------------------ | ------------------------------------------------------ |
| vLLM Worker      | `nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.1`    | `nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.0.1`          |
| Mocker (新)      | —                                                | `nvcr.io/nvidia/ai-dynamo/mocker-runtime:1.0.1`        |
| Operator         | 多镜像                                           | `nvcr.io/nvidia/ai-dynamo/kubernetes-operator:1.0.1`   |

> 注: 部分官方 `examples/backends/*/deploy/*.yaml` 文件中 tag 写的是 `1.0.0`。
> 我们的 manifests 用模板变量 `${RELEASE_VERSION}=1.0.1` 与 helm chart 版本对齐。
> 若 NGC 上 1.0.1 镜像不存在则脚本会 ImagePull 失败 — 此时回退 `RELEASE_VERSION=1.0.0`。

---

## 4. 扩缩容机制对比

| 方式                              | 0.7.1                                                 | 1.0.1                                                                            |
| --------------------------------- | ----------------------------------------------------- | -------------------------------------------------------------------------------- |
| **HPA**                           | `kubectl autoscale deployment …` 直接指向 K8s Deploy  | HPA 指向 **DGDSA**, DGDSA 持有 `scale` subresource                              |
| **Planner (内置自动扩缩容)**      | 不存在                                                 | **新增** `componentType: planner` — Operator 注入 ServiceAccount + RBAC 后, Planner 直接 PATCH DGDSA |
| **RL Scaling 控制器**             | 通过 `kubectl scale deploy` 实现 (粗粒度)             | PATCH `dgdsa/<name> {"spec":{"replicas":N}}` (细粒度, 与 HPA 不冲突)            |

---

## 5. 监控集成变化

| 组件                                  | 0.7.1                                               | 1.0.1                                                                       |
| ------------------------------------- | --------------------------------------------------- | --------------------------------------------------------------------------- |
| PodMonitor 自动创建                   | 手写 YAML                                            | Operator 检测 `monitoring.coreos.com` CRD 后**自动**创建 (`dynamo.metrics.podMonitors.enabled: null`/`true`) |
| Prometheus 端点注入                   | 手动 env                                            | Operator 把 `dynamo.metrics.prometheusEndpoint` 注入所有 worker 容器        |
| Grafana Dashboards                    | 自维护一份 `dynamo-dashboard.json`                  | **复用官方 4 个 ConfigMap**: disagg / planner / dynamo / operator           |
| 安装脚本                              | `tutorial/dynamo-auto-deploy/k8s/deploy-Prometheus-Grafana.sh` (自维护) | **复用** `dynamo/deploy/observability/k8s/setup-monitoring.sh` (官方)        |

---

## 6. 部署形态 (我们 1.0.1 同时支持)

`bash 01-deploy-dynamo-1.0.1.sh [--router|--planner|--mocker] [--skip-monitoring]`

| 模式      | 部署的 DGD                       | GPU? | 适用场景                                |
| --------- | -------------------------------- | :--: | --------------------------------------- |
| `router`  | `dgd-vllm-disagg-router.yaml`    | ✅   | 默认: 真实 vLLM + KV Router + DGDSA     |
| `planner` | `dgd-vllm-disagg-planner.yaml`   | ✅   | 真实 vLLM + Planner 自动扩缩容          |
| `mocker`  | `dgd-mocker-disagg.yaml`         | ❌   | 无 GPU, 验证 Router/Planner 行为        |

---

## 7. 文件目录结构对比

```
0.7.1/                              1.0.1/
├── deploy-dynamo-0.7.1.sh          ├── 00-upgrade-cuda.sh        (NEW: 自动升级 driver+CUDA)
└── manifests/                      ├── 01-deploy-dynamo-1.0.1.sh
    ├── dgd-vllm-disagg-router.yaml ├── cleanup-old.sh            (NEW)
    ├── dynamo-platform-values.yaml └── manifests/
    ├── hpa-decode-worker.yaml          ├── dynamo-platform-values.yaml
    ├── hpa-prefill-worker.yaml         ├── dgd-vllm-disagg-router.yaml   (重写)
    ├── hpa-frontend.yaml               ├── dgd-vllm-disagg-planner.yaml  (NEW)
    ├── ingress-frontend.yaml           ├── dgd-mocker-disagg.yaml        (NEW)
    ├── ingress-nginx-values.yaml       ├── dgdsa-decode.yaml             (NEW)
    ├── prometheus-adapter-values.yaml  ├── dgdsa-prefill.yaml            (NEW)
    └── runtime-class-nvidia.yaml       ├── ingress-frontend.yaml
                                        ├── ingress-nginx-values.yaml
                                        └── (HPA / prometheus-adapter / runtime-class 不再必需)
```

---

## 8. 升级路径

1. 在测试环境运行 `bash cleanup-old.sh` (默认 dry-run) 检查待清理资源
2. `bash cleanup-old.sh --apply` 卸载旧 0.7.x release / CRD / namespace
3. `sudo bash 00-upgrade-cuda.sh` (二阶段, 中间需要 reboot) — 升级 driver 到 ≥ 565
4. 重新登录后: `sudo bash 00-upgrade-cuda.sh --post-reboot`
5. `export HF_TOKEN=...; export NGC_API_KEY=...`
6. `bash 01-deploy-dynamo-1.0.1.sh --router` (或 `--planner` / `--mocker`)
7. 进入 `test-dynamo/1.0.1/` 跑各类测试 (见 [COMPLETE-GUIDE.md](test-dynamo/1.0.1/COMPLETE-GUIDE.md))
