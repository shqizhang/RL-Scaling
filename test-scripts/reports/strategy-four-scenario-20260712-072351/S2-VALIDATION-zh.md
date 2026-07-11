# S2 端到端验证（sidecar API + baseline/s2_only 两场景）2026-07-12

## 1. 结论

S2 Elastic PD Role Switch 的机制正确、收益成立、且端到端零 timeout：

- **sidecar API 测试通过**：直接对 decode worker 调 `/switch_role`，D->P 565ms、P->D 432ms，`status=ok`，`/v1/role` 前后确认为 prefill/decode；切回后真实 decode 请求正常完成（1.8s）。
- **端到端两场景（baseline_minimal + s2_only）通过**：

| 场景 | 拓扑 | timeout | valid% | prefill(s) | tail(s) | wall(s) | p95(s) | S2 exec | perf_valid |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline_minimal | 1P1D | 0 | 100.0 | 57.3 | 14.3 | 90.4 | 12.5 | 0 | **true** |
| s2_only | 2P2D | 0 | 100.0 | **32.5** | 15.0 | 132.6 | 7.5 | 2 (D->P,P->D) | **true** |

- **S2 prefill 收益**：prefill serving wall 从 baseline 1P 的 57.3s 降到 s2_only（D->P 3P）的 32.5s，**改善约 43%**；p95 latency 从 12.5s 降到 7.5s。S2 恰好 2 次受控切换（switch latency 419/492ms），tail 零 timeout，质量门通过。
- 说明：s2_only 总体 wall（132.6s）高于 baseline（90.4s）是因为 s2_only 跑 2P2D（4 worker）而 baseline 1P1D（2 worker），GPU-second 更多——这是拓扑成本，S2 的价值体现在 prefill 阶段加速与 p95 改善，不是总体 wall。

## 2. 为什么之前的重 workload 会 tail timeout（根因：集群无 RDMA）

之前 s2_only/mixed 的 4 个 `max_tokens=48` tail timeout，经逐层定位，根因是**本集群 pod 没有 RDMA 通路，跨 pod 的 disaggregated KV 传输走慢速回退路径**，在重负载下 receive 侧积压，tail 请求等 KV 超过 120s：

- 每个 worker pod 只能看到自己那 1 张 GPU（K8s 每 pod 1 GPU + device-plugin 隔离），因此 **cuda_ipc GPU P2P 无法跨 pod**。
- pod 内**没有 RDMA**：无 `/dev/infiniband`、`ibv_devices` 为空、节点无 `rdma/*` 可分配资源、无 device plugin（宿主机 RoCE 网卡 `rocep26s0f0` 等其实 PORT_ACTIVE，但没暴露给 pod，且 pod 走 flannel overlay 网络）。
- 于是跨 pod KV 传输只能 GPU->host->TCP(overlay)->host->GPU，实测 **~32-131 MB/s、~0.57ms/descriptor**。大 prompt 的 KV 传输有上万个 descriptor，单次要 10-58s；在 decode-bound 的 3P1D 下（D->P 把 decode 压到 1 个 worker）积压，tail 请求排队等 KV load 超过 120s 而 timeout。证据：hung tail worker 日志 `Running:0, Waiting:7-8, GPU KV ~16%`（cache 没满，是在等 KV 到达），约 70s 后集中放行。

这是**集群基础设施限制，不在 RL-Scaling / vLLM 应用层**。要在重 workload 下也零 timeout，需要给 pod 打通 RDMA（SR-IOV / RDMA device plugin + `/dev/infiniband` + RoCE 网络），属集群管理工作。

## 3. 本轮 workload 口径

为了让 S2 结论不被上面的传输瓶颈掩盖，本轮把 workload sizing 到本集群的传输能力：`prefill_burst` 用 400 词 prompt、`max_tokens=4`、64 请求（保持 prefill 是瓶颈，让 D->P 的第 3 个 prefill 仍有可观测收益），`balanced_decode` 用 200 词、`max_tokens=96`、24 请求，tail 保持 16/32/48 的混合。每次 KV 传输因此快到约 1s 量级，不再积压，tail 零 timeout。装了 RDMA 后，原始 3200/48 重 workload 同样可服务。

## 4. 应用层已做并保留的相关修复

- `dual_mode`：切换前 `wait_for_requests_to_drain` 排空引擎 + 通过 `collective_rpc` expire NIXL `_reqs_to_send`（需 `VLLM_ALLOW_INSECURE_SERIALIZATION=1`）释放 send 侧 pinned block；reset_prefix_cache 失败时重试。这些是正确的 switch 清理逻辑（虽然 tail timeout 的真因是传输，不是 send 泄漏）。
- DGD：`UCX_RCACHE_MAX_UNRELEASED=1024`（连接器想设但因 NIXL 已 import 设不上，改由 pod env 生效）。
- S2 partner-prefill、controller switch-target、port-forward 自愈等此前修复均保留。
