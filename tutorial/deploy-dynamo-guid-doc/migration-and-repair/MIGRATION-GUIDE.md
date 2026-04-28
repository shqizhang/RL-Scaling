# K8s 数据目录迁移指南：从根分区迁移到 SSD

> **日期**：2026-04-08  
> **环境**：单节点 K8s (gpu14)，kubeadm 安装  
> **目标**：将 K8s 核心数据从 `/dev/sda2`（94% 已满）迁移到 `/dev/nvme0n1p1`（`/ssd`，13% 使用）
> **执行方式**：使用 root 用户直接执行（无需 sudo）

---

## 一、可行性分析

### 1.1 当前磁盘状态

| 分区 | 挂载点 | 总容量 | 已用 | 可用 | 使用率 |
|------|--------|--------|------|------|--------|
| `/dev/sda2` | `/` | ~916 GB | ~814 GB | ~55 GB | **94%** |
| `/dev/nvme0n1p1` | `/ssd` | ~3.6 TB | ~451 GB | ~3.0 TB | 13% |

**结论：完全可行。** `/ssd` 剩余空间充足，且 NVMe SSD 性能优于 SATA 盘，迁移后 K8s 的 I/O 性能也会提升。

### 1.2 需要迁移的目录

K8s 在根分区上有 3 个核心数据目录，它们是磁盘的主要消费者：

| 目录 | 用途 | 预估大小 | 迁移必要性 |
|------|------|---------|-----------|
| `/var/lib/containerd` | 容器镜像层、容器快照、元数据 | **数十~数百 GB**（最大消费者） | ✅ 必须 |
| `/var/lib/kubelet` | Pod volume mounts、Pod 日志、Secret 挂载、emptyDir 等 | 数 GB~数十 GB | ✅ 必须 |
| `/var/lib/etcd` | K8s 集群状态数据库（kubeadm 默认位置） | 数百 MB~数 GB | ✅ 推荐 |

> **提示**：可以先在服务器上确认实际占用：
> ```bash
> du -sh /var/lib/containerd /var/lib/kubelet /var/lib/etcd 2>/dev/null
> ```

### 1.3 迁移策略

**方案选择：rsync + 符号链接（symlink）**

| 方案 | 原理 | 优点 | 缺点 |
|------|------|------|------|
| **符号链接** ✅ | 将数据拷贝到 `/ssd`，原位置替换为 symlink 指向新位置 | 简单可靠，K8s/containerd 无需修改任何配置文件 | 需要停服务 |
| 修改配置文件 | 修改 containerd config / kubelet flag 指向新路径 | 不需要 symlink | 配置分散、容易遗漏、升级时可能被覆盖 |
| bind mount (fstab) | 在 fstab 中添加 bind mount 将新路径挂载到旧路径 | 透明 | 需要改 fstab，忘记更新可能导致开机失败 |

**选择 symlink 方案**的理由：
1. 对 K8s、containerd、etcd **零配置修改**——所有程序仍然看到相同路径，只是底层存储位置变了
2. 最安全、最易回滚——删除 symlink 恢复原目录即可
3. 社区广泛使用的标准做法

### 1.4 对其他用户 Docker 容器的影响分析（重要）

> **核心结论：Docker 镜像和数据不会丢失，但迁移期间 Docker 容器会短暂中断。**

#### 1.4.1 Docker 与 K8s containerd 的关系

在 gpu14 上，可能同时存在两个容器运行时：

| 组件 | 服务名 | 数据目录 | 用途 |
|------|--------|---------|------|
| **containerd** | `containerd.service` | `/var/lib/containerd` | K8s 的容器运行时（CRI） |
| **Docker** | `docker.service` | `/var/lib/docker` | 其他用户直接使用 `docker run` |

**关键事实：**
1. **Docker 底层也依赖 containerd。** 现代 Docker 架构：`docker CLI → dockerd → containerd → runc`
2. 但 Docker 可以使用自己内嵌的 containerd 实例，也可能复用系统的 containerd 服务，**取决于安装配置**
3. **我们只迁移 `/var/lib/containerd`，不碰 `/var/lib/docker`**

#### 1.4.2 三种可能的场景

| 场景 | Docker 与 containerd 关系 | 停止 containerd 的影响 | 处理方式 |
|------|--------------------------|----------------------|---------|
| **A: Docker 使用系统 containerd** | `docker.service` 依赖 `containerd.service` | ⚠️ Docker 容器全部暂停 | 迁移后重启 Docker，容器自动恢复 |
| **B: Docker 使用内嵌 containerd** | Docker 自带独立的 containerd 进程 | ✅ Docker 不受影响 | 无需额外操作 |
| **C: 仅安装了 containerd，无 Docker** | 服务器没有 dockerd | ✅ 不存在影响 | 无需额外操作 |

**如何判断你的服务器属于哪种场景？**

```bash
# 1. 检查 Docker 是否安装
which docker && docker --version

# 2. 检查 Docker 服务是否在运行
systemctl is-active docker

# 3. 检查 Docker 是否依赖系统 containerd
systemctl show docker | grep -i "requires\|after" | grep containerd
# 如果输出包含 containerd.service → 场景 A
# 如果无输出 → 场景 B

# 4. 查看 Docker 使用的 containerd socket
docker info 2>/dev/null | grep -i containerd
# 如果显示 /run/containerd/containerd.sock → 场景 A（使用系统 containerd）

# 5. 查看有多少 containerd 进程
ps aux | grep containerd | grep -v grep
# 如果只有 1 个 containerd 进程 → 场景 A
# 如果有 2 个（一个是 Docker 的） → 场景 B
```

#### 1.4.3 迁移期间对 Docker 用户的具体影响

| 阶段 | Docker 容器状态 | 持续时间 | 用户感知 |
|------|---------------|---------|---------|
| 停止 containerd 前 | 正常运行 | - | 无 |
| 停止 containerd 期间 | **暂停/冻结**（场景 A） | 5~15 分钟 | 容器内服务无响应 |
| rsync 拷贝数据 | 暂停 | 取决于数据量 | 同上 |
| 创建 symlink 后重启 containerd | **自动恢复** | ~10 秒 | 短暂不可用后恢复 |
| 重启 Docker 服务（如需要） | 恢复运行 | ~30 秒 | 完全恢复 |

**关键：Docker 容器有 restart policy。** 如果容器使用 `--restart=always` 或 `--restart=unless-stopped`，Docker 启动后会自动重启这些容器。

#### 1.4.4 迁移不会删除 Docker 镜像或数据

- ✅ **Docker 镜像** 存储在 `/var/lib/docker`，**不在迁移范围内**
- ✅ **Docker 容器** 的文件系统层在 `/var/lib/docker/overlay2`，**不被触碰**
- ✅ **Docker volumes** 在 `/var/lib/docker/volumes`，**安全**
- ✅ 迁移完成后 `docker images` 和 `docker ps -a` 的结果不变

#### 1.4.5 迁移后的共存架构

```
迁移后磁盘布局：

/dev/sda2 (根分区, ~916GB)
  └── /var/lib/docker/         ← 其他用户的 Docker 数据（未动）
  └── /var/lib/containerd      ← symlink → /ssd/k8s-data/containerd
  └── /var/lib/kubelet         ← symlink → /ssd/k8s-data/kubelet
  └── /var/lib/etcd            ← symlink → /ssd/k8s-data/etcd

/dev/nvme0n1p1 (/ssd, ~3.6TB NVMe)
  └── /ssd/k8s-data/
        ├── containerd/        ← K8s 容器镜像和运行时数据
        ├── kubelet/           ← K8s Pod volumes
        └── etcd/              ← K8s 集群状态
```

**这种共存是完全可行的：**
- K8s（通过 containerd）读写 `/var/lib/containerd` → 被 symlink 重定向到 SSD
- Docker 继续读写 `/var/lib/docker` → 仍在根分区，不受影响
- 两者的数据完全独立，互不干扰

#### 1.4.6 迁移前通知计划

> **建议在迁移前通知其他使用 Docker 的用户：**

```
通知模板：
────────────────────────────────────
[@所有用户] gpu14 服务器维护通知

时间：[日期] [时间]，预计中断 10~20 分钟
影响：
  - K8s 集群将重新部署（不影响 Docker 用户）
  - Docker 容器会有 ~10 分钟短暂中断
  - Docker 容器会在维护后自动恢复（需设置 restart policy）
  - Docker 镜像和数据不会丢失

建议：
  - 重要的长时间运行任务请在维护窗口前保存 checkpoint
  - 确认你的容器使用了 --restart=always 策略

如有问题请联系 [管理员]
────────────────────────────────────
```

---

## 二、前置准备

### 2.1 权限要求

| 操作 | 所需权限 | 说明 |
|------|---------|------|
| 停止/启动 kubelet、containerd | **root** | systemd 服务管理 |
| rsync 拷贝数据 | **root** | 保留文件权限和 ownership |
| 创建 symlink 替换 /var/lib 下目录 | **root** | /var/lib 是 root 所有 |
| 查看磁盘使用 | 普通用户 | df、du 命令 |

**结论：直接使用 root 用户登录服务器执行即可，无需 sudo。**

### 2.2 迁移前检查清单

```bash
# 1. 确认你是 root 用户
whoami
# 预期输出：root

# 2. 确认 /ssd 是独立挂载点且可写
df -h /ssd
touch /ssd/.test_write && rm /ssd/.test_write && echo "OK: /ssd is writable"

# 3. 确认 /ssd 开机自动挂载（fstab 中有条目）
grep -i nvme /etc/fstab
# 如果无输出，说明 /ssd 是手动挂载的——重启后会丢失！必须先加入 fstab

# 4. 查看当前数据大小
du -sh /var/lib/containerd /var/lib/kubelet /var/lib/etcd 2>/dev/null

# 5. 确认 /ssd 剩余空间足够
df -h /ssd

# 6. 确认 K8s 组件部署方式（kubeadm vs k3s）
ls /etc/kubernetes/manifests/  # kubeadm: 静态 Pod manifest
which kubelet                  # kubelet 二进制路径
systemctl status kubelet       # kubelet 服务状态
systemctl status containerd    # containerd 服务状态
```

### 2.3 是否需要先删除 Pod / 清理环境？

**建议但非必须。** 具体来说：

| 操作 | 建议 | 原因 |
|------|------|------|
| 删除 Failed/Error Pod | ✅ 强烈推荐 | 减少迁移数据量，清理无用镜像层 |
| 清理未使用的容器镜像 | ✅ 强烈推荐 | 节省大量空间和迁移时间 |
| 停止业务 Pod | ❌ 不需要手动做 | 脚本会停 kubelet，所有 Pod 自动停止 |
| 卸载 Helm release | ❌ 不需要 | K8s 状态在 etcd 中，迁移后恢复 |

**预清理命令（在迁移前执行，可显著减少迁移数据量）：**

```bash
# 1. 删除所有 Failed/Completed Pod（减少残留数据）
kubectl delete pods --field-selector=status.phase==Failed -A
kubectl delete pods --field-selector=status.phase==Succeeded -A

# 2. 清理未使用的容器镜像（⚠️ 这很重要，可能释放几十 GB）
crictl rmi --prune

# 3. 清理僵死容器
crictl rm $(crictl ps -a --state exited -q) 2>/dev/null

# 4. 再次确认清理效果
du -sh /var/lib/containerd
df -h /
```

---

## 三、Step-by-Step 迁移步骤

### Step 0：环境变量与目标路径

```bash
# 迁移目标基路径
export SSD_BASE="/ssd/k8s-data"

# 要迁移的三个目录
# /var/lib/containerd  →  /ssd/k8s-data/containerd
# /var/lib/kubelet     →  /ssd/k8s-data/kubelet
# /var/lib/etcd        →  /ssd/k8s-data/etcd
```

### Step 1：创建目标目录

```bash
mkdir -p ${SSD_BASE}
```

### Step 2：停止 kubelet（所有 Pod 会停止）

```bash
systemctl stop kubelet
# 验证
systemctl is-active kubelet
# 预期：inactive
```

> ⚠️ **此步之后集群不可用**，kubectl 命令会超时。这是正常的。

### Step 3：停止 containerd

```bash
systemctl stop containerd
# 验证
systemctl is-active containerd
# 预期：inactive
```

> ⚠️ 必须先停 kubelet 再停 containerd，否则 kubelet 会检测到 runtime 断连并持续报错。

### Step 4：使用 rsync 拷贝数据到 SSD

```bash
# containerd（最大，耗时最长）
rsync -aHAXxv --progress /var/lib/containerd/ ${SSD_BASE}/containerd/

# kubelet
rsync -aHAXxv --progress /var/lib/kubelet/ ${SSD_BASE}/kubelet/

# etcd（如果存在且由 kubeadm 管理）
if [ -d /var/lib/etcd ]; then
  rsync -aHAXxv --progress /var/lib/etcd/ ${SSD_BASE}/etcd/
fi
```

**rsync 参数说明：**
- `-a`：归档模式（保留权限、时间戳、符号链接等）
- `-H`：保留硬链接（containerd 的 overlay 层使用硬链接节省空间）
- `-A`：保留 ACL
- `-X`：保留 extended attributes
- `-x`：不跨文件系统（只拷贝本分区数据）
- `-v --progress`：显示进度

### Step 5：验证数据完整性

```bash
# 比较源和目标的大小（应接近一致）
echo "=== containerd ==="
du -sh /var/lib/containerd ${SSD_BASE}/containerd

echo "=== kubelet ==="
du -sh /var/lib/kubelet ${SSD_BASE}/kubelet

echo "=== etcd ==="
du -sh /var/lib/etcd ${SSD_BASE}/etcd 2>/dev/null
```

### Step 6：备份原目录并创建符号链接

```bash
# 备份原目录（重命名为 .bak）
mv /var/lib/containerd /var/lib/containerd.bak
mv /var/lib/kubelet /var/lib/kubelet.bak
if [ -d /var/lib/etcd ]; then
  mv /var/lib/etcd /var/lib/etcd.bak
fi

# 创建符号链接
ln -s ${SSD_BASE}/containerd /var/lib/containerd
ln -s ${SSD_BASE}/kubelet /var/lib/kubelet
if [ -d ${SSD_BASE}/etcd ]; then
  ln -s ${SSD_BASE}/etcd /var/lib/etcd
fi

# 验证符号链接
ls -la /var/lib/containerd /var/lib/kubelet /var/lib/etcd 2>/dev/null
# 预期：每个都显示 -> /ssd/k8s-data/xxx
```

### Step 7：启动 containerd

```bash
systemctl start containerd
# 等待启动
sleep 5
systemctl is-active containerd
# 预期：active

# 验证 containerd 能读取镜像
crictl images | head
```

### Step 8：启动 kubelet

```bash
systemctl start kubelet
# 等待 K8s 组件恢复（etcd → apiserver → controller-manager → scheduler）
sleep 30

# 验证
kubectl get nodes
# 预期：gpu14 Ready

kubectl get pods -n kube-system
# 预期：所有 kube-system Pod 为 Running
```

### Step 9：验证迁移成功

```bash
# 1. 根分区使用率应显著下降
df -h /
# 预期：Use% 从 94% 大幅下降

# 2. /ssd 使用量增加
df -h /ssd

# 3. K8s 集群正常
kubectl get nodes
kubectl get pods -A

# 4. 测试创建 Pod 验证写入是否正常
kubectl run test-nginx --image=nginx --restart=Never
sleep 10
kubectl get pod test-nginx
kubectl delete pod test-nginx
```

### Step 10：清理备份（确认一切正常后）

```bash
# ⚠️ 确认集群稳定运行 24 小时后再执行！
rm -rf /var/lib/containerd.bak
rm -rf /var/lib/kubelet.bak
rm -rf /var/lib/etcd.bak 2>/dev/null

# 验证根分区释放空间
df -h /
```

---

## 四、回滚方案（如果出问题）

如果迁移后集群无法启动，可以快速回滚：

```bash
# 1. 停止服务
systemctl stop kubelet
systemctl stop containerd

# 2. 删除符号链接
rm -f /var/lib/containerd /var/lib/kubelet /var/lib/etcd

# 3. 恢复原目录
mv /var/lib/containerd.bak /var/lib/containerd
mv /var/lib/kubelet.bak /var/lib/kubelet
mv /var/lib/etcd.bak /var/lib/etcd 2>/dev/null

# 4. 重启
systemctl start containerd
sleep 5
systemctl start kubelet
```

---

## 五、常见问题

### Q1：迁移后 containerd 报错 "failed to create snapshot"

**原因**：`/ssd` 的文件系统不支持某些特性（如 overlay 需要 d_type 支持）。  
**排查**：
```bash
# 检查 /ssd 文件系统类型
df -T /ssd
# 如果是 xfs，确认 ftype=1
xfs_info /ssd | grep ftype
# ftype=1 才支持 overlay，ftype=0 不支持
```

### Q2：迁移后 kubelet 报错 "cannot find volume"

**原因**：kubelet 的某些 volume 可能包含绝对路径引用。  
**解决**：重启相关 Pod 或重新部署。

### Q3：/ssd 重启后没有自动挂载

**非常危险！** 如果 `/ssd` 没有在 fstab 中配置，重启后 K8s 会尝试写入根分区的 symlink 指向的不存在的路径，导致完全无法启动。  
**确认 fstab**：
```bash
grep nvme /etc/fstab
# 必须有类似这行：
# /dev/nvme0n1p1  /ssd  ext4  defaults  0  2
```
如果没有，必须先添加才能执行迁移。

### Q4：rsync 耗时太久

containerd 目录可能很大（数百 GB）。可以先执行预清理（Step 2.3 中的 `crictl rmi --prune`），能显著减少数据量。

### Q5：迁移期间集群会中断多久？

主要取决于 rsync 拷贝时间。以 NVMe SSD 的写入速度（~2 GB/s），200 GB 数据大约 2-3 分钟。加上停止/启动服务的时间，总计约 **5-10 分钟**。

### Q6：其他用户的 Docker 容器会被删除吗？

**不会。** Docker 的所有数据（镜像、容器、volumes）存储在 `/var/lib/docker`，本次迁移只涉及 `/var/lib/containerd`、`/var/lib/kubelet`、`/var/lib/etcd`，完全不碰 Docker 的数据目录。迁移完成后 `docker images`、`docker ps -a` 结果不变。

### Q7：停止 containerd 会影响正在运行的 Docker 容器吗？

**取决于 Docker 是否依赖系统的 containerd 服务（详见 1.4.2 节三种场景）。**
- 如果 Docker 使用系统 containerd（场景 A）：Docker 容器会暂停，迁移后重启 containerd + Docker 服务即可恢复。
- 如果 Docker 使用内嵌 containerd（场景 B）：Docker 容器不受影响。

**迁移脚本已内置自动检测和处理逻辑**——会在停止 containerd 前检测 Docker 服务状态，迁移完成后自动重启 Docker 并验证容器恢复。

### Q8：迁移后 K8s 在 SSD、Docker 在根分区，会有冲突吗？

**不会。** K8s 通过 containerd CRI 使用 `/var/lib/containerd`（已 symlink 到 SSD），Docker 使用 `/var/lib/docker`（仍在根分区）。两者的数据完全独立，各自使用不同的存储引擎和 namespace，互不干扰。这是一种常见的共存架构。

### Q9：如果 Docker 也想迁移到 SSD 怎么办？

可以用同样的 symlink 方法迁移 `/var/lib/docker`。但建议分开操作：
```bash
# 先确认 Docker 数据大小
du -sh /var/lib/docker

# 如果需要迁移 Docker，在 K8s 迁移完成并验证后：
systemctl stop docker
rsync -aHAXx /var/lib/docker/ /ssd/docker-data/
mv /var/lib/docker /var/lib/docker.bak
ln -s /ssd/docker-data /var/lib/docker
systemctl start docker
docker ps  # 验证
```

---

## 六、迁移后的后续工作

1. **验证 Docker 服务恢复**（如果服务器有其他用户使用 Docker）：
   ```bash
   # 确认 Docker 服务正在运行
   systemctl is-active docker
   # 预期：active

   # 确认所有 Docker 容器恢复
   docker ps
   # 对比迁移前记录的容器列表

   # 如果有容器未自动恢复，手动启动
   docker start <container_name>

   # 通知其他用户验证他们的服务
   ```

2. **重新部署 Prometheus & Grafana**：根分区空间释放后，迁移不影响已有的 Helm release 状态，但之前异常的 Pod 需要重新部署（参考 `01-deploy-prometheus-grafana.sh`）

3. **重新部署 Dynamo**：同上（参考 `02-deploy-dynamo.sh`）

4. **配置 containerd 垃圾回收**（可选）：防止未来镜像再次堆积
   ```bash
   # 查看 containerd 配置
   cat /etc/containerd/config.toml | grep -A5 "gc"
   ```

5. **配置 kubelet 镜像回收**（可选）：
   ```bash
   # kubelet 默认在磁盘使用率 >85% 时自动清理镜像
   # 迁移到大容量 SSD 后此阈值基本不会触发
   ```

---

## 七、已知问题：SSD 迁移后 vllm Worker CrashLoopBackOff

> **发现日期**：2026-04-09  
> **影响范围**：所有在 SSD 迁移后重新部署的 Dynamo vllm Worker  
> **修复脚本**：`04-fix-worker-crashloop.sh`

### 7.1 症状

迁移完成并重新部署 Dynamo 后，观察到以下现象：

```
NAMESPACE                  NAME                                             READY   STATUS
dynamo-system vllm-v1-disagg-router-frontend-xxx              1/1     Running          ← 正常
dynamo-system vllm-v1-disagg-router-vllmdecodeworker-xxx     0/1     CrashLoopBackOff ← 异常
dynamo-system vllm-v1-disagg-router-vllmprefillworker-xxx    0/1     CrashLoopBackOff ← 异常
```

Worker Pod 日志包含以下关键错误：

```
cudaErrorInsufficientDriver: CUDA driver version is insufficient for CUDA runtime version
ImportError: libcuda.so.1: cannot open shared object file: No such file or directory
```

Frontend 正常运行而 Worker 崩溃，是因为 Frontend 仅作路由转发，启动时不调用 CUDA API；Worker 在启动时即执行 `torch.cuda.device_count()` 等 CUDA 初始化，无法访问驱动则立即崩溃。

### 7.2 根因分析与因果链（2026-04-10 更新）

> **重要更正**：初次排查（04-09）只识别到 `default_runtime_name` 被覆盖为 `runc`，但实际上有 **3 个配置项同时出问题**，缺一不可。

```
因果链（完整版）：

[00-migrate-k8s-to-ssd.sh 执行]
    │
    ├─ Step 3: systemctl stop containerd
    │
    ├─ Step 4: rsync 数据到 /ssd
    │
    ├─ Step 7: systemctl start containerd   ← ★ 触发配置覆写链 ★
    │       │
    │       ▼
    │   nvidia-container-toolkit-daemonset 检测到 containerd 重启
    │       │
    │       ├── 读取自身环境变量 NVIDIA_RUNTIME_SET_AS_DEFAULT
    │       │   （GPU Operator 默认值: false）
    │       │
    │       ├── 覆写 /etc/containerd/config.toml:
    │       │   → default_runtime_name = "runc"     ← ① 故障点
    │       │   → enable_cdi = false                ← ② 故障点
    │       │
    │       └── 再次重启 containerd
    │
    │   nvidia-device-plugin-daemonset 已运行 20 天，未感知变更
    │                                               ← ③ 故障点
    │
    └── [重新部署 DGD]
            ↓
        两条路都是死路：
        ├── 无 runtimeClassName → runc → libcuda.so.1 缺失
        └── 有 runtimeClassName: nvidia → 绕过 CDI → 8 卡全可见 → OOM
```

**3 个配置项缺一不可：**

| 配置项 | 正确值 | 故障值 | 影响 |
|--------|-------|--------|------|
| `defaultRuntimeName` | `nvidia` | `runc` | 无 runtimeClassName 的 Pod 用 runc → 没有 GPU |
| `enable_cdi` | `true` | `false` | CDI 设备隔离失效 → Pod 看到全部 8 张 GPU |
| device-plugin | 重启以感知 CDI | 20 天前启动 | CDI annotation 未注入 → Pod 无法获得正确的 GPU 隔离 |

**为什么 `runtimeClassName: nvidia` 不是正确的修复？**

`runtimeClassName: nvidia` 通过 RuntimeClass handler 走 nvidia runtime，容器确实有 GPU 驱动。但此路径**绕过了 CDI（Container Device Interface）设备隔离**，导致每个容器看到全部 8 张 GPU。两个 Worker 同时使用 `cuda:0`，24 GiB 显存不够两个模型共享，触发 CUDA OOM。

**containerd 运行时 × CDI 配置矩阵（实测）：**

| `runtimeClassName` | `defaultRuntime` | `enable_cdi` | 结果 |
|-------------------|-----------------|-------------|------|
| 不设 | runc | any | `libcuda.so.1` 缺失 → 崩溃 |
| nvidia | any | any | 8 张 GPU 全可见 → OOM |
| 不设 | nvidia | false | 8 张 GPU 全可见 → OOM |
| **不设** | **nvidia** | **true** | **1 张 GPU ✓ CDI 隔离正常** |

### 7.2.1 正确的修复方法（3 步缺一不可）

```bash
# ① 让 toolkit daemonset 把 nvidia 设为默认 runtime
kubectl set env daemonset/nvidia-container-toolkit-daemonset \
  -n gpu-operator \
  NVIDIA_RUNTIME_SET_AS_DEFAULT=true
kubectl rollout status ds/nvidia-container-toolkit-daemonset \
  -n gpu-operator --timeout=120s

# ② 在主 config.toml 中启用 CDI
sudo sed -i 's/enable_cdi = false/enable_cdi = true/' /etc/containerd/config.toml
sudo systemctl restart containerd

# ③ 重启 device plugin（使其重新注册 CDI 设备规格）
kubectl rollout restart daemonset/nvidia-device-plugin-daemonset -n gpu-operator
kubectl rollout status ds/nvidia-device-plugin-daemonset -n gpu-operator --timeout=120s
```

### 7.2.2 验证修复

```bash
# 验证 containerd 实际配置（不要 grep config.toml，要用 crictl）
sudo crictl info 2>/dev/null | python3 -c "
import json, sys
info = json.load(sys.stdin)
cfg = info.get('config', {})
crd = cfg.get('containerd', {})
print(f'defaultRuntimeName: {crd.get(\"defaultRuntimeName\", \"UNKNOWN\")}')
print(f'enableCDI: {cfg.get(\"enableCDI\", \"UNKNOWN\")}')"
# 期望: defaultRuntimeName: nvidia, enableCDI: True

# 验证 CDI 设备隔离（不带 runtimeClassName，请求 1 GPU）
kubectl run gpu-test --image=nvidia/cuda:12.0.0-base-ubuntu22.04 \
  --rm -it --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"gpu-test","image":"nvidia/cuda:12.0.0-base-ubuntu22.04","command":["nvidia-smi"],"resources":{"limits":{"nvidia.com/gpu":"1"}}}]}}' \
  -- nvidia-smi
# 期望: 只显示 1 张 RTX 3090
```

验证当前 containerd 默认 runtime 的方法：

```bash
# ⚠️ 不推荐: grep config.toml（toolkit drop-in 可能覆盖主配置）
grep default_runtime_name /etc/containerd/config.toml

# ✅ 推荐: crictl info 显示 containerd 实际生效的配置
sudo crictl info 2>/dev/null | python3 -c "
import json,sys; c=json.load(sys.stdin)['config']
print(c.get('containerd',{}).get('defaultRuntimeName','?'))"
```

### 7.3 为何迁移前不存在此问题

K8s 集群初次安装时，在某一次手动调试过程中，containerd 的 3 项 GPU 配置恰好处于正确状态：

1. `default_runtime_name = "nvidia"`（toolkit 的 env 可能被手动调过，或初次安装时恰好生效）
2. `enable_cdi = true`（可能通过 toolkit drop-in 配置或手动设置）
3. `nvidia-device-plugin-daemonset` 在配置正确后启动过

`dynamo-0.7.1.md` 中的原始部署指南正是在此环境下编写和测试的，DGD manifest 中不需要 `runtimeClassName` 字段也能工作。

**SSD 迁移破坏了这一隐式环境依赖：**
- 迁移脚本必须重启 containerd → toolkit daemonset 检测到重启 → 按默认 env 覆写 config.toml
- toolkit 默认 `NVIDIA_RUNTIME_SET_AS_DEFAULT=false` → `default_runtime_name` 回退为 `runc`
- toolkit 覆写不保留 `enable_cdi = true`
- device plugin 在 20 天前启动，未感知任何配置变更

### 7.4 修复方案

> ~~**旧方案（❌ 已废弃）：** 在 DGD manifest 中添加 `runtimeClassName: nvidia`。这会绕过 CDI 设备隔离，导致每个容器看到全部 8 张 GPU → OOM。~~

**正确方案：** 修复 containerd 的 3 项配置，然后 DGD manifest **不设** `runtimeClassName`，依赖 CDI 实现 GPU 隔离。

一键修复脚本：

```bash
# 04-fix-worker-crashloop.sh 已更新为正确的 3 步修复
bash recover-script/04-fix-worker-crashloop.sh
```

详见本文 7.2.1 节或 `DIAGNOSIS-AND-REPAIR.md` 第五节。
