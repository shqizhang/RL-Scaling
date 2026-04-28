# RL-Scaling Deployment

This folder is the entry point for deploying the **RL-Scaling-flavoured** Dynamo
to a Kubernetes cluster, i.e. the worker built from the
[`RL-Scaling` branch of the dynamo fork](https://github.com/shqizhang/dynamo/tree/RL-Scaling)
together with the [rl-scaling-controller](../../) shipped in this repo.

The intent is **maximum reuse, minimum surprise**: every base script comes
from the existing `tutorial/dynamo-auto-deploy/1.0.1/` flow. We only override
the image reference.

## What was added vs reused

| File | New / Reused | Purpose |
| ---- | ------------ | ------- |
| [build-dynamo-image.sh](build-dynamo-image.sh) | **NEW** | Render Dockerfile via `dynamo/container/render.py` and `docker build && docker push` to `ghcr.io/<you>/dynamo-vllm-runtime:rl-scaling-<sha>` |
| [deploy-dynamo.sh](deploy-dynamo.sh) | **NEW (thin wrapper)** | Copies the official `1.0.1/manifests/` into a temp dir, `sed`-rewrites the image registry, then `exec`s the original [01-deploy-dynamo-1.0.1.sh](../../tutorial/dynamo-auto-deploy/1.0.1/01-deploy-dynamo-1.0.1.sh) with `MANIFEST_DIR=<tmp>` |
| [deploy-all.sh](deploy-all.sh) | **NEW (thin wrapper)** | Calls [deploy-controller.sh](../deploy-controller.sh) then [deploy-dynamo.sh](deploy-dynamo.sh) |
| [../deploy-controller.sh](../deploy-controller.sh) | **REUSED** | Builds & deploys the rl-scaling-controller (unchanged) |
| [../../tutorial/dynamo-auto-deploy/1.0.1/01-deploy-dynamo-1.0.1.sh](../../tutorial/dynamo-auto-deploy/1.0.1/01-deploy-dynamo-1.0.1.sh) | **REUSED (1-line patch)** | Now honours `MANIFEST_DIR` env override; everything else identical |
| [../../tutorial/dynamo-auto-deploy/1.0.1/manifests/](../../tutorial/dynamo-auto-deploy/1.0.1/manifests/) | **REUSED** | All YAML templates are reused as-is; only the image base is sed-rewritten in a temp copy |
| [../../tutorial/dynamo-auto-deploy/k8s/deploy-Prometheus-Grafana.sh](../../tutorial/dynamo-auto-deploy/k8s/deploy-Prometheus-Grafana.sh) | **REUSED** | Pre-req. Run once per cluster |

So the only **persistent edits** to the tutorial flow are:
1. one line in `01-deploy-dynamo-1.0.1.sh` to allow `MANIFEST_DIR` override,
2. nothing else.

## End-to-end deployment

### 0. Pre-reqs (cluster level, one time)

```bash
# Prometheus / Grafana
GRAFANA_ADMIN_PASSWORD=<...> bash tutorial/dynamo-auto-deploy/k8s/deploy-Prometheus-Grafana.sh

# (Optional) drivers / k3s / GPU operator – see tutorial/dynamo-auto-deploy/k8s/install-k8s.sh
```

### 1. Build the custom dynamo image from the RL-Scaling branch

```bash
cd /path/to/RL-Scaling
DYNAMO_DIR=/path/to/dynamo \
REGISTRY=ghcr.io/<you> \
IMAGE_REPO=dynamo-vllm-runtime \
PUSH=true \
./deploy/RL-scaling/build-dynamo-image.sh
# → outputs IMAGE_TAG, e.g.  rl-scaling-abc1234
```

### 2. Build the controller image (reuse existing flow)

```bash
IMAGE=ghcr.io/<you>/rl-scaling-controller:rl-scaling-abc1234 \
PUSH=true \
./deploy/deploy-controller.sh   # also applies CRBs/Deploy
```

If you only want to **build** without deploying, comment out the
`kubectl apply` block at the bottom of `deploy-controller.sh`, or set
`KUBECONFIG=/dev/null` for that invocation.

### 3. Deploy everything

```bash
export CONTROLLER_IMAGE=ghcr.io/<you>/rl-scaling-controller:rl-scaling-abc1234
export DYNAMO_IMAGE_REGISTRY=ghcr.io/<you>
export DYNAMO_IMAGE_REPO=dynamo-vllm-runtime
export RELEASE_VERSION=rl-scaling-abc1234
export HF_TOKEN=<...>            # via secure channel
export NGC_API_KEY=<...>         # via secure channel
./deploy/RL-scaling/deploy-all.sh --router
```

The script will:
1. (Re-)apply controller RBAC + ConfigMap + Deployment
2. (Re-)install/upgrade `dynamo-platform` Helm release
3. Apply DGD/DGDSA with the **custom RL-Scaling worker image**
4. Apply ingress
5. Smoke-test the frontend

### 4. Verify

```bash
kubectl -n dynamo-system get pods
kubectl -n dynamo get deploy/rl-scaling-controller
kubectl -n dynamo-system describe dgd vllm-v1-disagg-router | grep -i image:
# Should show ghcr.io/<you>/dynamo-vllm-runtime:rl-scaling-abc1234
```

Then run the scenario E2E suite from the repo root:

```bash
CONTROLLER_URL=http://<svc-ip>:8080 ./test-scripts/run-all.sh e2e
```

## Upgrade / rollback flow

Pure tag swap; nothing else changes:

```bash
# upgrade
RELEASE_VERSION=rl-scaling-NEWSHA ./deploy/RL-scaling/deploy-dynamo.sh --router

# rollback
RELEASE_VERSION=rl-scaling-OLDSHA ./deploy/RL-scaling/deploy-dynamo.sh --router
```

Because the underlying script uses `helm upgrade --install`, both directions
are idempotent.

## Reuse-vs-new summary (for the "deployment guide" question)

* **Reuse** all of `tutorial/dynamo-auto-deploy/1.0.1/` for the platform
  install, secrets, DGD shape, monitoring and ingress.
* **Reuse** `deploy/deploy-controller.sh` (and its manifests) for the
  controller side.
* **Add** only thin wrappers that point those scripts at a different image.
* The single one-line patch in `01-deploy-dynamo-1.0.1.sh` makes the
  `MANIFEST_DIR` env var overridable so we don't have to fork the upstream
  manifests directory.
