# 部署 Prometheus & Grafana 完全指南


## 环境假设与前置条件

本文档假设你的单节点环境如下：

```
服务器
├── OS: Linux（Ubuntu 22.04 / Rocky 9 推荐）
├── K8s: 已安装（kubeadm / k3s / kind 均可）
│         - kubectl 可用且连接正常
│         - 已配置 kubeconfig
├── GPU: 至少 1 块 NVIDIA GPU（已安装驱动）
├── NVIDIA Container Toolkit: 已安装
├── NVIDIA GPU Operator: 已安装（或手动配置 device plugin）
├── 默认 StorageClass: 已配置（etcd/NATS 需要 PVC）
├── Helm v3.8+: 已安装
└── 互联网访问: 可访问 NGC / Docker Hub / GitHub
```

### 安装缺失工具

如果 `helm` 未安装，使用官方脚本安装（推荐，避免 snap 版本滞后）：

```bash
# 方式一：官方安装脚本（推荐）
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# 验证
helm version
# 期望输出：version.BuildInfo{Version:"v3.x.x", ...}
```
![alt text](image.png)
```bash
# 方式二：snap（系统已提示此方式，版本可能略旧）
sudo snap install helm --classic
```

> **注意**：snap 安装的 helm 在某些系统上访问 `/tmp` 目录会受 snap 沙箱限制，导致 `helm fetch` 写文件失败。推荐使用方式一。

### 工具检查

```bash
# 验证基础工具
kubectl version --client
helm version
docker info
nvidia-smi

# 验证 K8s 集群状态
kubectl get nodes
kubectl get storageclass   # 确认有 default StorageClass（带 (default) 标记）

# 验证 GPU 可被 K8s 调度
kubectl describe node | grep -A5 "Capacity:"
# 应看到: nvidia.com/gpu: 1（或更多）
```

## 阶段 0：单节点 K8s 预飞检查

### 0.1 确保单节点可被调度

默认情况下，K8s 主节点（control-plane）有污点（taint），需要移除才能在其上调度工作 Pod：

```bash
# 查看节点污点
kubectl describe node $(kubectl get nodes -o name | head -1) | grep Taints

# 如果是 kubeadm 安装的单节点，移除 control-plane 污点：
kubectl taint nodes --all node-role.kubernetes.io/control-plane-

# 验证节点可调度
kubectl get nodes
# STATUS 列应为 Ready，没有 SchedulingDisabled
```

> **✅ 预期输出参考（0.1）：**
> ```
> NAME           STATUS   ROLES                  AGE   VERSION
> your-node      Ready    control-plane,master   2d    v1.29.0
> ```
> 关键点：`STATUS=Ready`，无 `SchedulingDisabled` 字样即为成功。若 `STATUS=NotReady`，执行 `kubectl describe node <name>` 查看具体原因。

### 0.2 配置默认 StorageClass

etcd 和 NATS 需要持久化存储（PVC），确保有默认 StorageClass：

```bash
kubectl get storageclass
```

如果没有默认 StorageClass，安装 `local-path-provisioner`（单节点最简方案）：

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml

# 设置为默认
kubectl patch storageclass local-path \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# 验证
kubectl get storageclass
# local-path (default)   rancher.io/local-path   Delete   WaitForFirstConsumer ...
```

> **✅ 预期输出参考（0.2）：**
> ```
> NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION
> local-path (default) rancher.io/local-path   Delete          WaitForFirstConsumer   false
> ```
> 关键点：`NAME` 列出现 `(default)` 标记，说明默认 StorageClass 已配置，etcd/NATS 的 PVC 可以自动完成绑定。
![alt text](image-13.png)

### 0.3 注册 GPU 到 K8s 并验证

K8s 本身不会自动识别 GPU。需要安装 **NVIDIA Device Plugin** 或 **GPU Operator**，才能让容器真正拿到 `/dev/nvidiaX` 设备，并让 K8s 计数、防止多 Pod 抢占同一张卡。

> **两个调度层的关系**：Dynamo 负责推理请求路由（哪个 Worker 处理哪条请求），K8s Device Plugin 负责 Pod 放置与设备挂载（容器内能否看到 GPU）。两者互补，不可替代。

#### 方式一：仅安装 Device Plugin（轻量，快速）

适合：只需要基本 GPU 调度，不需要 DCGM 监控指标。

```bash
# 以 DaemonSet 方式部署，自动在每个节点上运行
kubectl create -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.0/deployments/static/nvidia-device-plugin.yml

# 等待 DaemonSet Ready
kubectl rollout status daemonset/nvidia-device-plugin-daemonset -n kube-system --timeout=120s
```

#### 方式二：安装 GPU Operator（推荐，含 DCGM 监控）

适合：需要 GPU 利用率、显存、温度等 Prometheus 指标（与阶段 5 的 GPU 监控集成）。由于主机驱动已安装，使用 `--set driver.enabled=false` 跳过驱动安装。

```bash
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update

helm install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator \
  --create-namespace \
  --set driver.enabled=false \
  --set toolkit.enabled=true \
  --wait --timeout 10m
```

> **说明**：`driver.enabled=false` 表示使用主机上已有的 NVIDIA 驱动（不在容器内重装），`toolkit.enabled=true` 确保 NVIDIA Container Toolkit（containerd runtime hook）正确配置。

等待所有 GPU Operator 组件就绪：

```bash
kubectl get pods -n gpu-operator
# 期望看到以下 Pod 全部 Running：
# gpu-operator-*                Running
# nvidia-device-plugin-daemonset-*   Running
# nvidia-dcgm-exporter-*        Running  ← DCGM 监控，阶段 5 需要
# nvidia-container-toolkit-daemonset-* Running
```
![alt text](image-1.png)
#### 验证 GPU 已注册

```bash
# 确认 nvidia.com/gpu 资源已出现在节点容量中
kubectl get nodes -o json | python3 -c "
import json, sys
nodes = json.load(sys.stdin)['items']
for n in nodes:
    name = n['metadata']['name']
    cap  = n['status']['capacity'].get('nvidia.com/gpu', '0')
    alloc = n['status']['allocatable'].get('nvidia.com/gpu', '0')
    print(f'Node {name}: capacity={cap}, allocatable={alloc}')
"
```

> **✅ 预期输出参考（0.3）：**
> ```
> Node your-node: capacity=8, allocatable=8
> ```
> 若显示 `capacity=0`，说明 Device Plugin 未正确运行。检查：
> ```bash
> kubectl get pod -A | grep -E 'device-plugin|gpu-operator'
> kubectl describe node <node-name> | grep -A10 'Allocatable:'
> # 正常情况下 Allocatable 区块应包含：
> #   nvidia.com/gpu:  8
> ```
![alt text](image-2.png)
---

## 阶段 1：部署 Prometheus & Grafana（集群内）

> **在 Dynamo 平台之前安装监控栈**，因为 Dynamo Operator 安装时需要传入 Prometheus 的集群内 Service 地址。

### 1.1 创建 monitoring namespace 并添加 Helm repo

```bash
kubectl create namespace monitoring

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

### 1.2 安装 kube-prometheus-stack（单节点适配版）

创建单节点专用的 values 文件，避免 HA 相关 PodDisruptionBudget 和多副本要求：

```bash
cat > /tmp/prometheus-values-single-node.yaml << 'EOF'
# ============================================================
# kube-prometheus-stack 单节点优化配置
# ============================================================

# Grafana 配置
grafana:
  enabled: true
  replicas: 1
  # 启用持久化（避免重启丢失 dashboard 自定义配置）
  persistence:
    enabled: true
    size: 5Gi
  # 允许加载外部 ConfigMap 中的 Dashboard
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      labelValue: "1"
      searchNamespace: ALL
  adminPassword: ""  # 通过安全渠道获取并在部署时通过环境变量 GRAFANA_ADMIN_PASSWORD 传入

# Prometheus 配置
prometheus:
  prometheusSpec:
    # 允许跨 namespace 发现 PodMonitor / ServiceMonitor
    podMonitorSelectorNilUsesHelmValues: false
    podMonitorNamespaceSelector: {}
    serviceMonitorSelectorNilUsesHelmValues: false
    serviceMonitorNamespaceSelector: {}
    probeNamespaceSelector: {}
    # 数据保留 15 天（单节点磁盘有限，可按需调整）
    retention: 15d
    # 持久化存储 metrics 数据
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 20Gi
    replicas: 1

# Alertmanager 单副本（无需 HA）
alertmanager:
  alertmanagerSpec:
    replicas: 1

# node-exporter：DaemonSet，自动收集节点指标（无需修改）
nodeExporter:
  enabled: true

# kube-state-metrics：收集 K8s 对象状态
kubeStateMetrics:
  enabled: true
EOF
```

```bash
helm install prometheus \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values /tmp/prometheus-values-single-node.yaml \
  --timeout 10m \
  --wait
```

### 1.3 验证 Prometheus & Grafana 正常运行

```bash
kubectl get pods -n monitoring
# 期望看到以下 Pod 全部为 Running：
# prometheus-grafana-*
# prometheus-kube-prometheus-prometheus-*
# prometheus-kube-prometheus-alertmanager-*
# prometheus-kube-state-metrics-*
# prometheus-prometheus-node-exporter-* (DaemonSet，每节点一个)
```

> **✅ 预期输出参考（1.3）：**
> ```
> NAME                                                     READY   STATUS    RESTARTS   AGE
> prometheus-grafana-7d9d9f4b5c-xxxxx                      3/3     Running   0          3m
> prometheus-kube-prometheus-prometheus-0                  2/2     Running   0          3m
> prometheus-kube-prometheus-alertmanager-0                2/2     Running   0          3m
> prometheus-kube-state-metrics-xxxxxxxxx-xxxxx            1/1     Running   0          3m
> prometheus-prometheus-node-exporter-xxxxx                1/1     Running   0          3m
> prometheus-kube-prometheus-operator-xxxxxxxxx-xxxxx      1/1     Running   0          3m
> ```
> 全部 `STATUS=Running` 且 `READY` 中无 `0/x` 则安装成功。若某 Pod 一直 `Pending`，优先检查 StorageClass（阶段 0.2）是否已配置。
![alt text](image-3.png)

### 1.4 临时访问 Grafana（验证安装）

**情况 A：在服务器本地浏览器访问（服务器有桌面环境）**

```bash
# 在服务器上执行，后台运行
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring &
# 浏览器访问 http://localhost:3000
```

**情况 B：从本地电脑访问远程服务器上的 Grafana（推荐）**

`kubectl port-forward` 默认只绑定服务器的 `127.0.0.1`，需要通过 **SSH 本地端口转发**把流量从本地机器引过来。

在**本地电脑**上执行（二选一）：

```bash
# 方式一：先建立 SSH 隧道，再在服务器上手动启动 port-forward
# 步骤 1：本地建立隧道（保持此终端不关闭）
ssh -L 3000:localhost:3000 gpu14

# 步骤 2：在刚打开的 SSH 会话中执行
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring
```

```bash
# 方式二：一条命令完成（隧道 + port-forward 同时启动）
ssh -L 3000:localhost:3000 gpu14 \
  "kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring"
```

两种方式均完成后，在**本地浏览器**访问 `http://localhost:3000`。

> **原理**：`-L 3000:localhost:3000` 表示把本地的 3000 端口通过 SSH 隧道转发到服务器的 `localhost:3000`，与服务器上 `kubectl port-forward` 监听的端口对接。

确认可以进入 Grafana 主界面，看到预置的 K8s 相关 Dashboard 即为成功。

> **✅ 预期结果参考（1.4）：**
> - 浏览器访问 `http://localhost:3000` 可以正常打开登录页面
> - 使用 `admin` / `<GRAFANA_ADMIN_PASSWORD>` 登录后，左侧菜单 **Dashboards** 下可见多个预置看板（如 `Kubernetes / Compute Resources / Node`）
![alt text](image-4.png)
### 1.5 记录 Prometheus 集群内地址（后续安装 Dynamo 需要）

```bash
# 这是 Dynamo Platform 安装时要传入的地址
kubectl get svc -n monitoring | grep prometheus
# 目标 Service 名称类似：prometheus-kube-prometheus-prometheus
# 完整集群内 DNS 地址为：
echo "Prometheus endpoint: http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090"
```

> **✅ 预期输出参考（1.5）：**
> ```
> NAME                                          TYPE        CLUSTER-IP      PORT(S)    AGE
> prometheus-grafana                            ClusterIP   10.96.xx.xx     80/TCP     8m
> prometheus-kube-prometheus-alertmanager       ClusterIP   10.96.xx.xx     9093/TCP   8m
> prometheus-kube-prometheus-operator           ClusterIP   10.96.xx.xx     443/TCP    8m
> prometheus-kube-prometheus-prometheus         ClusterIP   10.96.xx.xx     9090/TCP   8m
> prometheus-kube-state-metrics                 ClusterIP   10.96.xx.xx     8080/TCP   8m
> ```
> 确认存在 `prometheus-kube-prometheus-prometheus` 服务即可。阿步段 2.4 中将使用其集群内 DNS 名称（而非 ClusterIP）进行配置。
![alt text](image-5.png)
---
