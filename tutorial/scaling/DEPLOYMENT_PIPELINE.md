# RL-Scaling Deployment Pipeline — Operations Summary

> **Date**: 2026-04-30  
> **Author**: Shengqi Zhang  
> **Scope**: End-to-end CI/CD for the RL-Scaling project, covering both
> repositories (`shqizhang/RL-Scaling`, `shqizhang/dynamo` fork at tag
> baseline `v1.0.1`), the GHCR image registry layout, and the rollout
> strategy for the single-node K8s cluster (`gpu14`).

This document is the *operator-facing* counterpart to:
- [CICD.md](../CICD.md) — pipeline design rationale
- [tutorial/scaling/RL_Scaling_Unified_Design.md](../tutorial/scaling/RL_Scaling_Unified_Design.md) — full technical design (S1/S2/S3, KV-cache invariants)
- [RL_SCALING_RUST_CHANGES.md](../../dynamo/RL_SCALING_RUST_CHANGES.md) (in dynamo fork) — pending Rust-side changes for full S2/S3

---

## 1. What was deployed

| Component | Repo | Branch | Image | Cluster object |
| --------- | ---- | ------ | ----- | -------------- |
| `rl-scaling-controller` | `shqizhang/RL-Scaling` | `RL-Scaling` | `ghcr.io/shqizhang/rl-scaling-controller:<sha>` | `Deployment dynamo/rl-scaling-controller` (1 replica) |
| `dynamo-vllm-runtime` (worker, includes S2 `dual_mode.py` + S3 `migration.py`) | `shqizhang/dynamo` (fork) | `RL-Scaling` (HEAD `07117d49`) | `ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-<sha>` and `:rl-scaling-latest` | `DynamoGraphDeployment` + `DGDSA` (rolled out by `deploy/RL-Scaling/deploy-dynamo.sh --router` in the dynamo repo) |
| `rl-signal-sdk` | `shqizhang/RL-Scaling` | `main` / `RL-Scaling` | not deployed — `pip install -e ./rl-signal-sdk` from the RL training framework | n/a |

Cluster context: `kubernetes-admin@kubernetes`, single node `gpu14` (control-plane + worker, RTX 3090). Namespaces in use: `dynamo` (controller), `dynamo-system` (Dynamo operator + workers).

---

## 2. CI/CD pipeline overview

Two coupled workflows, one per repository, decoupled at runtime via
`repository_dispatch` so the expensive worker-image build does not run on
every controller-only change.

```
shqizhang/RL-Scaling                     shqizhang/dynamo (fork)
─────────────────────                    ────────────────────────
.github/workflows/ci.yml                 .github/workflows/rl-scaling-build.yml
                                                                                            
push / PR  ──►  changes (dorny/paths-filter)
                  │
                  ├─►  unit-tests             (pytest, 78 tests)
                  │
                  ├─►  build-controller-image (GHCR push)
                  │
                  ├─►  trigger-dynamo-build ─repository_dispatch─►  build (RL-Scaling-Build)
                  │   (only when commit msg contains [dynamo-build]                ├─ render Dockerfile
                  │    or a v* tag is pushed; runs even on PR for tags)            ├─ docker build & push
                  │                                                                │     ghcr.io/.../dynamo-vllm-runtime:rl-scaling-<sha>
                  └─►  e2e (gated to push-on-main, self-hosted GPU runner)         │     ghcr.io/.../dynamo-vllm-runtime:rl-scaling-latest
                                                                                   └─ repository_dispatch back ──► (future) auto-deploy
```

### 2.1 Triggers

| Workflow | Triggers |
| -------- | -------- |
| `RL-Scaling/ci.yml` | `push` to `main` or `RL-Scaling`, `pull_request` to those branches, `tags: v*`, `workflow_dispatch` |
| `dynamo/rl-scaling-build.yml` | `push` to `RL-Scaling` (path-filtered to `components/`, `lib/`, `container/`, `Cargo.*`, `pyproject.toml`, `hatch_build.py`, the workflow itself), `repository_dispatch` event `rl-scaling-build`, `workflow_dispatch` |

### 2.2 Job conditions (after the 2026-04-30 fix)

`unit-tests` runs when:
- `workflow_dispatch` (manual override), **or**
- `controller`/`sdk`/`ci` paths changed.

`build-controller-image` runs when `unit-tests` succeeds **and**:
- `workflow_dispatch`, **or**
- `controller`/`sdk`/`deploy` paths changed, **or**
- a `v*` tag was pushed.

`trigger-dynamo-build` runs only when the commit message contains
`[dynamo-build]` or a `v*` tag is pushed (cost gate).

`e2e` runs only on `push` to `main` (self-hosted GPU runner).

### 2.3 Runner choice

Both workflows run on **`ubuntu-latest`** (free GitHub-hosted runner).
The dynamo image build uses the `jlumbroso/free-disk-space@v1.3.1`
action to free ~30 GB of pre-installed tooling so the ~25 GB rendered
vllm runtime image fits. **Larger runners (`ubuntu-latest-16-cores`)
are not available on personal forks** — using them caused the previous
runs to wait 24 h and time out.

### 2.4 Required secrets

| Repo | Secret | Purpose |
| ---- | ------ | ------- |
| `RL-Scaling` | `DYNAMO_DISPATCH_TOKEN` | PAT (`repo` + `workflow` on `shqizhang/dynamo`) for the cross-repo dispatch step |
| `dynamo` (fork) | `CONTROLLER_DISPATCH_TOKEN` | PAT for the back-dispatch to `RL-Scaling` |
| both | `GITHUB_TOKEN` | Built-in; used to push to GHCR (`packages: write` permission) |

A single fine-grained PAT scoped to the two repos with `repo` + `workflow`
covers both cross-repo dispatches.

---

## 3. Image registry layout (GHCR)

All images are published to **`ghcr.io/shqizhang/`** (GitHub Container Registry under the user's namespace).

```
ghcr.io/shqizhang/
├── rl-scaling-controller
│     ├── :<short-sha>           # one per push to main/RL-Scaling
│     ├── :<full-sha>            # one per push (immutable)
│     └── :v0.x.y                # one per release tag
└── dynamo-vllm-runtime
      ├── :rl-scaling-<short-sha> # one per push that touches runtime paths
      └── :rl-scaling-latest      # moving tag, latest successful build
```

Image labels carried in metadata (set by `docker/build-push-action@v6` `labels:`):
- `rl-scaling.branch=RL-Scaling`
- `rl-scaling.sha=<github.sha>`

### 3.1 Visibility

The packages default to **private** when first published. To allow the
cluster to pull without an image-pull-secret, change visibility to
**public** in `https://github.com/users/shqizhang/packages/container/<name>/settings`.
Otherwise, create a `ghcr-imagepullsecret` in the target namespace and
reference it from the `DGD` template — the `deploy-dynamo.sh` script
already wires this up if `GHCR_USERNAME` and `GHCR_PAT` env vars are set.

---

## 4. Deployment strategy

### 4.1 Controller (registry-pull only — disk-constrained host)

Because the operator host (`gpu14`) is at 98 % disk usage, the original
`deploy-controller.sh` (which always runs `docker build`) cannot be used
locally. Use **`deploy/apply-controller.sh`** instead — it pulls the
image from GHCR and applies the manifests:

```bash
IMAGE=ghcr.io/shqizhang/rl-scaling-controller:<sha> \
NAMESPACE=dynamo \
./deploy/apply-controller.sh
```

The script:
1. ensures namespace `dynamo`,
2. applies `manifests/01-rbac.yaml` and `02-configmap.yaml`,
3. `sed`-rewrites the `image:` line of `03-deployment.yaml` and applies it,
4. `kubectl rollout restart` (so re-applying the same manifest still pulls the new image),
5. waits for rollout (timeout 5 min),
6. prints status.

**Smoke test** (after deploy):
```bash
kubectl -n dynamo exec deploy/rl-scaling-controller -- \
    python -c "import urllib.request,json;print(json.dumps(json.load(urllib.request.urlopen('http://127.0.0.1:8080/api/v1/status',timeout=3))))"
# Expected: {"state": "idle", "current_target": null, "history": []}
```

The controller is a **single-writer** by design (`replicas: 1`,
`strategy: Recreate`). Do not scale > 1.

### 4.2 Dynamo backend (prefill + decode workers)

Once the dynamo CI run for `RL-Scaling` HEAD has produced
`ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-<sha>`, deploy the
DGD + DGDSA from the **dynamo** repo:

```bash
cd /home/shengqizhang/IP/dynamo
RL_SCALING_REPO=/home/shengqizhang/IP/RL-Scaling \
DYNAMO_IMAGE_REGISTRY=ghcr.io/shqizhang \
DYNAMO_IMAGE_REPO=dynamo-vllm-runtime \
RELEASE_VERSION=rl-scaling-<sha> \
HF_TOKEN=... NGC_API_KEY=... \
./deploy/RL-Scaling/deploy-dynamo.sh --router
```

What that wrapper does:
1. Locates the upstream 1.0.1 deployer + manifests under
   `RL-Scaling/tutorial/dynamo-auto-deploy/1.0.1/`.
2. Copies the manifests to a tempdir and `sed`-rewrites the runtime image
   from `nvcr.io/nvidia/ai-dynamo/vllm-runtime` to
   `${DYNAMO_IMAGE_REGISTRY}/${DYNAMO_IMAGE_REPO}`.
3. Optionally creates `ghcr-imagepullsecret` (when `GHCR_USERNAME` /
   `GHCR_PAT` are set) and injects it next to `nvcr-imagepullsecret`.
4. Invokes the upstream deployer with `MANIFEST_DIR=` and
   `RELEASE_VERSION=` env vars so the renderer (`envsubst`) substitutes
   the new tag everywhere.

### 4.3 Combined orchestrator

```bash
cd /home/shengqizhang/IP/RL-Scaling
CONTROLLER_IMAGE=ghcr.io/shqizhang/rl-scaling-controller:<sha> \
DYNAMO_IMAGE_REGISTRY=ghcr.io/shqizhang \
DYNAMO_IMAGE_REPO=dynamo-vllm-runtime \
RELEASE_VERSION=rl-scaling-<sha> \
./deploy/deploy-all.sh --router
```

This composes the two steps above. (Note: the current `deploy-all.sh`
calls the *build*-then-apply flavour; on disk-constrained hosts replace
the `deploy-controller.sh` invocation inside it with
`apply-controller.sh`.)

### 4.4 Rollback

* Controller: `kubectl -n dynamo set image deploy/rl-scaling-controller controller=ghcr.io/shqizhang/rl-scaling-controller:<previous-sha>`.
* Dynamo backend: re-run `deploy-dynamo.sh` with the previous
  `RELEASE_VERSION=rl-scaling-<previous-sha>` — the upstream deployer is
  idempotent and rolls the DGD with the older image.

### 4.5 Resource policy

| Pod | Requests | Limits | Notes |
| --- | -------- | ------ | ----- |
| `rl-scaling-controller` | 100 m CPU / 128 Mi | 500 m CPU / 512 Mi | CPU-only, single replica |
| Prefill worker | 1 GPU | 1 GPU | DGDSA `spec.replicas` driven by controller |
| Decode worker | 1 GPU | 1 GPU | DGDSA `spec.replicas` driven by controller |

---

## 5. Code-correctness review (2026-04-30)

### 5.1 dynamo fork — RL-Scaling-only files

| File | Verdict | Notes |
| ---- | ------- | ----- |
| `components/src/dynamo/vllm/dual_mode.py` (S2) | OK | Reuses existing `BaseWorkerHandler.sleep`/`wake_up`, per-worker `asyncio.Lock` for idempotency, attempts wake on failure. NIXL/KV-pool reconfig + `WorkerRoleChanged` emission are explicit no-op stubs (documented in `RL_SCALING_RUST_CHANGES.md`). |
| `components/src/dynamo/vllm/migration.py` (S3) | OK | Recompute-prefill fallback (no NIXL D2D). Engine-agnostic via `RequestTracker` Protocol; `migrate_out` aborts in-engine, `migrate_in` re-submits prompt + generated tokens. |
| `components/src/dynamo/vllm/handlers.py` | OK | Untouched at the public surface; `dual_mode.py` plugs into the existing handler. |
| `components/src/dynamo/vllm/tests/test_dual_mode.py` + `test_migration.py` | OK | 9 + 9 unit tests, mock-only. They cannot be executed locally without a torch install — they run in the dynamo runtime image during CI. |

### 5.2 RL-Scaling repo

| Path | Verdict | Notes |
| ---- | ------- | ----- |
| `rl-signal-sdk/` | OK | All tests pass locally (part of the 78). |
| `rl-scaling-controller/src/...` | OK | State machine + capacity planner + role-switch + consolidation modules wired through `main.py`; falls back to `InMemoryDGDSAClient` if the K8s API is unavailable. |
| `deploy/Dockerfile` | OK | Slim Python 3.11; installs both packages; healthcheck on `/api/v1/status`. |
| `deploy/manifests/{01-rbac,02-configmap,03-deployment}.yaml` | OK | RBAC scoped to `patch dgdsa` + `get pods`; deployment is single-writer (`Recreate`, replicas: 1). |
| `.github/workflows/ci.yml` | **fixed** | Added `RL-Scaling` branch to triggers + `workflow_dispatch` bypass for `unit-tests` and `build-controller-image`. |

### 5.3 Local test results

```
RL-Scaling: 78 passed in 0.58s   (rl-signal-sdk + rl-scaling-controller)
dynamo:     not runnable locally  (requires torch in the runtime image)
```

### 5.4 Known limitations (carried over from the design doc)

1. **S2 NIXL / KV-pool reconfig** — Rust-side APIs not yet implemented; the
   Python `dual_mode.py` calls are no-op stubs. Sleep/wake path is
   exercised end-to-end and is safe.
2. **S3 KV migration** — uses recompute-prefill fallback (one extra
   prefill on the destination). True NIXL D2D KV transfer is future
   work.
3. **`cuda-checkpoint` / Snapshot** — RTX 3090 (Ampere consumer) cannot use
   it; we fall back to the 4-layer cold-start optimisation (pre-warming,
   image pre-pull, NVMe page-cache, optional standby pod).

---

## 6. Fixes applied during this rollout

| Fix | File | Why |
| --- | ---- | --- |
| `runs-on: ubuntu-latest-16-cores` → `ubuntu-latest` (+ `timeout-minutes: 360`) | `dynamo/.github/workflows/rl-scaling-build.yml` | Larger runners aren't available on personal forks → the previous two runs waited 24 h and were cancelled. |
| Added `workflow_dispatch` bypass to `unit-tests` and `build-controller-image` `if:` conditions | `RL-Scaling/.github/workflows/ci.yml` | Manual `gh workflow run` previously did nothing because every paths-filter output was `false`. |
| Added `RL-Scaling` branch to `push` / `pull_request` triggers | `RL-Scaling/.github/workflows/ci.yml` | Active development happens on `RL-Scaling`; CI used to run only on `main`, leaving the dev branch untested. |
| New `deploy/apply-controller.sh` | `RL-Scaling/deploy/` | Registry-pull-only deployer for disk-constrained operator hosts (the `gpu14` node is at 98 %). |

All four changes are committed and pushed:
- `RL-Scaling@d5794b7` (CI bypass + apply-controller.sh)
- `dynamo@07117d49` (runner fix)

---

## 7. Operational runbook (cheat sheet)

```bash
# === Build & verify the controller ===
gh workflow run -R shqizhang/RL-Scaling ci.yml --ref RL-Scaling
gh run watch -R shqizhang/RL-Scaling

# === Deploy controller (registry-pull) ===
cd /home/shengqizhang/IP/RL-Scaling
IMAGE=ghcr.io/shqizhang/rl-scaling-controller:$(git rev-parse --short HEAD) \
    NAMESPACE=dynamo \
    ./deploy/apply-controller.sh

# === Build & verify the dynamo worker image ===
# Either push to dynamo RL-Scaling on a runtime path, or:
gh workflow run -R shqizhang/dynamo rl-scaling-build.yml --ref RL-Scaling
gh run watch -R shqizhang/dynamo

# === Deploy dynamo backend with the new image ===
cd /home/shengqizhang/IP/dynamo
RL_SCALING_REPO=/home/shengqizhang/IP/RL-Scaling \
DYNAMO_IMAGE_REGISTRY=ghcr.io/shqizhang \
DYNAMO_IMAGE_REPO=dynamo-vllm-runtime \
RELEASE_VERSION=rl-scaling-$(git rev-parse --short HEAD) \
HF_TOKEN=... NGC_API_KEY=... \
./deploy/RL-Scaling/deploy-dynamo.sh --router

# === Smoke test ===
kubectl -n dynamo get pods
kubectl -n dynamo exec deploy/rl-scaling-controller -- \
    python -c "import urllib.request,json;print(json.dumps(json.load(urllib.request.urlopen('http://127.0.0.1:8080/api/v1/status',timeout=3))))"
bash test-scripts/test-s1.sh

# === Rollback controller ===
kubectl -n dynamo set image deploy/rl-scaling-controller \
    controller=ghcr.io/shqizhang/rl-scaling-controller:<previous-sha>
```

---

## 8. Future continuous deployment

The `e2e` job in `ci.yml` already shows the build → `kubectl apply` → smoke
pattern. To turn it into real CD, add a separate workflow gated on
`workflow_run` of `CI` succeeding on `RL-Scaling`:

```yaml
on:
  workflow_run:
    workflows: ["CI"]
    types: [completed]
    branches: [RL-Scaling]
jobs:
  cd:
    if: ${{ github.event.workflow_run.conclusion == 'success' }}
    runs-on: [self-hosted, prod-cluster]
    steps:
      - uses: actions/checkout@v4
      - run: |
          IMAGE=ghcr.io/${{ github.repository_owner }}/rl-scaling-controller:${{ github.event.workflow_run.head_sha }} \
              NAMESPACE=dynamo \
              ./deploy/apply-controller.sh
```

Until that runner exists, deployment stays manual on purpose — to avoid
auto-rolling a half-baked controller into a production cluster.
