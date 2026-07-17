# RL-Scaling 容器镜像构建说明

本文说明 `C:\projects\IP` 工作区里 RL-Scaling 项目相关容器镜像是如何构建、打 tag、推送和部署的。

这个项目不是单镜像结构。实际部署里有两条镜像链路：

1. `rl-scaling-controller`：RL-Scaling 控制面镜像，来自 `RL-Scaling/` 仓库。
2. `dynamo-vllm-runtime`：Dynamo worker/runtime 镜像，来自 `dynamo/` 仓库的 `RL-Scaling` 分支，包含 S2 PD role switch、S3 request consolidation、sidecar、migration 等 worker-side 实现。

## 1. 镜像与代码来源

| 镜像 | 代码仓库 | 主要内容 | 默认镜像名 |
| --- | --- | --- | --- |
| Controller | `C:\projects\IP\RL-Scaling` | `rl-signal-sdk`、`rl-scaling-controller`、FastAPI controller、K8s client/RBAC | `ghcr.io/shqizhang/rl-scaling-controller:<tag>` |
| Dynamo worker/runtime | `C:\projects\IP\dynamo` | Dynamo + vLLM runtime，以及 `components/src/dynamo/vllm/*` 里的 RL-Scaling worker-side 代码 | `ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-<sha>` |

判断一次部署是否真的包含最新修复时，必须同时确认这两类镜像：

- Controller 侧修改只需要重建 `rl-scaling-controller`。
- Worker-side 修改，例如 `dual_mode.py`、`migration.py`、`rl_scaling_sidecar.py`、`main.py`、`handlers.py`，必须重建并部署 `dynamo-vllm-runtime`。

## 2. Controller 镜像如何构建

Controller 镜像的 Dockerfile 在：

```text
C:\projects\IP\RL-Scaling\deploy\Dockerfile
```

构建逻辑：

1. 基础镜像是 `python:3.11-slim`。
2. 复制两个 Python 包：
   - `rl-signal-sdk`
   - `rl-scaling-controller`
3. 执行 editable install：
   - `pip install -e /app/rl-signal-sdk`
   - `pip install -e "/app/rl-scaling-controller[k8s]"`
4. 暴露 `8080`。
5. healthcheck 调用 `http://127.0.0.1:8080/api/v1/status`。
6. 启动命令是：

```bash
python -m rl_scaling_controller.main
```

### 2.1 CI 构建

CI workflow 在：

```text
C:\projects\IP\RL-Scaling\.github\workflows\ci.yml
```

触发条件：

- push 到 `main` 或 `RL-Scaling`
- PR 到 `main` 或 `RL-Scaling`
- tag `v*`
- 手工 `workflow_dispatch`

当 controller、sdk、deploy 或 tag 相关条件满足时，CI 会运行 `build-controller-image` job：

```yaml
docker/build-push-action@v6
context: .
file: deploy/Dockerfile
push: true
tags:
  ghcr.io/<owner>/rl-scaling-controller:<short-sha-or-version-tag>
  ghcr.io/<owner>/rl-scaling-controller:<full-sha>
```

因此常见 tag 形态是：

```text
ghcr.io/shqizhang/rl-scaling-controller:<short-sha>
ghcr.io/shqizhang/rl-scaling-controller:<full-sha>
ghcr.io/shqizhang/rl-scaling-controller:v0.x.y
```

### 2.2 本地构建

本地脚本在：

```text
C:\projects\IP\RL-Scaling\deploy\deploy-controller.sh
```

用法：

```bash
cd C:/projects/IP/RL-Scaling
IMAGE=ghcr.io/shqizhang/rl-scaling-controller:<tag> \
PUSH=true \
bash deploy/deploy-controller.sh
```

这个脚本会：

1. `docker build -f deploy/Dockerfile -t ${IMAGE} .`
2. 如果 `PUSH=true` 且 tag 不是 `:dev`，执行 `docker push ${IMAGE}`。
3. 应用 controller 的 RBAC、ConfigMap、Deployment、Service。
4. 等待 `deploy/rl-scaling-controller` rollout。
5. 在 pod 内调用 `/api/v1/status` 做 smoke test。

如果只想部署已经存在于 registry 的镜像，不想在本地 build，使用：

```text
C:\projects\IP\RL-Scaling\deploy\apply-controller.sh
```

用法：

```bash
cd C:/projects/IP/RL-Scaling
IMAGE=ghcr.io/shqizhang/rl-scaling-controller:<tag> \
NAMESPACE=dynamo \
bash deploy/apply-controller.sh
```

这个脚本只替换 Deployment 里的 controller image 并触发 rollout，不会执行 `docker build`。

## 3. Dynamo worker/runtime 镜像如何构建

Worker 镜像不是在 `RL-Scaling/` 仓库构建，而是在 `dynamo/` 仓库构建。

它使用 Dynamo 原生的 container render 流程：

```text
C:\projects\IP\dynamo\container\render.py
C:\projects\IP\dynamo\container\Dockerfile.template
C:\projects\IP\dynamo\container\templates\*.Dockerfile
```

RL-Scaling worker 镜像的本地脚本在：

```text
C:\projects\IP\dynamo\deploy\RL-Scaling\build-dynamo-image.sh
```

构建逻辑：

1. 确认当前在 `dynamo` checkout。
2. 读取当前 git short sha。
3. 默认生成 tag：

```text
rl-scaling-<short-sha>
```

4. 渲染 vLLM runtime Dockerfile：

```bash
python3 container/render.py \
  --framework vllm \
  --target runtime \
  --cuda-version 12.9 \
  --platform amd64 \
  --output-short-filename
```

5. 输出：

```text
container/rendered.Dockerfile
```

6. 构建镜像：

```bash
docker build \
  --platform linux/amd64 \
  -f container/rendered.Dockerfile \
  -t ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-<short-sha> \
  --label rl-scaling.branch=<branch> \
  --label rl-scaling.sha=<full-sha> \
  .
```

7. 如果 `PUSH=true`，推送到 GHCR。

### 3.1 CI 构建

Dynamo worker 镜像的 CI workflow 在：

```text
C:\projects\IP\dynamo\.github\workflows\rl-scaling-build.yml
```

触发条件：

- push 到 `dynamo` 仓库的 `RL-Scaling` 分支，并且修改路径命中：
  - `components/**`
  - `lib/**`
  - `container/**`
  - `Cargo.*`
  - `pyproject.toml`
  - `hatch_build.py`
  - `.github/workflows/rl-scaling-build.yml`
- `repository_dispatch`，event type 为 `rl-scaling-build`
- 手工 `workflow_dispatch`

CI 会：

1. checkout `RL-Scaling` 分支。
2. 清理 GitHub runner 磁盘空间。
3. setup buildx 并登录 GHCR。
4. 渲染 `container/rendered.Dockerfile`。
5. 使用 `docker/build-push-action@v6` 构建并推送：

```text
ghcr.io/<owner>/dynamo-vllm-runtime:rl-scaling-<short-sha>
ghcr.io/<owner>/dynamo-vllm-runtime:rl-scaling-latest
```

6. 给镜像打 metadata label：

```text
rl-scaling.branch=RL-Scaling
rl-scaling.sha=<github.sha>
```

7. 如果不是由 `repository_dispatch` 触发，还会通知 `RL-Scaling` 仓库：

```text
repository_dispatch event-type=dynamo-image-ready
```

### 3.2 本地构建

本地构建命令：

```bash
cd C:/projects/IP/dynamo
REGISTRY=ghcr.io/shqizhang \
IMAGE_REPO=dynamo-vllm-runtime \
PUSH=true \
bash deploy/RL-Scaling/build-dynamo-image.sh
```

可选环境变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `REGISTRY` | `ghcr.io/shqizhang` | 镜像 registry/owner |
| `IMAGE_REPO` | `dynamo-vllm-runtime` | 镜像 repo 名 |
| `IMAGE_TAG` | `rl-scaling-<short-sha>` | 指定 tag |
| `FRAMEWORK` | `vllm` | Dynamo runtime framework |
| `TARGET` | `runtime` | Docker build target |
| `CUDA_VERSION` | `12.9` | CUDA 版本 |
| `PLATFORM` | `amd64` | 架构 |
| `PUSH` | `false` | 是否推送 |

示例：只构建不推送：

```bash
cd C:/projects/IP/dynamo
PUSH=false bash deploy/RL-Scaling/build-dynamo-image.sh
```

示例：指定 tag 并推送：

```bash
cd C:/projects/IP/dynamo
REGISTRY=ghcr.io/shqizhang \
IMAGE_REPO=dynamo-vllm-runtime \
IMAGE_TAG=rl-scaling-myfix \
PUSH=true \
bash deploy/RL-Scaling/build-dynamo-image.sh
```

## 4. RL-Scaling 仓库如何触发 Dynamo 镜像构建

`RL-Scaling/.github/workflows/ci.yml` 里有一个 `trigger-dynamo-build` job。

它不会在每次 controller 改动时自动构建 worker 镜像，因为 worker 镜像很大、构建时间长。

它只在下面条件触发：

1. push commit message 包含：

```text
[dynamo-build]
```

2. 或者 push `v*` tag。

触发后，它通过 GitHub `repository_dispatch` 调用：

```text
repository: shqizhang/dynamo
event-type: rl-scaling-build
```

这个跨仓库触发需要 `RL-Scaling` 仓库里配置 secret：

```text
DYNAMO_DISPATCH_TOKEN
```

该 token 需要能触发 `shqizhang/dynamo` 的 workflow。

## 5. 部署时如何引用这些镜像

### 5.1 Controller 部署

Controller Deployment manifest 在：

```text
C:\projects\IP\RL-Scaling\deploy\manifests\03-deployment.yaml
```

默认 image 是：

```text
ghcr.io/shqizhang/rl-scaling-controller:dev
```

部署脚本会把它替换成 `IMAGE` 环境变量。

```bash
cd C:/projects/IP/RL-Scaling
IMAGE=ghcr.io/shqizhang/rl-scaling-controller:<tag> \
bash deploy/apply-controller.sh
```

### 5.2 Dynamo worker 部署

Worker 部署脚本在：

```text
C:\projects\IP\dynamo\deploy\RL-Scaling\deploy-dynamo.sh
```

它复用 `RL-Scaling/tutorial/dynamo-auto-deploy/1.0.1/` 下的原始部署流程，但会临时复制 manifests 并把 runtime image 从：

```text
nvcr.io/nvidia/ai-dynamo/vllm-runtime
```

替换为：

```text
${DYNAMO_IMAGE_REGISTRY}/${DYNAMO_IMAGE_REPO}:${RELEASE_VERSION}
```

部署命令示例：

```bash
cd C:/projects/IP/dynamo
RL_SCALING_REPO=C:/projects/IP/RL-Scaling \
DYNAMO_IMAGE_REGISTRY=ghcr.io/shqizhang \
DYNAMO_IMAGE_REPO=dynamo-vllm-runtime \
RELEASE_VERSION=rl-scaling-<short-sha> \
HF_TOKEN=<hf-token> \
NGC_API_KEY=<ngc-api-key> \
bash deploy/RL-Scaling/deploy-dynamo.sh --router
```

如果 GHCR package 是 private，还需要：

```bash
GHCR_USERNAME=<github-user>
GHCR_PAT=<token-with-read-packages>
```

脚本会创建 `ghcr-imagepullsecret` 并把它注入 DGD manifests。

### 5.3 一次性部署 controller + worker

组合脚本在：

```text
C:\projects\IP\dynamo\deploy\RL-Scaling\deploy-all.sh
```

示例：

```bash
cd C:/projects/IP/dynamo
RL_SCALING_REPO=C:/projects/IP/RL-Scaling \
CONTROLLER_IMAGE=ghcr.io/shqizhang/rl-scaling-controller:<controller-tag> \
DYNAMO_IMAGE_REGISTRY=ghcr.io/shqizhang \
DYNAMO_IMAGE_REPO=dynamo-vllm-runtime \
RELEASE_VERSION=rl-scaling-<worker-sha> \
HF_TOKEN=<hf-token> \
NGC_API_KEY=<ngc-api-key> \
bash deploy/RL-Scaling/deploy-all.sh --router
```

注意：当前 `deploy-all.sh` 默认调用 `RL-Scaling/deploy/deploy-controller.sh`，也就是会尝试本地 build controller。若部署机器磁盘紧张，建议改用 `RL-Scaling/deploy/apply-controller.sh` 或先单独执行 apply-only controller 部署。

## 6. 验证当前集群实际运行的镜像

Controller：

```bash
kubectl -n dynamo get deploy rl-scaling-controller \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Dynamo workers：

```bash
kubectl -n dynamo-system get pods \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.name}={.image}{" "}{end}{"\n"}{end}'
```

DGD 中声明的 worker image：

```bash
kubectl -n dynamo-system get dgd vllm-v1-disagg-router \
  -o jsonpath='{.spec.services.VllmDecodeWorker.extraPodSpec.mainContainer.image}{"\n"}'
```

如果测试里出现“代码已修复但行为还是旧的”，优先检查：

1. 改的是 controller 代码还是 Dynamo worker-side 代码。
2. 对应镜像是否真的 rebuild。
3. Deployment/DGD 是否真的引用了新 tag。
4. Pod 是否 rollout 到新镜像。
5. 是否还存在旧 DGD/DGDSA 或旧 worker pod。
6. 是否用了 ConfigMap overlay 临时覆盖了镜像内代码。

## 7. 常见误区

### 7.1 只重建 controller 不能更新 worker-side 行为

S2/S3 的核心 worker-side 逻辑在 `dynamo/` 仓库：

```text
dynamo/components/src/dynamo/vllm/dual_mode.py
dynamo/components/src/dynamo/vllm/migration.py
dynamo/components/src/dynamo/vllm/rl_scaling_sidecar.py
dynamo/components/src/dynamo/vllm/main.py
dynamo/components/src/dynamo/vllm/handlers.py
```

这些文件改动后，必须重建 `dynamo-vllm-runtime`，只部署新的 `rl-scaling-controller` 不会生效。

### 7.2 `rl-scaling-latest` 方便但不适合做测试证据

`rl-scaling-latest` 是 moving tag。正式测试报告最好记录不可变 tag：

```text
ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-<short-sha>
ghcr.io/shqizhang/rl-scaling-controller:<short-sha-or-full-sha>
```

### 7.3 ConfigMap overlay 只能用于临时验证

如果线上 pod 通过 ConfigMap mount 覆盖了 `main.py`、`dual_mode.py` 等文件，那么测试结果验证的是“镜像 + overlay”的组合，不是纯镜像本身。

正式复测前应确认：

```bash
kubectl -n dynamo-system describe deploy <worker-deployment>
```

并检查是否存在额外 volume mount 覆盖 Python 源码。

## 8. 推荐的标准流程

当修改 controller：

1. 在 `RL-Scaling/` 提交代码。
2. 运行单元测试。
3. 构建并推送 `rl-scaling-controller:<sha>`。
4. 用 `apply-controller.sh` 部署新 controller。
5. 验证 `/api/v1/status`。

当修改 worker-side S2/S3：

1. 在 `dynamo/` 的 `RL-Scaling` 分支提交代码。
2. 触发 `dynamo/.github/workflows/rl-scaling-build.yml`，或本地运行 `build-dynamo-image.sh`。
3. 得到 `dynamo-vllm-runtime:rl-scaling-<sha>`。
4. 用 `deploy-dynamo.sh --router` 部署新 worker image。
5. 验证 DGD/DGDSA、worker pod image、sidecar `/v1/role`。
6. 再运行 baseline/S2/S3/mixed 等测试。

当两边都改：

1. 分别构建 controller image 和 worker image。
2. 记录两个不可变 tag。
3. 先部署 controller，再部署 Dynamo worker stack。
4. 确认没有旧 DGD/DGDSA、旧 worker pod、旧 overlay。
5. 再执行测试。
