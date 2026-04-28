# RL-Scaling — CI/CD Guide

This document describes how the RL-Scaling repo and the
[dynamo fork](https://github.com/shqizhang/dynamo) cooperate to deliver
new component images and roll them out to a Kubernetes cluster
automatically. It complements [TEST_STRATEGY.md](TEST_STRATEGY.md) and
[deploy/RL-scaling/README.md](deploy/RL-scaling/README.md).

---

## 1. Pipeline overview

```
┌─────────────────────────────────────────────────────────┐
│                 RL-Scaling repo (this)                  │
│  push / PR ─►  CI workflow (.github/workflows/ci.yml)   │
│                  ├── changes filter (paths-filter)      │
│                  ├── unit-tests (controller + sdk)      │
│                  ├── build-controller-image  (ghcr.io)  │
│                  ├── trigger-dynamo-build    (opt-in)   │
│                  └── e2e (self-hosted GPU runner)       │
└──────────────┬──────────────────────────────────────────┘
               │ repository_dispatch  event=rl-scaling-build
               ▼
┌─────────────────────────────────────────────────────────┐
│                    dynamo fork                          │
│  push to RL-Scaling, dispatch, or manual                │
│  ─►  RL-Scaling-Build workflow                          │
│       (.github/workflows/rl-scaling-build.yml)          │
│       ├── render Dockerfile (vllm/runtime/cuda12.9)     │
│       ├── docker build & push to ghcr.io                │
│       │     dynamo-vllm-runtime:rl-scaling-<sha>        │
│       └── repository_dispatch back to RL-Scaling        │
│            event=dynamo-image-ready                     │
└──────────────┬──────────────────────────────────────────┘
               │ image is ready
               ▼
┌─────────────────────────────────────────────────────────┐
│        Cluster operator (manual or future CD job)       │
│  ./deploy/RL-scaling/deploy-all.sh --router             │
│   → controller + dynamo platform + DGD with new image   │
└─────────────────────────────────────────────────────────┘
```

The two halves are deliberately decoupled because the dynamo image build is
expensive (~25 GB / 30 min on a default runner). Only opt-in triggers
launch it.

---

## 2. What gets rebuilt when

| Change in… | Unit tests | Controller image | Dynamo image | E2E |
| ---------- | :--------: | :--------------: | :----------: | :-: |
| `rl-signal-sdk/**` | ✅ | ✅ | – | on `main` |
| `rl-scaling-controller/**` | ✅ | ✅ | – | on `main` |
| `deploy/**`, `test-scripts/**` | – | ✅ | – | on `main` |
| `*.md` only | – | – | – | – |
| `.github/workflows/**` | ✅ | ✅ | – | on `main` |
| Dynamo `components/**`, `lib/**`, `container/**` | – | – | ✅ (auto on push to `RL-Scaling`) | – |
| Push tag `v*` (this repo) | ✅ | ✅ tagged | ✅ via dispatch | – |
| Commit message contains `[dynamo-build]` | – | – | ✅ via dispatch | – |

The change-classifier lives in
[ci.yml](.github/workflows/ci.yml) and uses
[`dorny/paths-filter`](https://github.com/dorny/paths-filter).

---

## 3. Required secrets

Both repos publish to GHCR using the default `GITHUB_TOKEN`, so the only
**extra** secrets are for cross-repo dispatch:

| Repo | Secret | Scope | Used by |
| ---- | ------ | ----- | ------- |
| `RL-Scaling` | `DYNAMO_DISPATCH_TOKEN` | PAT with `repo` + `workflow` on the dynamo fork | `trigger-dynamo-build` job |
| `dynamo` (fork) | `CONTROLLER_DISPATCH_TOKEN` | PAT with `repo` + `workflow` on RL-Scaling | "Notify controller repo" step |

A single fine-grained PAT scoped to those two repos with the above two
permissions is sufficient.

For the **E2E job** (which deploys to a real cluster) the self-hosted GPU
runner must already have:
* `kubectl` configured against the target cluster (env `KUBECONFIG`)
* permission to pull `ghcr.io/<owner>/rl-scaling-controller:*`

---

## 4. End-to-end change flow (worked example)

Suppose you fix a bug in `rl_scaling_controller/role_switch/strategy.py`
and want it live in the cluster.

1. **Commit & push** to `main` (or open a PR):
   ```bash
   git add rl-scaling-controller
   git commit -m "shengqi : fix least-loaded selection in S2 strategy"
   git push origin main
   ```
2. **CI runs automatically:**
   * `changes.controller=true` → `unit-tests` runs
   * `unit-tests` green → `build-controller-image` builds & pushes
     `ghcr.io/<you>/rl-scaling-controller:<short-sha>`
   * `e2e` (only on `main`) port-forwards & runs `test-s1.sh`
3. **Operator deploys** the new image:
   ```bash
   CONTROLLER_IMAGE=ghcr.io/<you>/rl-scaling-controller:<short-sha> \
   DYNAMO_IMAGE_REGISTRY=ghcr.io/<you> \
   DYNAMO_IMAGE_REPO=dynamo-vllm-runtime \
   RELEASE_VERSION=rl-scaling-latest \
   ./deploy/RL-scaling/deploy-all.sh --router
   ```

Now the same flow but you also changed the dynamo worker:

1. Push to **dynamo** `RL-Scaling` branch — the
   `RL-Scaling-Build` workflow auto-triggers, builds the image, and emits
   a `dynamo-image-ready` dispatch back to this repo.
2. Push to **RL-Scaling** `main` with `[dynamo-build]` in the message if
   you want to force-rebuild the worker image without changing dynamo.

---

## 5. Promoting to a stable tag

1. Cut a release tag in this repo: `git tag v0.2.0 && git push origin v0.2.0`
2. The CI workflow:
   * builds & pushes `rl-scaling-controller:v0.2.0`
   * fires the `repository_dispatch` to dynamo (because of the tag)
3. The dynamo workflow builds & pushes
   `dynamo-vllm-runtime:rl-scaling-<sha>` and pings back.
4. Operator pins both tags in `deploy-all.sh` for the production cluster.

---

## 6. Local equivalents

The CI does nothing the local scripts can't:

| CI job | Local equivalent |
| ------ | ---------------- |
| `unit-tests` | `python -m pytest rl-signal-sdk rl-scaling-controller -q` |
| `build-controller-image` | `IMAGE=… PUSH=true bash deploy/deploy-controller.sh` |
| `RL-Scaling-Build` (dynamo) | `bash deploy/RL-scaling/build-dynamo-image.sh` |
| `e2e` | `bash test-scripts/run-all.sh e2e` |

This means anyone with the right secrets can reproduce a failing CI run
locally with the same commands — no hidden CI magic.

---

## 7. Adding a continuous-deployment job (future work, not enabled by default)

The `e2e` job already shows the "build → kubectl apply → smoke" pattern.
To turn it into real CD against a long-lived cluster, add a workflow gated
on `workflow_run` of `CI` succeeding on `main`:

```yaml
on:
  workflow_run:
    workflows: ["CI"]
    types: [completed]
    branches: [main]
jobs:
  cd:
    if: ${{ github.event.workflow_run.conclusion == 'success' }}
    runs-on: [self-hosted, prod-cluster]
    steps:
      - uses: actions/checkout@v4
      - run: |
          export CONTROLLER_IMAGE=ghcr.io/${{ github.repository_owner }}/rl-scaling-controller:${{ github.event.workflow_run.head_sha }}
          export DYNAMO_IMAGE_REGISTRY=ghcr.io/${{ github.repository_owner }}
          export DYNAMO_IMAGE_REPO=dynamo-vllm-runtime
          export RELEASE_VERSION=rl-scaling-latest
          ./deploy/RL-scaling/deploy-all.sh --router
```

Until that's enabled, deployment stays manual on purpose — to avoid
accidentally rolling a half-baked controller into a production cluster.
