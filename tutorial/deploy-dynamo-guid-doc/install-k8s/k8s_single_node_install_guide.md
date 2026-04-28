# Kubernetes 单机安装详细步骤指南（基于 kubeadm，单节点集群）

> 参考：
> - [Kubernetes 官方文档 - Installing kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install/)
> - [Kubernetes 官方文档 - Creating a cluster with kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/)

---

## 单机部署说明

单机部署即将 Control Plane（Master）和 Worker 的职责合并到**一台机器**上运行。与双节点部署的核心差异：

| 维度 | 单机部署 | 双节点部署 |
|---|---|---|
| 节点数量 | 1 | 2+（Master + Worker） |
| Pod 调度 | 所有 Pod 都运行在同一节点 | 系统组件在 Master，业务 Pod 在 Worker |
| Master taint | **必须去除 taint**，否则业务 Pod 无法调度 | 保留 taint，Worker 节点调度业务 |
| Worker join | **不需要** | Worker 需执行 `kubeadm join` |
| `/etc/hosts` | 不需要配置对端主机 | 需配置所有节点主机名/IP |
| 防火墙端口 | 只需开 Master 侧端口 | Master/Worker 各自开端口 |
| 适用场景 | 学习、开发、测试 | 生产、准生产环境 |

---

## 机器规划

| 角色 | 主机名 | 最低配置 |
|------|--------|---------|
| Control Plane + Worker（All-in-One） | master-node | **2 CPU, 4GB RAM, 30GB 磁盘** |

> **注意：** 单机部署由于系统组件与业务 Pod 共享资源，建议内存 ≥ 4GB。2GB 可以启动但容易 OOM。

- **操作系统**：Ubuntu 22.04 LTS（本指南以此为例，CentOS 7+/RHEL 8+ 类似）
- **网络**：需要能访问外网（拉取镜像和安装包）

---

## 步骤总览

| 步骤 | 操作 | 权限 | 关键验收 |
|---|---|---|---|
| 1 | 系统预检：关 swap、加载内核模块、配置参数 | root/sudo | swap=0, ip_forward=1 |
| 2 | 安装 containerd（CRI 容器运行时） | root/sudo | containerd active (running) |
| 3 | 安装 kubeadm / kubelet / kubectl | root/sudo | 三组件版本一致 |
| 4 | `kubeadm init` 初始化控制平面 | root/sudo | `kubectl cluster-info` 正常 |
| 5 | 配置 kubectl 访问权限 | 普通用户 | `kubectl get nodes` 可执行 |
| 6 | 安装 CNI 网络插件 | kubectl 用户 | 节点变 Ready，CoreDNS Running |
| 7 | 去除 Master taint（**单机必须**） | kubectl 用户 | 业务 Pod 可调度到该节点 |
| 8 | 部署验证性工作负载 | kubectl 用户 | nginx 可通过 NodePort 访问 |

---

## 步骤总览流程图

```
┌─────────────────────────────────────────────────┐
│          单节点（All-in-One）                      │
│                                                  │
│  Step 1: 系统预检与基础配置                        │
│            ↓                                     │
│  Step 2: 安装容器运行时 (containerd)               │
│            ↓                                     │
│  Step 3: 安装 kubeadm / kubelet / kubectl         │
│            ↓                                     │
│  Step 4: kubeadm init 初始化控制平面               │
│            ↓                                     │
│  Step 5: 配置 kubectl 访问权限                     │
│            ↓                                     │
│  Step 6: 安装 CNI 网络插件                         │
│            ↓                                     │
│  Step 7: 去除 Master taint（单机关键步骤）          │
│            ↓                                     │
│  Step 8: 部署验证性工作负载                        │
│            ↓                                     │
│  总验收：集群功能完整性检查                         │
└─────────────────────────────────────────────────┘
```

---

## 第 1 步：系统预检与基础配置

### 目的
确保系统满足 Kubernetes 运行的基本前提条件，消除已知的兼容性问题。

### 所需权限
`root` 或 `sudo` 权限

### 操作内容

#### 1.1 设置主机名（跳过，会修改主机名字gpu13/14为master-node）

```bash
sudo hostnamectl set-hostname master-node
```

#### 1.2 关闭 swap（K8s 硬性要求）

检查服务器内存情况：确认关闭swap没有影响
![alt text](image1.png)

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab
```

> **说明：** Kubernetes 要求关闭 swap，否则 kubelet 默认无法启动。`swapoff -a` 立即关闭，`sed` 命令注释掉 `/etc/fstab` 中的 swap 行使其重启后也不会自动挂载。

#### 1.3 加载必要的内核模块

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
```

> **说明：**
> - `overlay`：containerd 的存储驱动依赖此模块
> - `br_netfilter`：使桥接流量可被 iptables 处理，K8s 网络通信必需

#### 1.4 设置必要的 sysctl 参数（网络桥接和转发）

```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

#### 1.5 关闭防火墙（或开放所需端口，多节点的话需要做，单节点安装可以跳过）

```bash
# 方式一：直接关闭防火墙（开发/测试环境推荐）
sudo ufw disable

# 方式二：仅开放所需端口（生产环境推荐）
sudo ufw allow 6443/tcp        # Kubernetes API Server
sudo ufw allow 2379:2380/tcp   # etcd
sudo ufw allow 10250/tcp       # Kubelet API
sudo ufw allow 10259/tcp       # kube-scheduler
sudo ufw allow 10257/tcp       # kube-controller-manager
sudo ufw allow 10256/tcp       # kube-proxy
sudo ufw allow 30000:32767/tcp # NodePort Services
```

**单机部署需开放的端口（全集）：**

| 端口 | 用途 |
|------|------|
| 6443 | Kubernetes API Server |
| 2379-2380 | etcd |
| 10250 | Kubelet API |
| 10259 | kube-scheduler |
| 10257 | kube-controller-manager |
| 10256 | kube-proxy |
| 30000-32767 | NodePort Services |

### ✅ 验收标准

逐项执行以下命令，全部通过即为合格：

```bash
# 1) swap 已关闭
free -h
# ✅ 预期：Swap 行的 total/used/free 全部为 0

# 2) 内核模块已加载
lsmod | grep br_netfilter
# ✅ 预期：有输出，包含 br_netfilter

lsmod | grep overlay
# ✅ 预期：有输出，包含 overlay

# 3) sysctl 参数生效
sysctl net.bridge.bridge-nf-call-iptables
# ✅ 预期：net.bridge.bridge-nf-call-iptables = 1

sysctl net.ipv4.ip_forward
# ✅ 预期：net.ipv4.ip_forward = 1

# 4) 主机名正确
hostname
# ✅ 预期：显示 master-node
```

**验收结论：** 以上 4 项全部通过，说明系统基础环境已就绪，可进入下一步。任一项不通过需排查后重试。
![alt text](image.png)
![alt text](image-2.png)
---

## 第 2 步：安装容器运行时（containerd）

### 目的
Kubernetes 本身不直接运行容器，需要一个符合 CRI（Container Runtime Interface）规范的容器运行时。自 K8s 1.24 起移除了内置 dockershim，官方推荐使用 **containerd**。

### 所需权限
`root` 或 `sudo` 权限

### 操作内容

#### 2.1 安装 containerd

```bash
sudo apt-get update
sudo apt-get install -y containerd
```

在gpu13上安装containerd之前apt-get update失败，无法访问代理。并且查看cpu01的8000端口，没有代理程序运行。因此换在gpu14上安装。

![alt text](<Screenshot 2026-03-17 093853.png>)
![alt text](image-1.png)


#### 2.2 生成默认配置文件

```bash
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
```

#### 2.3 配置 containerd 使用 systemd 作为 cgroup 驱动

```bash
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
```

> **说明：** kubelet 默认使用 systemd 作为 cgroup 驱动，containerd 也必须保持一致，否则节点状态会出现异常。这是新手最容易遗漏的关键配置。

#### 2.4 重启并启用 containerd

```bash
sudo systemctl restart containerd
sudo systemctl enable containerd
```

### ✅ 验收标准

```bash
# 1) containerd 服务正在运行
sudo systemctl status containerd
# ✅ 预期：Active: active (running)

# 2) cgroup 驱动已配置为 systemd
grep SystemdCgroup /etc/containerd/config.toml
# ✅ 预期：SystemdCgroup = true

# 3) containerd 版本可查
containerd --version
# ✅ 预期：显示版本号，如 containerd containerd.io 1.7.x
```

**验收结论：** containerd 服务运行正常且 cgroup 驱动为 systemd，容器运行时就绪。
![alt text](image-3.png)
---

## 第 3 步：安装 kubeadm、kubelet、kubectl

### 目的
- **kubeadm**：集群初始化和管理工具
- **kubelet**：运行在节点上的核心代理，负责管理 Pod 和容器的生命周期
- **kubectl**：命令行工具，与集群 API Server 交互

### 所需权限
`root` 或 `sudo` 权限

### 操作内容

#### 3.1 安装必要依赖

```bash
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
```

#### 3.2 添加 Kubernetes apt 仓库的签名密钥

```bash
# 创建 keyrings 目录（如不存在）
sudo mkdir -p /etc/apt/keyrings

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
```

> **注意：** 如需安装其他版本，将 URL 中的 `v1.30` 替换为目标版本，如 `v1.29`、`v1.31`。

#### 3.3 添加 Kubernetes apt 仓库

```bash
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
```

#### 3.4 安装三件套

```bash
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
```

#### 3.5 锁定版本，防止意外升级

```bash
sudo apt-mark hold kubelet kubeadm kubectl
```

> **说明：** K8s 组件版本必须严格匹配，自动升级可能导致集群不一致，因此锁定版本。

#### 3.6 启用 kubelet 服务

```bash
sudo systemctl enable kubelet
```

> **注意：** 此时 kubelet 会不断重启并报错，这是**正常现象**，因为还没有执行 `kubeadm init`。kubelet 在等待 kubeadm 提供的配置文件。

### ✅ 验收标准

```bash
# 1) 各组件版本正确且一致
kubeadm version
# ✅ 预期：显示版本，如 kubeadm version: &version.Info{Major:"1", Minor:"30", ...}

kubelet --version
# ✅ 预期：显示版本，如 Kubernetes v1.30.x

kubectl version --client
# ✅ 预期：显示客户端版本，如 Client Version: v1.30.x
# ✅ 三者的 minor version 必须一致（都是 1.30）

# 2) kubelet 服务已启用
sudo systemctl is-enabled kubelet
# ✅ 预期：enabled

# 3) 版本已锁定
apt-mark showhold
# ✅ 预期：输出包含 kubelet、kubeadm、kubectl
```

**验收结论：** 三组件安装完成、版本一致、已锁定、kubelet 已设为开机自启。可进入集群初始化。
![alt text](image-4.png)
---

## 第 4 步：初始化 Control Plane（kubeadm init）

### 目的
在本机上启动 Kubernetes 控制平面组件（API Server、etcd、Controller Manager、Scheduler），生成集群证书和配置。

### 所需权限
`root` 或 `sudo` 权限

### 操作内容

#### 4.1 获取本机 IP

```bash
# 查看本机 IP（选取对外通信的网卡 IP）
ip addr show
# 或
hostname -I | awk '{print $1}'
```

记录本机 IP，下面命令中替换 `<本机IP>`。

#### 4.2 执行集群初始化

```bash
sudo kubeadm init \
  --apiserver-advertise-address=<本机IP> \
  --pod-network-cidr=10.244.0.0/16 \

sudo kubeadm init \
  --apiserver-advertise-address=192.168.1.246 \
  --pod-network-cidr=10.244.0.0/16 

#   --control-plane-endpoint=192.168.2.99
#   --control-plane-endpoint=master-node
```
**问题**：
![alt text](image-5.png)

这是上次 kubeadm init 失败后遗留了不完整的 PKI 文件，导致 kubeadm 误以为在使用外部 CA

```
# 1. 重置清理
sudo kubeadm reset -f

# 2. 删除残留的 PKI 和配置文件
sudo rm -rf /etc/kubernetes/pki/
sudo rm -rf /etc/kubernetes/*.conf

# 3. 重新初始化
 kubeadm init \
  --apiserver-advertise-address=192.168.1.246 \
  --pod-network-cidr=10.244.0.0/16
```

**参数说明：**

| 参数 | 说明 |
|------|------|
| `--apiserver-advertise-address` | API Server 监听的 IP，填本机 IP |
| `--pod-network-cidr` | Pod 网络的 CIDR 范围。使用 Flannel 时必须为 `10.244.0.0/16`，使用 Calico 时通常为 `192.168.0.0/16` |
| `--control-plane-endpoint` | 控制平面入口地址，单机安装首选不写，其次写固定ip,最不推荐写主机名 |

> **⚠ 重要：** 如果初始化失败需要重试，先执行 `sudo kubeadm reset` 清理环境后再重新 init。

> **国内网络提示：** 如果拉取镜像超时，可添加 `--image-repository=registry.aliyuncs.com/google_containers` 使用阿里云镜像源。

#### 4.3 初始化成功的输出（记录关键信息）

初始化成功后会输出类似以下内容：

```
Your Kubernetes control plane has initialized successfully!

To start using your cluster, you need to run the following as a regular user:

  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

Then you can join any number of worker nodes by running the following on each as root:

  kubeadm join master-node:6443 --token <token> \
    --discovery-token-ca-cert-hash sha256:<hash>
```

> **单机部署不需要记录 join 命令**，因为没有 Worker 节点要加入。但如果未来计划扩展为多节点，可以记录备用。

### ✅ 验收标准

```bash
# 1) kubeadm init 命令执行完毕，输出包含 "Your Kubernetes control plane has initialized successfully!"
# ✅ 预期：看到上述成功提示

# 2) /etc/kubernetes/ 下生成了配置文件
ls /etc/kubernetes/
# ✅ 预期：包含 admin.conf, controller-manager.conf, kubelet.conf, scheduler.conf, pki/ 等

# 3) 静态 Pod manifest 文件已生成
ls /etc/kubernetes/manifests/
# ✅ 预期：包含 etcd.yaml, kube-apiserver.yaml, kube-controller-manager.yaml, kube-scheduler.yaml
```

**验收结论：** 控制平面初始化成功，证书和配置文件已生成。下一步配置 kubectl 访问。
![alt text](image-6.png)
![alt text](image-7.png)
---

## 第 5 步：配置 kubectl 访问权限

### 目的
将集群的管理员配置文件复制到当前用户目录下，使 `kubectl` 命令可以与集群通信。

### 所需权限
当前登录用户（非 root 建议使用普通用户操作日常 kubectl 命令）

### 操作内容




```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```


**`其他人后续使用k8s需要在自己的 ~/.bashrc 中加上这两行就可以使用 kubectl了`**

```bash
echo 'export KUBECONFIG=/etc/kubernetes/admin.conf' >> ~/.bashrc
source ~/.bashrc
```

> **说明：** 这三条命令就是 `kubeadm init` 输出中提示的操作。如果是 root 用户，也可以设置环境变量：`export KUBECONFIG=/etc/kubernetes/admin.conf`

### ✅ 验收标准

```bash
# 1) kubectl 可以与集群通信
kubectl cluster-info
# ✅ 预期：
# Kubernetes control plane is running at https://master-node:6443
# CoreDNS is running at https://master-node:6443/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy

# 2) 查看节点状态（此时应为 NotReady，因 CNI 未安装）
kubectl get nodes
# ✅ 预期：
# NAME          STATUS     ROLES           AGE   VERSION
# master-node   NotReady   control-plane   ...   v1.30.x
# （NotReady 是正常的，因为还没安装网络插件）

# 3) 查看系统 Pod 状态
kubectl get pods -n kube-system
# ✅ 预期：
# etcd-master-node                      1/1   Running   ...
# kube-apiserver-master-node             1/1   Running   ...
# kube-controller-manager-master-node    1/1   Running   ...
# kube-scheduler-master-node             1/1   Running   ...
# kube-proxy-xxxxx                       1/1   Running   ...
# coredns-xxxxx                          0/1   Pending   ...  ← CNI 未装，Pending 正常
# coredns-xxxxx                          0/1   Pending   ...  ← 同上
```

**验收结论：** kubectl 已正确配置，集群可通信。控制平面核心组件（etcd、apiserver、controller-manager、scheduler、kube-proxy）全部 Running。CoreDNS 为 Pending 是正常的（等待 CNI）。
![alt text](image-8.png)
---

## 第 6 步：安装 Pod 网络插件（CNI）

### 目的
K8s 本身不提供 Pod 间的网络通信能力，必须安装 CNI（Container Network Interface）插件来实现 Pod 网络通信和 DNS 解析。

### 所需权限
能执行 `kubectl apply` 的用户

### 操作内容

以下三个方案任选其一：

#### 方案 A：安装 Flannel（简单，推荐新手使用。 gpu14上安装的就是Flannel）

```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

> **前提：** `kubeadm init` 时必须指定 `--pod-network-cidr=10.244.0.0/16`

#### 方案 B：安装 Calico（功能更丰富，支持网络策略）

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml
```

> **前提：** 如果 `kubeadm init` 时使用了 `10.244.0.0/16`，需修改 Calico 的 CALICO_IPV4POOL_CIDR 环境变量匹配。

#### 方案 C：安装 Cilium（基于 eBPF，性能最优，适合进阶用户）

```bash
# 先安装 Cilium CLI
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz

# 安装 Cilium
cilium install
```

### ✅ 验收标准

```bash
# 1) 节点状态变为 Ready
kubectl get nodes
# ✅ 预期：
# NAME          STATUS   ROLES           AGE   VERSION
# master-node   Ready    control-plane   ...   v1.30.x
# （从 NotReady → Ready，这是最关键的变化）

# 2) CNI 插件 Pod 运行正常
kubectl get pods -n kube-system
# ✅ 预期（以 Flannel 为例）：
# kube-flannel-ds-xxxxx    1/1   Running   ...

# 使用 Calico 时：
# calico-node-xxxxx        1/1   Running   ...
# calico-kube-controllers-xxxxx  1/1  Running  ...

# 3) CoreDNS Pod 从 Pending 变为 Running
kubectl get pods -n kube-system -l k8s-app=kube-dns
# ✅ 预期：
# coredns-xxxxx   1/1   Running   ...
# coredns-xxxxx   1/1   Running   ...

# 4) 所有 kube-system Pod 状态检查
kubectl get pods -n kube-system
# ✅ 预期：所有 Pod 都应为 Running 状态，RESTARTS 为 0 或很低
```

**验收结论：** 节点状态变为 Ready，所有系统 Pod（包括 CoreDNS）正常运行。集群网络已就绪。

但是安装好后pod一直处于pending，查询了日志后诊断为磁盘剩余空间比例小。修改配置后重启。

![alt text](image-10.png)

![alt text](image-9.png)

![alt text](image-11.png)

![alt text](image-12.png)
---

## 第 7 步：去除 Master taint（⭐ 单机部署关键步骤）

### 目的
默认情况下，Kubernetes 会给 Control Plane 节点打上 `NoSchedule` 的 taint（污点），阻止业务 Pod 调度到 Master 节点上。在单机部署中，**必须去除此 taint**，否则业务 Pod 永远无法调度（因为没有其他节点可用）。

> **这是单机部署与双节点部署最关键的区别之一。**

### 所需权限
能执行 `kubectl taint` 的用户

### 操作内容

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

> **说明：** 末尾的 `-` 表示删除该 taint。`--all` 对所有节点生效（单机只有一个节点）。

如果上述命令提示 taint 不存在（`taint "node-role.kubernetes.io/control-plane" not found`），说明该 taint 本来就没设置，可忽略。

### ✅ 验收标准

```bash
# 1) 确认 taint 已去除
kubectl describe node gpu14 | grep -A5 Taints
# ✅ 预期：
# Taints:   <none>
# （或不包含 node-role.kubernetes.io/control-plane:NoSchedule）

# 2) 快速验证 Pod 可调度
kubectl run taint-test --image=nginx --restart=Never
# 等待几秒后检查
kubectl get pod taint-test -o wide
# ✅ 预期：
# NAME         READY   STATUS    ...   NODE
# taint-test   1/1     Running   ...   master-node
# （Pod 成功调度到 master-node）

# 3) 清理测试 Pod
kubectl delete pod taint-test
```

**验收结论：** Master taint 已去除，业务 Pod 能正常调度到唯一的 master-node 节点上。
![alt text](image-13.png)
---

## 第 8 步：部署验证性工作负载

### 目的
通过部署实际应用来端到端验证集群的调度、网络、Service 能力是否完整。

### 所需权限
能执行 `kubectl` 创建资源的用户

### 操作内容

#### 8.1 部署 nginx Deployment

```bash
kubectl create deployment nginx-test --image=nginx --replicas=2
```

#### 8.2 暴露为 NodePort Service

```bash
kubectl expose deployment nginx-test --port=80 --type=NodePort
```

#### 8.3 查看服务信息

```bash
kubectl get svc nginx-test
```

输出类似：

```
NAME         TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
nginx-test   NodePort   10.96.x.x      <none>        80:3xxxx/TCP   10s
```

记住输出中 `80:3xxxx` 中的 NodePort 端口号（30000-32767 范围）。

### ✅ 验收标准

```bash
# 1) Pod 全部运行在 master-node 上
kubectl get pods -o wide
# ✅ 预期：
# NAME                          READY   STATUS    ...   NODE
# nginx-test-xxxxxxx-xxxxx      1/1     Running   ...   master-node
# nginx-test-xxxxxxx-xxxxx      1/1     Running   ...   master-node
# （两个 Pod 都调度到 master-node，因为只有这一个节点）

# 2) Service 创建成功
kubectl get svc nginx-test
# ✅ 预期：TYPE 为 NodePort，PORT(S) 包含映射的 NodePort

# 3) 通过 NodePort 访问 nginx
curl http://localhost:<NodePort>
# 或
curl http://<本机IP>:<NodePort>
# ✅ 预期：返回 nginx 默认欢迎页 HTML 内容，包含 "Welcome to nginx!"

# 4) DNS 解析测试
kubectl run dns-test --image=busybox:1.28 --rm -it --restart=Never -- nslookup kubernetes
# ✅ 预期：成功解析 kubernetes.default.svc.cluster.local，显示 ClusterIP 地址

# 5) 清理测试资源
kubectl delete deployment nginx-test
kubectl delete svc nginx-test
```

**验收结论：** 应用部署、调度、Service 网络代理、DNS 解析全部正常。集群功能完整可用。

---

## 全部安装完成后的总验收

在所有步骤完成后，执行以下总验收清单：

### 节点状态验收

```bash
kubectl get nodes
```

| 检查项 | 预期结果 |
|--------|---------|
| 节点数量 | 1 个节点 |
| STATUS | `Ready` |
| ROLES | `control-plane` |
| VERSION | `v1.30.x`（与安装版本一致） |

### 系统组件验收

```bash
kubectl get pods -n kube-system
```

| 组件 | 预期状态 | 数量 |
|------|---------|------|
| etcd | Running | 1 |
| kube-apiserver | Running | 1 |
| kube-controller-manager | Running | 1 |
| kube-scheduler | Running | 1 |
| kube-proxy | Running | 1（单节点只有 1 个） |
| coredns | Running | 2 |
| CNI 插件 Pod（flannel/calico 等） | Running | 1（单节点只有 1 个） |

> **注意：** 与双节点不同，单机部署的 kube-proxy 和 CNI 插件 Pod 各只有 **1 个**（每个节点一个）。

### 综合验收清单

| # | 验收项 | 验证命令 | 预期结果 |
|---|--------|---------|---------|
| 1 | 节点 Ready | `kubectl get nodes` | 1/1 Ready |
| 2 | 系统 Pod 全部 Running | `kubectl get pods -n kube-system` | 所有 Pod Running，RESTARTS ≈ 0 |
| 3 | API Server 可访问 | `kubectl cluster-info` | 返回控制平面地址 |
| 4 | DNS 解析正常 | `kubectl run dns-test --image=busybox:1.28 --rm -it --restart=Never -- nslookup kubernetes` | 成功解析 |
| 5 | Pod 可调度 | `kubectl run test --image=nginx` | Pod Running 在 master-node |
| 6 | Service 可访问 | 创建 NodePort Service + `curl` | 外部可通过 NodePort 访问 |
| 7 | Taint 已去除 | `kubectl describe node master-node \| grep Taints` | `<none>` |
| 8 | kubelet 正常运行 | `sudo systemctl status kubelet` | active (running) |
| 9 | containerd 正常运行 | `sudo systemctl status containerd` | active (running) |
| 10 | 版本一致性 | `kubectl version` / `kubelet --version` | 各组件版本一致 |

### 安装完成后的集群状态

安装完成，集群没有任何业务 Pod，但有约 **8 个系统 Pod** 在运行：

| 组件 | 数量 | 作用 |
|---|---|---|
| kube-apiserver | 1 | 集群 API 入口 |
| etcd | 1 | 集群状态存储 |
| kube-controller-manager | 1 | 控制循环管理 |
| kube-scheduler | 1 | Pod 调度决策 |
| kube-proxy | 1 | Service 网络代理 |
| coredns | 2 | 集群内 DNS |
| CNI 插件 | 1 | Pod 网络通信 |

**资源占用概况：** 系统组件约占 400MB-800MB 内存、5-10% CPU。

**可查看的内容：**

```bash
kubectl get pods -A              # ~8 个系统 Pod，全部 Running
kubectl get nodes                # 1 个节点 Ready
kubectl get namespaces           # default, kube-system, kube-public, kube-node-lease, kube-flannel(如使用)
kubectl get svc -A               # kubernetes + kube-dns 两个系统 Service
kubectl get events -A            # 节点注册、Pod 调度等系统事件
```

> **注意：** `kubectl top` 命令默认不可用，需额外安装 [metrics-server](https://github.com/kubernetes-sigs/metrics-server)。
![alt text](image-14.png)
---

## 后续可选操作

### 扩展为多节点集群

单机集群可随时扩展为多节点。流程如下：

1. 在新机器上完成第 1-3 步（系统预检、containerd、kubeadm/kubelet/kubectl）
2. 在 master 上生成 join 命令：
   ```bash
   kubeadm token create --print-join-command
   ```
3. 在新 Worker 节点执行 join 命令：
   ```bash
   sudo kubeadm join master-node:6443 --token <token> \
     --discovery-token-ca-cert-hash sha256:<hash>
   ```
4. 验证：`kubectl get nodes` 显示新节点为 Ready

无需重新初始化 master，也无需恢复 taint。

### 安装 Metrics Server

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

安装后可使用 `kubectl top nodes` 和 `kubectl top pods` 查看资源使用情况。

---

## 常见问题排查

| 问题 | 排查命令 | 常见原因 |
|------|---------|---------|
| 节点 NotReady（安装 CNI 后仍然） | `kubectl describe node master-node` | CNI 插件 Pod 未正常启动，检查网络/镜像 |
| Pod 一直 Pending | `kubectl describe pod <name>` | 未去除 Master taint（第 7 步），或资源不足 |
| kubelet 不断重启 | `journalctl -u kubelet -f` | swap 未关闭、cgroup 驱动不匹配 |
| kubeadm init 失败 | 查看 init 输出 | 端口被占用、容器运行时未启动、CPU < 2 |
| CoreDNS CrashLoopBackOff | `kubectl logs -n kube-system <coredns-pod>` | CNI 未安装或配置错误 |
| 镜像拉取超时 | `kubectl describe pod <name>` 看 Events | 网络问题，添加 `--image-repository` 参数 |
| kubeadm init 重试 | 先执行 `sudo kubeadm reset` | 上次 init 残留导致冲突 |
| curl NodePort 连接拒绝 | `kubectl get svc` 确认端口 | 防火墙未开放 30000-32767 端口范围 |

---

## 给新手的建议

1. **先学 Linux 基础**：了解 `vi/nano` 编辑、`systemctl`、`journalctl`、`ip addr` 等基本命令
2. **虚拟机练手**：先在 VirtualBox/VMware 里建一台 VM 练习，搞坏了可以快照回退
3. **逐步验收**：每个步骤的验收标准通过后再进入下一步，不要跳步
4. **网络问题提前解决**：国内环境提前配好镜像源，`kubeadm init` 时添加 `--image-repository=registry.aliyuncs.com/google_containers`
5. **保存日志**：每个步骤的输出建议保存，排错时可回溯
