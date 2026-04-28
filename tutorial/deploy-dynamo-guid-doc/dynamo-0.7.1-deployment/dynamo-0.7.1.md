# Dynamo 0.7.1 Disaggregated + Router 部署指南（单节点 K8s）

> **目标**：在单节点 Kubernetes 上，从零部署 Dynamo 0.7.1 推理服务（Disaggregated + KV Router 模式），配置 HPA Auto Scaling，并接入 Prometheus + Grafana 监控。
>
> **模式说明**：Disaggregated + Router 将 Prefill（首 token 生成）与 Decode（后续 token 流）拆分到不同 Pod，Frontend 内置 KV Router 基于缓存命中率智能路由，适合追求高吞吐的生产场景。

---

## 目录

- [前置假设](#前置假设)
- [Step 0：设置环境变量](#step-0设置环境变量)
- [Step 1：创建 namespace 和 Secrets](#step-1创建-namespace-和-secrets)
- [Step 2：安装 Dynamo CRDs](#step-2安装-dynamo-crds)
- [Step 3：安装 Dynamo Platform](#step-3安装-dynamo-platform)
- [Step 4：创建 DGD Manifest（Disaggregated + Router）](#step-4创建-dgd-manifestdisaggregated--router)
- [Step 5：部署推理服务](#step-5部署推理服务)
- [Step 6：验证推理 API](#step-6验证推理-api)
- [Step 7：验证 Disaggregated 路由行为（可选）](#step-7验证-disaggregated-路由行为可选)
- [Step 8：配置 HPA Auto Scaling（可选）](#step-8配置-hpa-auto-scaling可选)
- [Step 9：全链路监控验证（可选）](#step-9全链路监控验证可选)
- [开发迭代工作流](#开发迭代工作流)
- [故障排查速查](#故障排查速查)

---

## 前置假设

- K8s 单节点已完成基础配置：control-plane 污点已移除，默认 StorageClass 已配置，GPU 已注册（`nvidia.com/gpu` 可调度）
- Prometheus & Grafana 已运行在 `monitoring` namespace（`kube-prometheus-stack`）
- `kubectl`、`helm` v3.8+ 可用
- NGC API Key 和 HuggingFace Token 已准备好

---

## Step 0：设置环境变量

> **目的**：将所有可变参数集中声明为 Shell 变量，后续所有命令直接引用，避免在多步骤操作中反复硬编码同一值，降低因笔误导致的资源错建或版本不一致风险。

```bash
# ============================================================
# 根据实际情况修改以下变量，后续所有步骤均依赖这些变量
# ============================================================
export NAMESPACE=dynamo-system   # 全新的 K8s namespace 名称
export RELEASE_VERSION=0.7.1                 # Dynamo 版本
export MODEL_NAME="Qwen/Qwen3-0.6B"          # 要运行的模型
# export HF_TOKEN=  # 通过安全渠道获取后设置此变量
# export NGC_API_KEY=  # 通过安全渠道获取后设置此变量
# ============================================================
```

**验证：**

```bash
echo "NAMESPACE=${NAMESPACE}  VERSION=${RELEASE_VERSION}  MODEL=${MODEL_NAME}"
```

> ✅ 输出与设置值一致即可继续。
![alt text](image.png)
---

## Step 1：创建 namespace 和 Secrets

> **目的**：建立独立的 K8s 资源隔离边界，并在该边界内预置两类凭证——NGC 镜像拉取凭证（`nvcr-imagepullsecret`）确保 Pod 能从私有 Registry 拉取 Dynamo 镜像，HuggingFace Token（`hf-token-secret`）在 Worker 启动时自动注入，用于从 HF Hub 下载模型权重。

```bash
kubectl create namespace ${NAMESPACE}

# NGC 镜像拉取 Secret（必须，NGC 镜像需要认证）
kubectl create secret docker-registry nvcr-imagepullsecret \
  --docker-server=nvcr.io \
  --docker-username='$oauthtoken' \
  --docker-password="${NGC_API_KEY}" \
  --namespace=${NAMESPACE}

# HuggingFace Token Secret（从 HF Hub 拉模型时需要）
kubectl create secret generic hf-token-secret \
  --from-literal=HF_TOKEN="${HF_TOKEN}" \
  --namespace=${NAMESPACE}
```

**验证：**

```bash
kubectl get namespace ${NAMESPACE}
kubectl get secret -n ${NAMESPACE}
```

> ✅ 预期输出：
> ```
> NAME                  STATUS   AGE
> dynamo-system         Active   10s
>
> NAME                    TYPE                             DATA   AGE
> nvcr-imagepullsecret    kubernetes.io/dockerconfigjson   1      8s
> hf-token-secret         Opaque                           1      5s
> ```
> 两个 Secret 均存在且类型正确。
![alt text](image-1.png)
---

## Step 2：安装 Dynamo CRDs

> **目的**：向集群注册 Dynamo 的自定义资源类型（`DynamoGraphDeployment`、`DynamoGraphDeploymentRequest`），使 `kubectl` 和 API Server 能够识别并处理这些对象。若跳过此步，Step 5 的 `kubectl apply` 将报错 `no kind DynamoGraphDeployment is registered`。

> ⚠️ **集群级共享资源**：CRD 全集群唯一，多人共用同一集群时由管理员统一执行一次即可，后续每位用户跳过此步。下方命令已加检测，CRD 已存在时自动跳过，不会产生冲突。

```bash
mkdir -p ~/dynamo-charts && cd ~/dynamo-charts

# CRD 已存在则跳过，避免多人部署时冲突
if kubectl get crd dynamographdeployments.nvidia.com &>/dev/null; then
  echo "Dynamo CRDs already installed, skipping."
else
  helm fetch https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-crds-${RELEASE_VERSION}.tgz \
    --username='$oauthtoken' \
    --password="${NGC_API_KEY}"

  helm install dynamo-crds dynamo-crds-${RELEASE_VERSION}.tgz \
    --namespace default \
    --wait
fi
```

**验证：**

```bash
kubectl get crd | grep dynamo
```

> ✅ 预期输出：
> ```
> NAME                                              CREATED AT
> dynamographdeploymentrequests.nvidia.com          2026-03-20T10:00:00Z
> dynamographdeployments.nvidia.com                 2026-03-20T10:00:00Z
> ```
> 必须看到这两个 CRD，否则后续 `kubectl apply` DGD manifest 会报错 `no kind DynamoGraphDeployment is registered`。
![alt text](image-2.png)
---

## Step 3：安装 Dynamo Platform

> **目的**：部署 Dynamo 的三个核心平台组件——**Dynamo Operator**（监听 DGD 对象并自动创建/管理推理 Pod）、**etcd**（服务发现键值存储，Frontend 通过它定位 Worker 地址）、**NATS**（组件间异步消息传递总线）。这三个组件是推理服务运行的必要基础设施，必须在部署推理服务前就绪。

### 概念解释

> **"Platform" 是谁的概念？**  
> Platform 是 **Dynamo 自己定义的产品名**，不是 K8s 或 Helm 的通用术语。NVIDIA/Dynamo 团队把 Operator + etcd + NATS 这三个基础设施组件打包成一个 Helm chart，命名为 `dynamo-platform`。对 Helm 而言它只是一个普通 chart 包；对 K8s 而言它安装后只是普通的 Pod/Service/StatefulSet 等资源。"Platform" 只是 Dynamo 项目的叫法，表示"所有推理服务共用的底座"。

### 核心概念说明

#### 1. K8s 自带的 etcd vs Dynamo 安装的 etcd — 为什么有两个？

K8s 本身自带一个 etcd，但那个是 K8s 系统内部专用的，外部程序无法直接写入。

| | K8s 自带的 etcd | Dynamo 安装的 etcd |
|--|--|--|
| 用途 | 存储 K8s 自身的状态（Pod、Service、Deployment 等） | 存储 Dynamo 推理服务的**运行时服务发现数据** |
| 谁写入 | 只有 K8s API Server 能写 | Dynamo 的 Frontend 和 Worker 直接读写 |
| 存什么 | Pod IP、配置、密钥等 | "哪个 Worker Pod 地址是什么、当前 KV Cache 命中率是多少" |

> **类比**：K8s 的 etcd 是"楼管的花名册"，Dynamo 的 etcd 是"外卖小哥的实时位置调度板"——用途完全不同，必须分开。

#### 2. Dynamo Operator 是什么？

Operator 是 K8s 的"自动化运维机器人"模式。K8s 原生只认识 `Deployment`、`Service` 等内置对象，不认识 Dynamo 的 `DynamoGraphDeployment`（DGD）对象。Dynamo Operator 持续监听集群中的 DGD 事件，负责将 DGD 蓝图翻译成真实的 K8s 资源：

```
你（用户）
    │  kubectl apply -f vllm-disagg-router.yaml  （Step 5）
    ▼
K8s API Server
    │  "有人创建了一个 DynamoGraphDeployment 对象"
    ▼
Dynamo Operator（监听 DGD 事件的控制器，Step 3 安装，一直在后台运行）
    │
    ├──► 自动创建 Frontend Deployment
    ├──► 自动创建 VllmPrefillWorker Deployment
    ├──► 自动创建 VllmDecodeWorker Deployment
    ├──► 自动创建各组件的 Service
    └──► 自动创建 PodMonitor（供 Prometheus 采集指标）
```

> **类比**：你在网上下了一个"组装电脑"的订单（DGD），Operator 就是工厂流水线——它看到订单，自动把各部件分别安装好，你不需要手动一件件操作。

#### 3. DGD（DynamoGraphDeployment）是什么？

DGD 就是 Step 4 中 YAML 文件里 `kind: DynamoGraphDeployment` 这个对象。它是一张**高层声明蓝图**，描述"我想要什么样的推理服务"（需要哪些组件、用什么镜像、分配多少 GPU……），**本身不直接创建任何 Pod**，由 Dynamo Operator 读取蓝图后才真正动手创建 K8s 资源。

#### 4. NATS 是什么？

NATS 是一个**消息队列/消息总线**。在 Disaggregated 模式下，Frontend 不直接调用 Worker，而是通过 NATS 异步分发任务：

```
Frontend 收到推理请求
    │  发布消息："有一个 prefill 任务"
    ▼
NATS（消息中间件）
    ├──► PrefillWorker 订阅到消息 → 执行 Prefill → 发布结果
    └──► DecodeWorker 订阅到消息 → 执行 Decode → 返回 token 流
```

> **类比**：NATS 是"对讲机频道"，各组件都在同一频道上广播和接收消息，而不是点对点打电话。

#### 5. 完整调用关系

```
┌──────────────────────────────────────────────────────┐
│  Step 5: kubectl apply -f vllm-disagg-router.yaml    │
└────────────────────────┬─────────────────────────────┘
                         │
                         ▼
             K8s API Server（存入 K8s 自带的 etcd）
                         │ 通知事件
                         ▼
              Dynamo Operator Pod（Step 3 安装）
                         │ 自动创建↓
          ┌──────────────┼───────────────┐
          ▼              ▼               ▼
     Frontend Pod   PrefillWorker    DecodeWorker
     (HTTP 入口)     Pod (GPU)        Pod (GPU)
          │              │               │
          │    启动时注册自己的地址到 Dynamo etcd
          │              │               │
          └──────────────┴───────────────┘
                    ▼（服务发现）
              Dynamo etcd（Step 3 安装）
                    
          推理请求通过 NATS 异步分发
                    ▼
              NATS（Step 3 安装）
          ├──► PrefillWorker（首 token 计算）
          └──► DecodeWorker（后续 token 流）
```

#### 6. 为什么装在你自己的 namespace 里？

etcd 和 NATS 是**你的推理服务专属基础设施**。其他用户在自己的 namespace 里有自己的 etcd/NATS，互不干扰，隔离清晰。Operator 也装在你的 namespace，只管理你的 DGD。

---

```bash
cd ~/dynamo-charts

helm fetch https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-platform-${RELEASE_VERSION}.tgz \
  --username='$oauthtoken' \
  --password="${NGC_API_KEY}"

cat > /tmp/dynamo-platform-single-node.yaml << 'EOF'
dynamo-operator:
  dynamo:
    metrics:
      prometheusEndpoint: "http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090"
  imagePullSecrets:
    - name: nvcr-imagepullsecret
  controllerManager:
    kubeRbacProxy:
      image:
        repository: quay.io/brancz/kube-rbac-proxy
        tag: v0.15.0
etcd:
  replicaCount: 1
  podDisruptionBudget:
    enabled: false
nats:
  replicaCount: 1
  cluster:
    enabled: false
EOF

# ── 如果之前安装失败，先卸载再重装 ─────────────────────────────────────
# helm list -n ${NAMESPACE}                        # 确认 dynamo-platform 存在
# helm uninstall dynamo-platform -n ${NAMESPACE}   # 卸载旧版本
# kubectl get pods -n ${NAMESPACE}                 # 等待所有 Pod 消失后再执行 install
# ─────────────────────────────────────────────────────────────────────

helm install dynamo-platform ~/dynamo-charts/dynamo-platform-${RELEASE_VERSION}.tgz \
  --namespace ${NAMESPACE} \
  --values /tmp/dynamo-platform-single-node.yaml \
  --timeout 15m \
  --wait
```

**验证 Pod 状态：**

```bash
kubectl get pods -n ${NAMESPACE}
```

> ✅ 预期输出（**3 或 4 个平台 Pod 全部 Running**）：
> ```
> NAME                                                   READY   STATUS    RESTARTS   AGE
> dynamo-platform-dynamo-operator-controller-manager-*   2/2     Running   0          3m
> dynamo-platform-etcd-0                                 1/1     Running   0          3m
> dynamo-platform-nats-0                                 2/2     Running   0          3m
> dynamo-platform-nats-box-*                             1/1     Running   0          3m   # 可能不出现，见下方说明
> ```
>
> | Pod | READY | 角色 | 是否必须 |
> |-----|-------|------|--------|
> | `dynamo-platform-dynamo-operator-controller-manager-*` | 2/2 | Operator 主进程 + kube-rbac-proxy sidecar | ✅ 必须 |
> | `dynamo-platform-etcd-0` | 1/1 | 服务发现键值存储（StatefulSet，单副本） | ✅ 必须 |
> | `dynamo-platform-nats-0` | 2/2 | 消息中间件 + config-reloader sidecar（StatefulSet） | ✅ 必须 |
> | `dynamo-platform-nats-box-*` | 1/1 | NATS 管理工具箱（仅用于调试，可选） | ❌ 可选 |
>
> > **nats-box 缺失属正常现象**：`nats-box` 是 NATS 的可选调试容器，新版本 NATS Helm chart（v1.2+）默认不再部署。3 个 Pod 全部 Running 即可继续。

![alt text](image-3.png)
**追加验证（平台健康度）：**

```bash
# etcd 健康检查
kubectl exec -n ${NAMESPACE} dynamo-platform-etcd-0 -- \
  etcdctl --endpoints=http://localhost:2379 endpoint health
# 期望：http://localhost:2379 is healthy: successfully committed proposal: took = ...ms

# Operator 无报错
kubectl logs -l app.kubernetes.io/name=dynamo-operator \
  -n ${NAMESPACE} --tail=20 | grep -i error || echo "No errors found"
```
![alt text](image-4.png)
---

## Step 4：创建 DGD Manifest（Disaggregated + Router）

> **目的**：以声明式配置描述整套推理服务的拓扑结构——Frontend 作为 HTTP 入口并内置 KV Router，VllmPrefillWorker 专用于首 token 生成（Prefill 阶段），VllmDecodeWorker 专用于后续 token 流式输出（Decode 阶段）。Manifest 本身不触发任何部署，仅生成配置文件，供 Step 5 提交到集群。

> **单节点资源提示**：标准配置 Prefill/Decode 各 2 副本，共需 **4 张 GPU**。若 GPU 不足，将 `replicas` 改为 `1`（各 1 副本，共 2 张 GPU）。

```bash
cat > /tmp/vllm-disagg-router.yaml << EOF
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: vllm-v1-disagg-router
  namespace: ${NAMESPACE}
spec:
  services:
    Frontend:
      dynamoNamespace: vllm-v1-disagg-router
      componentType: frontend
      replicas: 1
      extraPodSpec:
        imagePullSecrets:
          - name: nvcr-imagepullsecret
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:${RELEASE_VERSION}
          imagePullPolicy: IfNotPresent
      envs:
        - name: DYN_ROUTER_MODE
          value: kv

    VllmDecodeWorker:
      dynamoNamespace: vllm-v1-disagg-router
      envFromSecret: hf-token-secret
      componentType: worker
      replicas: 1
      extraPodSpec:
        imagePullSecrets:
          - name: nvcr-imagepullsecret
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:${RELEASE_VERSION}
          imagePullPolicy: IfNotPresent
          workingDir: /workspace/examples/backends/vllm
          command: ["python3", "-m", "dynamo.vllm"]
          args:
            - --model
            - "${MODEL_NAME}"
            - --is-decode-worker
          resources:
            limits:
              nvidia.com/gpu: "1"

    VllmPrefillWorker:
      dynamoNamespace: vllm-v1-disagg-router
      envFromSecret: hf-token-secret
      componentType: worker
      replicas: 1
      extraPodSpec:
        imagePullSecrets:
          - name: nvcr-imagepullsecret
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:${RELEASE_VERSION}
          imagePullPolicy: IfNotPresent
          workingDir: /workspace/examples/backends/vllm
          command: ["python3", "-m", "dynamo.vllm"]
          args:
            - --model
            - "${MODEL_NAME}"
            - --is-prefill-worker
          resources:
            limits:
              nvidia.com/gpu: "1"
EOF
```

**验证 Manifest 内容：**

```bash
grep -E 'namespace:|image:|-- model|-- is-' /tmp/vllm-disagg-router.yaml
```

> ✅ 所有 `image:` 行应包含 `0.7.1`（非空字符串），`namespace:` 为你的 `${NAMESPACE}` 实际值，`--model` 为你的模型名。

![alt text](image-5.png)
---

## Step 5：部署推理服务

> **目的**：将 Step 4 生成的 DGD Manifest 提交到集群，触发 Dynamo Operator 的调协流程——Operator 会自动创建对应的 Deployment、Service、PodMonitor 等 K8s 资源，并持续监控 Pod 健康状态直至所有组件就绪。

```bash
kubectl apply -f /tmp/vllm-disagg-router.yaml
```

**监控部署进度（Ctrl+C 退出）：**

```bash
kubectl get dynamographdeployment -n ${NAMESPACE} -w
```

**验证所有 Pod 状态：**

```bash
kubectl get pods -n ${NAMESPACE}
```

> ✅ 预期输出（副本数为 1 时，共 **6/7 个 Pod 全部 Running**）：
>
> ```
> NAME                                                      READY   STATUS    RESTARTS   AGE
> # ── 平台基础（Step 3 部署，始终存在）─────────────────────────────
> dynamo-operator-controller-manager-<hash>-<hash>          2/2     Running   0          20m
> etcd-0                                                    1/1     Running   0          20m
> nats-0                                                    2/2     Running   0          20m
> nats-box-<hash>-<hash> （可以没有）                                   1/1     Running   0          20m
> # ── 推理组件（Step 5 部署）───────────────────────────────────────
> vllm-v1-disagg-router-frontend-<hash>-<hash>              1/1     Running   0          8m
> vllm-v1-disagg-router-vllmprefillworker-<hash>-<hash>     1/1     Running   0          8m
> vllm-v1-disagg-router-vllmdecodeworker-<hash>-<hash>      1/1     Running   0          8m
> ```
>
> | Pod 前缀 | READY | 角色 |
> |---------|-------|------|
> | `vllm-v1-disagg-router-frontend-*` | 1/1 | HTTP 入口 + KV Router（`DYN_ROUTER_MODE: kv`），CPU 节点可调度 |
> | `vllm-v1-disagg-router-vllmprefillworker-*` | 1/1 | Prefill 专用 GPU Worker，执行首 token 生成（高延迟敏感） |
> | `vllm-v1-disagg-router-vllmdecodeworker-*` | 1/1 | Decode 专用 GPU Worker，执行后续 token 流式输出（高吞吐敏感） |
>
![alt text](image-6.png)

**确认 DGD 整体就绪：**

```bash
kubectl get dynamographdeployment -n ${NAMESPACE}
```

> ✅ 预期输出：
> ```
> NAME                     READY   AGE
> vllm-v1-disagg-router    True    15m
> ```
> `READY=True` 表示所有组件均已 Running 并通过健康检查。
![alt text](image-7.png)

**确认 GPU 已分配：**

```bash
kubectl get pods -n ${NAMESPACE} -o custom-columns=\
'NAME:.metadata.name,STATUS:.status.phase,GPU:.spec.containers[0].resources.limits.nvidia\.com/gpu'
```

> ✅ PrefillWorker 和 DecodeWorker 的 `GPU` 列应显示 `1`，Frontend 显示 `<none>`。

![alt text](image-8.png)

---

## Step 6：验证推理 API

> **目的**：通过真实 HTTP 请求端到端验证推理链路完整可用——从 Frontend 接收请求，经 KV Router 分发到 Prefill/Decode Worker，再将结果返回客户端。这是确认整套部署成功的最终标准。

```bash
# 端口转发 Frontend Service
kubectl port-forward \
  svc/vllm-v1-disagg-router-frontend \
  8000:8000 \
  -n ${NAMESPACE} &

sleep 3
```

**验证 1：查询可用模型**

```bash
curl -s http://localhost:8000/v1/models | python3 -m json.tool
```

> ```json
> {
>   "data": [
>     {
>       "id": "Qwen/Qwen3-0.6B",
>       "object": "model"
>     }
>   ]
> }
> ```

**验证 2：发送推理请求**

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "'"${MODEL_NAME}"'",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 50
  }'
```

> ✅ 收到包含 `choices[0].message.content` 的 JSON 响应，内容合理（如回答 `2`）则推理链路完全正常。  
> ❌ `Connection refused` → port-forward 未启动，重新执行上面的 `kubectl port-forward` 命令  
> ❌ `503 Service Unavailable` → Worker 尚未完全就绪，等待 DGD `READY=True` 后再试
![alt text](image-9.png)
---

## Step 7：验证 Disaggregated 路由行为（可选）

> **目的**：通过观察 PrefillWorker 和 DecodeWorker 的实时日志，确认 KV Router 确实按 Disaggregated 模式分配请求，而非所有计算都由单一 Worker 完成。用于验证路由策略配置正确，排查 KV Cache 命中率异常。

确认 KV Router 确实将请求分别路由给 Prefill 和 Decode Worker：

```bash
# 后台观察两类 Worker 日志
kubectl logs -l dynamo.nvidia.com/component-type=worker \
  -n ${NAMESPACE} --prefix=true --tail=20 &

# 发送几条请求
for i in 1 2 3; do
  curl -s http://localhost:8000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"'"${MODEL_NAME}"'","messages":[{"role":"user","content":"Count to '"$i"'"}],"max_tokens":30}' \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])"
done
```

> ✅ 多条请求均正常响应，且 PrefillWorker 和 DecodeWorker 的日志均有活动，说明 Disaggregated 路由工作正常。

---

## Step 8：配置 HPA Auto Scaling（可选）

> **目的**：根据实际推理请求队列深度自动调整 Worker 副本数，在负载高峰时横向扩容以降低排队延迟，在负载低谷时缩容以节省 GPU 资源，避免人工干预。

Dynamo 的 DGD manifest 中的 `autoscaling` 字段会自动创建 K8s HPA 对象。若在 Step 4 的 manifest 中已配置 `autoscaling`，验证如下：

```bash
kubectl get hpa -n ${NAMESPACE}
# 应看到每个启用 autoscaling 的服务对应一个 HPA 对象
```

**配置基于推理队列深度的 Worker HPA（推荐生产）：**

> ⚠️ **集群级共享组件**：`prometheus-adapter` 为整个集群暴露自定义指标 API，多人共用同一集群时只需安装一次。下方命令已加检测，已存在时自动跳过。

```bash
cat > /tmp/prom-adapter-values.yaml << 'EOF'
prometheus:
  url: http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local
  port: 9090
rules:
  custom:
    - seriesQuery: 'dynamo_request_queue_size{namespace!="",pod!=""}'
      resources:
        overrides:
          namespace: {resource: "namespace"}
          pod: {resource: "pod"}
      name:
        matches: "dynamo_request_queue_size"
        as: "dynamo_request_queue_size"
      metricsQuery: 'avg(dynamo_request_queue_size{<<.LabelMatchers>>}) by (<<.GroupBy>>)'
EOF

# prometheus-adapter 已存在则跳过，避免多人部署时冲突
if helm status prometheus-adapter -n monitoring &>/dev/null; then
  echo "prometheus-adapter already installed, skipping."
else
  helm install prometheus-adapter \
    prometheus-community/prometheus-adapter \
    --namespace monitoring \
    --values /tmp/prom-adapter-values.yaml \
    --wait
fi

# 验证自定义指标 API 可用
kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1 | python3 -m json.tool | head -30
```

**手动调整副本数（临时操作，DGD 不支持 `kubectl scale`）：**

```bash
kubectl patch dynamographdeployment vllm-v1-disagg-router \
  --type=merge \
  -p '{"spec":{"services":{"VllmDecodeWorker":{"replicas":2}}}}' \
  -n ${NAMESPACE}
```

---

## Step 9：全链路监控验证（可选）

> **目的**：将 Dynamo 的推理性能指标（TTFT、ITL、吞吐量、请求队列深度等）接入 Prometheus 采集并在 Grafana 看板中可视化，实现对生产推理服务的持续可观测性，支撑性能调优和容量规划。

### 部署 Dynamo Grafana Dashboard

> ⚠️ **集群级共享资源**：Grafana Dashboard ConfigMap 部署在 `monitoring` namespace，多人共用时由管理员执行一次即可。多人重复 `kubectl apply` 会覆盖彼此修改（last-writer-wins），不会报错但会静默替换。

```bash
kubectl apply -n monitoring \
  -f deploy/observability/k8s/grafana-dynamo-dashboard-configmap.yaml

kubectl get configmap -n monitoring | grep dynamo
# grafana-dynamo-dashboard   ...
```

Grafana 的 dashboard sidecar 会自动发现带有 `grafana_dashboard: "1"` 标签的 ConfigMap 并加载，无需手动 import。

### 验证 Prometheus 采集到 Dynamo 指标

```bash
kubectl port-forward svc/prometheus-kube-prometheus-prometheus \
  9090:9090 -n monitoring &

sleep 3

# 查询指标（发送推理请求后应有数据）
curl -s "http://localhost:9090/api/v1/query?query=dynamo_frontend_requests_total" \
  | python3 -m json.tool
```

> ✅ 返回 JSON 中 `data.result` 数组非空则 Prometheus 已采集到 Dynamo 指标。  
> 浏览器访问 `http://localhost:9090` 可在 Graph 页面查询 `dynamo_request_queue_size`、`dynamo_time_to_first_token_seconds_bucket` 等指标。

### 访问 Grafana 查看推理性能看板

```bash
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring
# 浏览器访问 http://localhost:3000，登录后搜索 "dynamo" Dashboard
```

> ✅ Dashboard 应包含：Request Rate、Time to First Token (TTFT)、Inter Token Latency (ITL)、Request Queue Size 等面板。

---

## 开发迭代工作流

### 修改代码并重新部署

```bash
# 1. 构建新镜像
export NEW_TAG=0.7.1-dev-$(git rev-parse --short HEAD)
bash container/build.sh --framework VLLM
docker tag dynamo-vllm:latest localhost:5000/dynamo/vllm-runtime:${NEW_TAG}
docker push localhost:5000/dynamo/vllm-runtime:${NEW_TAG}

# 2. Patch DGD 中的镜像 tag
kubectl patch dynamographdeployment vllm-v1-disagg-router \
  --type=merge \
  -p "{\"spec\":{\"services\":{\"VllmDecodeWorker\":{\"extraPodSpec\":{\"mainContainer\":{\"image\":\"localhost:5000/dynamo/vllm-runtime:${NEW_TAG}\"}}}}}}" \
  -n ${NAMESPACE}
```

### 查看实时日志

```bash
# Frontend 日志
kubectl logs -l dynamo.nvidia.com/component-type=frontend \
  -n ${NAMESPACE} -f --tail=100

# Worker 日志（Prefill + Decode 都会输出）
kubectl logs -l dynamo.nvidia.com/component-type=worker \
  -n ${NAMESPACE} -f --tail=100 --prefix=true

# Operator 日志（查看 DGD 调协过程）
kubectl logs -l app.kubernetes.io/name=dynamo-operator \
  -n ${NAMESPACE} -f --tail=100
```

---

## 故障排查速查

| 问题现象 | 排查命令 | 常见原因 |
|---------|---------|---------|
| `etcd-0` Pending | `kubectl describe pod etcd-0 -n ${NAMESPACE}` | 无默认 StorageClass，PVC 无法 Bound |
| Worker OOMKilled | `kubectl describe pod <worker-pod> -n ${NAMESPACE}` | GPU 显存不足，减少 `replicas` 或换小模型 |
| 镜像拉取失败 (401) | `kubectl describe pod <pod> -n ${NAMESPACE}` 看 Events | `nvcr-imagepullsecret` 未创建或 NGC Key 过期 |
| DGD `READY=False` | `kubectl describe dynamographdeployment vllm-v1-disagg-router -n ${NAMESPACE}` | 查看 `Status.Conditions` 字段 |
| Prometheus 无 Dynamo 指标 | 访问 `localhost:9090/targets` 查看 Scrape 状态 | PodMonitor 未创建，检查 Operator 日志 |
| HPA `UNKNOWN` 状态 | `kubectl describe hpa -n ${NAMESPACE}` | Metrics Server 未安装或 Prometheus Adapter 未配置 |

### 一键状态检查

```bash
echo "=== DynamoGraphDeployment ==="
kubectl get dynamographdeployment -n ${NAMESPACE}

echo "=== All Pods ==="
kubectl get pods -n ${NAMESPACE} -o wide

echo "=== PVCs ==="
kubectl get pvc -n ${NAMESPACE}

echo "=== Services ==="
kubectl get svc -n ${NAMESPACE}

echo "=== CRDs ==="
kubectl get crd | grep dynamo

echo "=== Recent Events ==="
kubectl get events -n ${NAMESPACE} \
  --sort-by='.lastTimestamp' | tail -20
```

---

