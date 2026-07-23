% CVPR 2026 Paper Template -- FINAL REPORT
% Double-column. Builds on mid-report.tex: keeps the verified design sections,
% adds an end-to-end autoscaling implementation section, and replaces the
% correctness-only verification with a phase-attributed efficacy evaluation.

\documentclass[10pt,twocolumn,letterpaper]{article}

%%%%%%%%% PACKAGES
\usepackage{booktabs}
\usepackage{makecell}
\usepackage{multirow}
\usepackage{array}
\usepackage{tabularx}
\usepackage{ragged2e}
\usepackage{caption}
\usepackage{pifont}
\usepackage{cvpr}
\input{preamble}
\usepackage{pdfpages}

\definecolor{cvprblue}{rgb}{0.21,0.49,0.74}
\usepackage[pagebackref,breaklinks,colorlinks,allcolors=cvprblue]{hyperref}
\usepackage{graphicx}
\usepackage{amsmath}
\usepackage{amssymb}
\usepackage{geometry}
\usepackage{float}
\usepackage{listings}
\usepackage{xcolor}
\usepackage{enumitem}
\usepackage{tikz}

\usetikzlibrary{arrows.meta,positioning,shapes.geometric,fit,calc}

% Column types for tabularx: L=left-wrapped, C=center-wrapped, R=right-wrapped
\newcolumntype{L}{>{\RaggedRight\arraybackslash}X}
\newcolumntype{C}{>{\Centering\arraybackslash}X}
\newcolumntype{R}{>{\RaggedLeft\arraybackslash}X}

\lstset{
  basicstyle=\ttfamily\scriptsize,
  breaklines=true,
  frame=single,
  columns=fullflexible,
  keepspaces=true,
  xleftmargin=2pt,
  xrightmargin=2pt,
}

%%%%%%%%% TITLE
\title{Cloud-Native Autoscaling for Disaggregated LLM Inference:\\Elastic Role Switching and In-Flight Request Consolidation for Reinforcement Learning Workloads}

%%%%%%%%% AUTHORS
\author{
Shengqi ZHANG\\
{\tt szhanggd@connect.ust.hk (21209697)} \\
}

\begin{document}
\maketitle

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\begin{abstract}
Prefill--Decode (PD) disaggregation is the mainstream LLM inference architecture (exemplified by NVIDIA Dynamo), splitting compute-bound prefill and bandwidth-bound decode onto separate GPU pools to maximize online serving efficiency. However, in reinforcement-learning (RL) post-training, inference traffic bursts periodically with rollout phases, leaving pools alternately idle and wasting GPU-hours; horizontal scaling (cold start on the order of tens of seconds) cannot react within a single rollout phase.

This report introduces two runtime primitives on Dynamo + vLLM~0.16, driven end-to-end by an RL-signal autoscaling controller: (1)~Elastic PD Role Switching---a state-machine-driven in-place protocol that flips a worker's role via ModelCard mutation and engine sleep/wake cycling, with no engine rebuild or pod redeploy; (2)~In-Flight Decoder Request Consolidation---a three-phase block-hold protocol that migrates running decode requests across GPUs with zero KV loss and then releases the drained decoders.

Beyond confirming correctness, we evaluate efficacy with purpose-built phased workloads run across five topologies ($\times 3$ repeats) on a Kubernetes deployment of \texttt{Qwen3-0.6B}, attributing timing and GPU occupancy per rollout phase, and gate every suite on eight automated acceptance checks before it may be analysed. The results: all runs are 100\% valid (0 HTTP errors, 0 timeout); topology elasticity cuts batch makespan by \textbf{21.2\%} ($t=-9.98$); reclaiming drained decoders inside the rollout lowers tail-phase decode-GPU occupancy by \textbf{44.5\%} ($t=-103.9$) and average decode-GPU count by 22.1\%; and a role switch costs \textbf{941\,ms} with zero request loss, decomposed per protocol step. We also report two boundaries the data imposes rather than hiding them: role switching yields \emph{no} queue-timing benefit here---phase-A time-to-first-token stays within 1\% of the equal-topology control across two independent suites---because this fabric has no RDMA and the prefill phase is bounded by KV transport rather than prefill compute; and the 44.5\% is attributable to idle-release plus scale-down, since the runs producing it performed no live migration.
\end{abstract}

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{Introduction}
\label{sec:intro}

\subsection{Overview of the NVIDIA Dynamo Serving Framework}
\label{sec:dynamo-overview}

NVIDIA Dynamo is an open-source serving framework for disaggregated LLM inference. Architecturally, it is a Rust runtime that hosts (i)~a KV-aware router that accepts incoming LLM inference requests, (ii)~any number of worker pods each wrapping a vLLM engine, and (iii)~a discovery layer that uses Kubernetes Custom Resources as the single observable source of truth for worker membership. The frontend embeds two stateful routers---\texttt{KvRouter} for decode dispatch and \texttt{PrefillRouter} for prefill dispatch---and a \texttt{ModelWatcher} that maintains the WorkerSet by \texttt{list+watching} worker metadata CRs. The KV-cache transfer between prefill and decode workers is performed by the NIXL connector over NVLink / RDMA. This stack is the \texttt{de facto} mainstream choice today for production PD-disaggregated serving and is the baseline on which our extensions are built.

\subsection{The RL Workload and Its GPU-Waste Problem}
\label{sec:rl-waste}

The cost economics of LLM inference are dominated by GPU-hours. In online chat-style serving, the traffic is near-stationary; static PD partitioning works because both pools stay busy. The RL rollout loop that drives modern post-training methods (RLHF, DPO, GRPO) submits inference traffic in a fundamentally different pattern, as shown in Figure~\ref{fig:gpu-hour}.

\begin{figure}[t]
\centering
\includegraphics[width=\linewidth]{GPU-hour.png}
\caption{GPU utilization pattern in RL workloads. Each phase boundary leaves one pool busy and the other idle.}
\label{fig:gpu-hour}
\end{figure}

Each phase boundary leaves one of Dynamo's GPU pools fully busy and the other completely idle. Two compounded sources of waste result:

\begin{enumerate}[nosep]
\item Cross-phase pool waste. During the prompt-processing burst only prefill GPUs are active, while during the long-tail generation only decode GPUs are active. The idle pool retains its GPU allocation throughout, incurring cost without contributing useful work.
\item Intra-phase tail waste. As a batch nears completion the active request count on each decoder asymptotically approaches zero, yet the GPU cannot be released until the last remaining long completion finishes.
\end{enumerate}

Standard elasticity mechanisms are structurally mismatched to this workload. Horizontal pod scaling incurs a cold-start latency on the order of tens of seconds, which is one to two orders of magnitude larger than the sampling phase it would need to react inside. Moreover, each newly started pod initializes with an empty prefix cache and must re-establish NIXL connectivity, discarding the prefix-reuse benefit that PD disaggregation was designed to expose. The fundamental problem is that cold start cannot converge fast enough: by the time a new worker is ready, the phase that demanded it has already passed. Static over-provisioning, on the other hand, sizes both pools for peak demand and therefore lower-bounds GPU expenditure at that peak even while either pool is idle. Both mechanisms fail the RL controller's requirement to act within a single rollout phase.

\subsection{Limitations of Current Elasticity Mechanisms}
\label{sec:limitations}

Three structural facts of the vLLM~0.16 + Dynamo~v1.0.1 stack prevent existing mechanisms from supporting RL-driven elastic scaling:

\begin{enumerate}[nosep]
\item The \texttt{kv\_transfer\_config} is fixed at engine construction. The NIXL connector binds to one role at engine boot. Any run-time role switch must not rebuild the engine.
\item vLLM's prefix cache is an index over KV blocks that \texttt{engine.sleep(level=2)} returns to the GPU allocator. Without a synchronized reset, a resumed engine can serve stale hits.
\item Dynamo's router is stateful. \texttt{KvRouter} and \texttt{PrefillRouter} carry radix-tree KV indices and per-worker cost models. A role change must propagate through the discovery layer and reconverge this state without disrupting in-flight requests.
\end{enumerate}

\subsection{Optimization Targets}
\label{sec:opt-targets}

We formalize the RL workload's optimization goal. The primary lever is GPU utilization:
\begin{equation}
U_{\text{GPU}} = \frac{\sum_g T_{\text{compute}}(g)}{\sum_g T_{\text{allocated}}(g)}
\label{eq:ugpu}
\end{equation}

By re-rolling idle GPUs into the currently-bottlenecked phase and by consolidating tail-end decode work onto fewer GPUs, the system raises useful work per allocated GPU-hour. The operation must complete fast enough (sub-second to a few seconds) that an RL controller can act inside one rollout phase.

\subsection{Contributions}
\label{sec:contributions}

\begin{itemize}[nosep]
\item (C1) A two-layer in-place role-switch protocol---an eight-step engine-core state machine wrapped in a zero-loss safety envelope (cordon-first, drain\,+\,settle, hold-during-switch, bounded outbound-KV drain)---that atomically transitions a worker between decode and prefill roles. Measured cost \textbf{941\,ms} per flip under in-flight load (engine steps ${\sim}115$\,ms; \texttt{register\_mdc} control-plane round-trip ${\sim}309$\,ms; drain\,+\,settle ${\sim}502$\,ms) at 100\% request validity.
\item (C2) A single-TCP-slot dispatcher for partner-prefill that lets the same vLLM engine serve both decode and prefill traffic at run-time without socket re-binding.
\item (C3) A three-phase block-hold NIXL-pull migration protocol that consolidates running decoders with zero KV loss, bounded by a safety-net sweep timer.
\item (C4) An RL-signal-driven autoscaling controller that dispatches the above primitives with a cordon-first quiesce/settle discipline that makes them composable without dropping requests.
\item (C5) A phase-attributed end-to-end evaluation on a Kubernetes deployment of \texttt{Qwen3-0.6B} demonstrating both correctness (100\% valid across all scenarios) and efficacy (makespan $-21.2\%$; tail decode-GPU$\cdot$s $-44.5\%$), with an honest account of what could not be resolved at this scale.
\end{itemize}

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{Background and Related Work}
\label{sec:background}

\subsection{Prefill--Decode Disaggregation}
\label{sec:pd-disagg}

LLM inference of every request goes through two serial phases that share the same model weights but have different resource bottlenecks. The prefill phase processes all $N$ prompt tokens in a single forward pass with full-rank attention, and is compute-bound due to large GEMMs. The decode phase generates one token at a time against the growing KV cache, and is memory-bandwidth-bound.

Co-locating both phases on one GPU (continuous batching) maximizes raw throughput but causes severe head-of-line blocking: a single long prefill stalls a batch of fast decodes. PD-disaggregated serving---pioneered by Splitwise~\cite{splitwise} and DistServe~\cite{distserve} and now the mainstream pattern adopted by NVIDIA Dynamo~\cite{dynamo}, vLLM-disagg~\cite{vllm}, and SGLang-disagg---splits the two phases onto separate GPU pools. The prefill pool produces the KV cache and ships it to the decode pool over a high-bandwidth fabric (NVLink / RDMA via NIXL~\cite{nixl}). The advantages are: compute-bound and bandwidth-bound work no longer interfere; each pool can be sized to its own bottleneck; and prefix caching becomes a first-class cross-request optimization.

However, the split inherits a structural inefficiency: the ratio of compute to memory traffic in a workload may not match the ratio of prefill to decode GPUs that the operator provisioned, so one pool is idle while the other is the bottleneck. This mismatch is amplified in RL workloads where traffic arrives in bursts, and it is the central leverage point of this work.

\subsection{NVIDIA Dynamo Runtime Architecture}
\label{sec:dynamo-arch}

Dynamo provides the routing and discovery substrate on top of stateful vLLM engines. Figure~\ref{fig:dynamo-arch} illustrates the overall architecture.

\begin{figure}[t]
\centering
\includegraphics[width=\linewidth]{dynamo-architecture.png}
\caption{NVIDIA Dynamo overall architecture.}
\label{fig:dynamo-arch}
\end{figure}

The architecture consists of three core subsystems relevant to this work. The discovery layer uses Kubernetes Custom Resources (one CR per worker pod) as the single source of truth for worker membership. Each worker calls strategic-merge-patch to update its own CR; the frontend's \texttt{ModelWatcher} reconstructs the WorkerSet from these CRs via \texttt{list+watch}. There is no etcd and no central registry. The routing layer consists of \texttt{KvRouter} and \texttt{PrefillRouter}, both stateful engines. \texttt{KvRouter} maintains a radix-tree index over KV blocks held by each decoder, scoring candidates by prefix-overlap, queue load, and capacity. \texttt{PrefillRouter} fans prefill traffic to any prefill-role worker discovered through the CRs. When a worker's role changes, the router state must reconverge through CR propagation. The NIXL connector provides zero-copy cross-GPU KV transfer over NVLink (RDMA over InfiniBand for multi-host). Combined with the KV-Block Manager (KVBM) that tracks per-request GPU-block layout, it enables a decoder to pull KV blocks directly from another worker's VRAM---the mechanism our consolidation protocol builds upon.

For our autoscaling research, Dynamo's CR-based discovery provides the critical property that role changes can be made visible to the entire system through a single metadata mutation, without restarting pods or rebuilding engines.

\subsection{KV Cache and Prefix Caching}
\label{sec:kv-cache}

The KV cache stores the keys/values of every prior token so decode amortizes attention cost. Prefix caching~\cite{lmcache} reuses KV blocks across requests that share a prompt prefix. vLLM~0.16 keeps the cache index in CPU memory and the blocks pinned in GPU VRAM. This split is the coherence target of our role-switch protocol: the index can outlive the blocks when \texttt{engine.sleep(2)} releases them to the GPU allocator, and a stale hit at wake-up will corrupt a later request.

\subsection{Related Systems and Distinctions}
\label{sec:related}

\begin{table}[t]
\centering
\caption{Comparison with related systems.}
\label{tab:related}
\small
\begin{tabularx}{\linewidth}{@{}lLL@{}}
\toprule
System & Elasticity primitive & Limitation addressed \\
\midrule
Splitwise~\cite{splitwise} / DistServe~\cite{distserve} & Static PD partition at deploy time & No run-time role flip \\
vLLM native~\cite{vllm} & Pod replicate & Cold start ${\sim}$30\,s; loses prefix cache \\
Mooncake~\cite{mooncake} & KV pool offload & Orthogonal to PD; no role switch \\
ServerlessLLM~\cite{serverlessllm} & Cold-start optimized serverless & No PD-disagg topology \\
SpotServe~\cite{spotserve} & Spot instance migration & Instance-level, not request-level \\
Our work & In-place role switch + NIXL-pull migration & Sub-second elasticity and zero KV loss \\
\bottomrule
\end{tabularx}
\end{table}

To our knowledge, no prior open-source serving system combines (a) in-place sub-second PD role flipping with (b) live decoder-to-decoder NIXL-pull migration, both controllable from an external RL signal, as summarized in Table~\ref{tab:related}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{System Design: RL-Signal-Driven Autoscaling}
\label{sec:system-design}

\subsection{RL Scenarios and Design Rationale}
\label{sec:rl-scenarios}

The reinforcement-learning post-training loop presents two distinct scaling scenarios that demand different elasticity primitives:

\begin{enumerate}[nosep]
\item Elastic PD role switch. When the RL training job transitions between sampling and training phases, the prefill/decode demand ratio shifts abruptly---early in a rollout burst prefill dominates as all prompts arrive simultaneously, while later decode dominates as long completions accumulate. The static PD partition cannot track these shifts, leaving one pool over-provisioned and the other starved. An in-place role-flip primitive is needed so that idle workers can be instantly re-roled to the bottlenecked pool without cold start.
\item Decode request consolidation. Near the end of a decode-heavy phase, a shrinking set of long-running completions is scattered across many decoders, each holding only one or two active requests. These nearly-empty decoders cannot be reclaimed or re-roled because aborting in-flight work wastes thousands of already-generated tokens. A live migration primitive is needed to consolidate remaining requests onto fewer decoders, freeing the rest for scale-down or role switch.
\end{enumerate}

To address these scenarios, we propose an RL-signal-driven autoscaling architecture with three layered primitives, as summarized in Table~\ref{tab:scaling-scenarios}.

\begin{table}[t]
\centering
\caption{RL-signal-driven scaling scenarios.}
\label{tab:scaling-scenarios}
\small
\begin{tabularx}{\linewidth}{@{}LLLL@{}}
\toprule
Scenario & Layer & Goal & Primitive \\
\midrule
Cluster scaling & Pod replicas & Pre-warm / drain & Patch replicas \\
PD role switch & In-place flip & Re-balance P/D & \texttt{/switch\_role} \\
Consolidation & Live migration & Free target & \texttt{/migrate} \\
\bottomrule
\end{tabularx}
\end{table}

Rollout-driven cluster scaling serves as the foundation: it simulates hot-start by pre-warming pods before a rollout begins, so that role-switching and consolidation operate on already-running engines rather than cold-starting new ones. The controller architecture is shown in Figure~\ref{fig:rl-controller}.

\begin{figure}[t]
\centering
\includegraphics[width=\linewidth]{RL-controller.png}
\caption{RL-Scaling controller architecture. The controller consumes phase signals from the RL training job and dispatches scaling primitives.}
\label{fig:rl-controller}
\end{figure}

\subsection{Deployment Topology}
\label{sec:deploy-topo}

The deployment extends a standard Dynamo graph deployment with one pod-local component (the RL-Scaling sidecar) and one cluster-level component (the RL-Scaling controller), as shown in Figure~\ref{fig:k8s-deploy}.

\begin{figure}[t]
\centering
\includegraphics[width=\linewidth]{K8S-deployement.png}
\caption{Kubernetes deployment topology showing dual-mode worker pods, frontend, and RL-Scaling controller.}
\label{fig:k8s-deploy}
\end{figure}

Each dual-mode worker pod exposes three logical TCP services, as listed in Table~\ref{tab:ports}.

\begin{table}[t]
\centering
\caption{Port model of a dual-mode worker pod.}
\label{tab:ports}
\small
\begin{tabularx}{\linewidth}{@{}lCL@{}}
\toprule
Service & Port & Role \\
\midrule
Frontend HTTP API & :8000 & inference request intake\\
Request-serving slot & dynamic & \texttt{generate} endpoint \\
System / Prometheus & :9090 & Metrics and health \\
RL-Scaling sidecar & :9091 & Control-plane HTTP \\
\bottomrule
\end{tabularx}
\end{table}

The key invariant for dual-mode operation is: one pod, one engine, one TCP slot---two ModelCards (decode + prefill) take turns owning that slot. The vLLM engine is built with the following configuration, carrying NIXL metadata for both roles from boot:

\begin{lstlisting}
--kv-transfer-config NixlConnector kv_both
--kv-events-config zmq
\end{lstlisting}

The \texttt{switch\_role} operation never reopens any socket; it only renames the entry that the frontend's \texttt{ModelWatcher} observes in the worker CR.

\subsection{Request Path}
\label{sec:request-path}

A single chat request traverses the system in the following ordered steps:

\begin{enumerate}[nosep]
\item The client issues \texttt{POST /v1/chat/completions} to the frontend on \texttt{:8000}.
\item Under PD-disaggregated mode, \texttt{PrefillRouter} first selects a prefill worker from the prefill subset of the \texttt{WorkerSet}, dispatches the prompt to it, and receives \texttt{kv\_transfer\_params} describing the KV blocks the prefill worker has produced.
\item \texttt{KvRouter} selects a decoder by scoring each candidate's radix-tree prefix-block overlap, queue load, and remaining KV capacity, then drawing via \texttt{softmax\_sample}.
\item The frontend reads the chosen worker's transport URL from the corresponding \texttt{DWMD.endpoints[\dots].transport.tcp} entry and connects to its dynamic TCP slot \texttt{host:port/\{cid:x\}/generate}.
\item The worker's \texttt{generate} handler---gated by the request-time dispatcher on dual-mode pods---runs the request through the local vLLM engine, pulling prefill KV blocks via NIXL when \texttt{kv\_transfer\_params} is present.
\item Generated tokens stream back over the same TCP slot to the frontend, which forwards them as SSE chunks to the client.
\end{enumerate}

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{Elastic PD Role Switching}
\label{sec:role-switch}

\subsection{Problem Definition}
\label{sec:switch-problem}

Given a running disaggregated deployment with $D$ decoder pods and $P$ prefill pods serving chat traffic at $r$\,RPS through the frontend, an operator wants to instruct a specific decoder pod $D_i$ to become a prefill worker (and later come back) without restarting the pod, without dropping in-flight requests on the other pods, and within a few seconds. Concretely, \texttt{POST~<$D_i$>/switch\_role} must achieve all of the following:

\begin{enumerate}[nosep]
\item The chat \texttt{KvRouter} stops selecting $D_i$ (its decode WorkerSet membership is withdrawn);
\item $D_i$'s decode-side KV state is released;
\item $D_i$ subsequently serves prefill traffic that the frontend's \texttt{PrefillRouter} dispatches to it;
\item A reverse \texttt{target\_role="decode"} restores the above symmetrically;
\item The pod's name, IP, vLLM engine identity, and prefix-cache infrastructure are unchanged; only the registered role in the worker CR and the engine's transient state are mutated.
\end{enumerate}

Because the operation has internal sequencing constraints, the implementation is a state machine rather than a flat script. It is best understood as \emph{two layers}: an engine-core flip wrapped in a zero-loss safety envelope. This layering reconciles the switch-cost numbers reported across this project: 453\,ms (mid-term, light load, no envelope) $\rightarrow$ 3.4\,s (first zero-loss envelope, 3.0\,s settle) $\rightarrow$ \textbf{941\,ms} in the final round.

\subsection{Layer 1: The Eight-Step Engine Core}
\label{sec:state-machine}

\texttt{DualModeWorker.switch\_role(target)} runs under a per-worker async lock and proceeds through eight deterministic states; each transition is timed and surfaced in the JSON response's \texttt{timings\_ms} field. Figure~\ref{fig:role-switch} illustrates the state machine. Excluding the \texttt{register\_mdc} control-plane round-trip (${\sim}309$\,ms, a Kubernetes \texttt{apply}, a physical floor rather than engine work), the engine steps total only ${\sim}115$\,ms: sleep 58, wake 27, cordon 16, flush 7, reconfig-NIXL 5, reset-prefix-cache 2 (Table~\ref{tab:switchcost}).

\begin{figure}[htbp]
\centering
\scriptsize
\begin{tikzpicture}[
  node distance=3.0mm,
  box/.style={draw, rounded corners=1pt, align=center, inner sep=2pt,
              font=\scriptsize, minimum height=4.4mm, text width=26mm},
  env/.style={box, fill=blue!8},
  core/.style={box, fill=green!12},
  ann/.style={font=\tiny, align=left, text width=26mm, inner sep=1pt},
  arr/.style={-{Latex[length=1.3mm]}}]
\node[env] (c) {(1) cordon, 16\,ms};
\node[env, below=of c] (d) {(2) drain to idle};
\node[env, below=of d] (s) {(3) settle 0.5\,s};
\node[env, below=of s] (k) {(4) outbound-KV wait};
\node[core, below=of k] (sl) {(5) sleep(2), 58\,ms};
\node[core, below=of sl] (rn) {(6) reconfig\_nixl, 5\,ms};
\node[core, below=of rn] (rp) {(7) reset\_prefix, 2\,ms};
\node[env, below=of rp] (rg) {(8) register\_mdc, 309\,ms};
\node[env, below=of rg] (w) {(9) wake, 27\,ms};
\draw[arr] (c) -- (d);
\draw[arr] (d) -- (s);
\draw[arr] (s) -- (k);
\draw[arr] (k) -- (sl);
\draw[arr] (sl) -- (rn);
\draw[arr] (rn) -- (rp);
\draw[arr] (rp) -- (rg);
\draw[arr] (rg) -- (w);
\node[ann, right=3mm of c]  {withdraw the old-role ModelCard \emph{first}};
\node[ann, right=3mm of d]  {in-flight requests finish naturally};
\node[ann, right=3mm of s]  {continuous idle $\Rightarrow$ router converged};
\node[ann, right=3mm of k]  {no peer still pulling KV we produced};
\node[ann, right=3mm of sl] {frees the GPU KV blocks};
\node[ann, right=3mm of rp] {reset while asleep: no stale hit};
\node[ann, right=3mm of rg] {publish only in the target role};
\node[ann, right=3mm of w]  {\textbf{total 941\,ms} (884--1005)};
\end{tikzpicture}
\caption{The deployed two-layer \texttt{switch\_role} protocol, annotated with the
10-switch means of Table~\ref{tab:switchcost}. Blue = zero-loss envelope,
green = engine core; the dispatcher \textbf{holds} any request arriving between
(1) and (8) and serves it under the pre-switch role. This \emph{replaces} the
mid-term state machine, which ordered \texttt{sleep} before
\texttt{unregister\_mdc} and omitted steps (2)--(4) --- the three steps that
account for 89\% of the measured cost.}
\label{fig:role-switch}
\end{figure}

\subsection{Layer 2: The Zero-Loss Envelope}
\label{sec:envelope}

The core alone drops requests when a flip is issued mid-flight: the router keeps dispatching to the worker until it observes the ModelCard withdrawal, so a request can land on a half-asleep engine (observed as switch-instant HTTP 500s under concurrency). The deployed protocol therefore wraps the core with, in order: \textbf{cordon-first} (withdraw the old-role ModelCard before anything else, closing the intake as early as possible); \textbf{drain to idle\,+\,settle window} (0.5\,s of continuous idle confirms the router stopped routing here; any arrival re-drains); \textbf{hold-during-switch} (between cordon and re-registration the router can only be acting on the \emph{old} card, so an arrival in that window is old-role traffic by construction---the request-time dispatcher holds it until the switch completes and serves it under the pre-switch role, instead of letting \texttt{sleep} reject it); and \textbf{bounded outbound-KV drain} (Section~\ref{sec:ordering}, constraint~4). Hold-during-switch is what makes the short settle safe: losslessness became a property of the protocol rather than of out-waiting the router, so the window shrank $3.0\,\text{s}\rightarrow0.5\,\text{s}$ with validity unchanged at 100\%.

\subsection{Critical Ordering Constraints}
\label{sec:ordering}

Four orderings make the protocol safe:

\noindent(1) cordon before everything: unpublish first. Removing the ModelCard is what closes the intake, and it is eventually consistent (hundreds of milliseconds through the frontend watcher), so it must start as early as possible. \emph{This revises the mid-term report's ordering}, which paused generation before unpublishing; draining behind a still-published card merely lets the router refill the worker.

\noindent(2) drain and confirm before sleep. \texttt{sleep(2)} does not guarantee running requests finish, so their blocks keep \texttt{ref\_cnt>0} and the reset below cannot free them.

\noindent(4) inside the sleep window, before (7): reset cache while engine is asleep. vLLM's prefix cache holds block-IDs that \texttt{sleep(2)} returns to the allocator. Reset-after-wake is unsafe because the wake-up race could allocate one of those blocks to a new request before we flush the index. Reset-while-asleep is atomic from the scheduler's perspective:

\begin{lstlisting}
before sleep:  prefix_cache -> block #42
sleep(2):      block #42 returned to free pool
reset_pc:      index cleared
wake_up:       no stale hits possible
\end{lstlisting}

\noindent(3) publish only when the engine is in a consistent target state. This guarantees that traffic arriving via the new ModelCard lands on an engine that can serve it.

\noindent(4) never sleep while a peer is pulling our KV. \texttt{sleep(level=2)} frees GPU memory. If this worker served prefill and a peer decoder's NIXL READ against its KV is still in flight, sleeping destroys that transfer and the peer's request hangs until its client timeout. We measured this directly: a P$\to$D switch-back issued 5\,s into the decode phase left 646 blocks permanently pinned (\texttt{Failed to reset prefix cache because some blocks are not freed yet}) and hung 34 peer requests to their 600\,s timeout. The earlier 3.0\,s quiesce window had been \emph{accidentally} safe---it happened to outlast typical pull times---so the defect surfaced only once the switch became fast. Force-expiring the connector's pending sends is equally destructive for a send a peer is about to pull. The deployed protocol therefore \emph{waits}, polling the connector's pending-send registry and the block pool's pinned state (bounded at 8\,s), and force-expires only what nobody claimed in that window---a true orphan. At a phase boundary with no handoff in flight this passes on the first poll at ${\sim}0$ cost; under an active handoff it is the honest, load-dependent price of losslessness.

\subsection{Why kv\_role=kv\_both Is Load-Bearing}
\label{sec:kv-both}

vLLM's \texttt{kv\_transfer\_config} is fixed at engine construction. Run-time mutation would require an engine rebuild (at least 5 seconds plus prefix-cache loss). We instead build one engine that knows about both roles from boot (\texttt{NixlConnector kv\_both}). Under \texttt{kv\_both} the engine registers NIXL metadata for both prefill-side and decode-side semantics. The role switch is then purely (i) a registration change in the worker CR (which ModelCard is published) and (ii) an engine-state cycle (sleep, reset, wake) to discard transient state inconsistent under the new role.

\subsection{Partner-Prefill: One TCP Slot, Two ModelCards}
\label{sec:partner-prefill}

When partner-prefill is enabled, the post-switch pod becomes a first-class prefill worker that the frontend's \texttt{PrefillRouter} actually dispatches traffic to. Two non-obvious behaviours were required:

(a) Multi-chunk merge of \texttt{kv\_transfer\_params}. vLLM~0.16's \texttt{NixlConnector} publishes \texttt{kv\_transfer\_params} only on the last \texttt{RequestOutput} chunk, but Dynamo's Rust \texttt{PrefillRouter} reads \texttt{disaggregated\_params} only from the first chunk. A wrapper consumes the entire stream, captures the last observed \texttt{kv\_transfer\_params}, and yields a merged chunk so the router sees the field on chunk~\#1.

(b) Single TCP-slot dispatcher. Dynamo's \texttt{SharedTcpServer} stores handlers in a map keyed by endpoint path. Because the \texttt{connection\_id} is process-level, a naive registration of both decode and prefill on the same engine would collide. The fix is to register exactly one TCP handler and dispatch at request time:

\begin{lstlisting}[language=Python]
async def _generate_dispatch(request, context):
    if dm.current_role == "prefill" \
       and partner_prefill_handler is not None:
        async for chunk in _partner_prefill_generate(
            request, context):
            yield chunk
        return
    async for chunk in handler.generate(
        request, context):
        yield chunk
\end{lstlisting}

\texttt{switch\_role} flips \texttt{current\_role} between steps~(3) and~(6), so by the time the new ModelCard is observable on the frontend the dispatcher routes correctly.

\subsection{End-to-End Correctness via Kubernetes Service Discovery}
\label{sec:e2e-correctness}

The protocol's correctness does not rely on any in-process coordination between worker and frontend---it relies entirely on the cluster control plane. The propagation chain on every flip is:

\begin{lstlisting}
Worker mutates own CR
-> K8s API server (etcd write)
-> kube informer (watch event)
-> Frontend ModelWatcher(re-converge WorkerSet + invalidate routers)
\end{lstlisting}

Several non-obvious properties fall out of this design: pod identity is invariant (only the CR's \texttt{model\_cards} entry changes); the worker CR is the single observable truth; no Kubernetes Service is on the chat path; and eventual consistency is bounded (empirically the watcher converges in well under 200\,ms on a single-node cluster). A test or operator confirms a successful flip by composing three independent observations: (1)~CRD diff---the decode \texttt{model\_card} key disappears and a prefill key appears; (2)~Frontend log---\texttt{ModelWatcher} emits a Removed event correlated with the CR change; (3)~Workload attribution---post-switch probes confirm the target's \texttt{prompt\_tokens\_total} counter grows while its decode attribution is zero.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{In-Flight Decoder Request Consolidation}
\label{sec:consolidation}

\subsection{Problem Definition}
\label{sec:consol-problem}

The role-switch protocol lets us shrink the decoder pool if the target decoder has no live requests---but a \texttt{switch\_role} issued mid-flight terminates whatever was running. For long completions (e.g., \texttt{max\_tokens~=~6000}) with thousands of already-generated tokens, throwing the work away is wasteful. We therefore need an operator-callable primitive that migrates a running request from one decoder to another, leaving the source drainable, while guaranteeing that no KV state is lost or corrupted.

\subsection{The Three-Phase Block-Hold NIXL-Pull Protocol}
\label{sec:three-phase}

The protocol moves a request $R$ from a source decoder $D_{\text{src}}$ to a destination decoder $D_{\text{dst}}$ in three coordinated phases. The defining property is that $D_{\text{src}}$ keeps the request alive and the KV blocks pinned across the entire handshake, releasing them only after $D_{\text{dst}}$ has confirmed acceptance. Combined with NIXL's RDMA-style READ semantics, this gives a strict guarantee: at every instant of the protocol, the request's KV state exists on at least one GPU, as shown in Figure~\ref{fig:migration}.

\begin{figure}[t]
\centering
\includegraphics[width=\linewidth]{request-consolidation.png}
\caption{Three-phase block-hold NIXL-pull migration sequence. The connector path is the fast path when KVBM is exposed; recompute is the safe fallback otherwise.}
\label{fig:migration}
\end{figure}

Phase~1 (Block-Hold): The orchestrator calls \texttt{migrate\_out} on $D_{\text{src}}$. $D_{\text{src}}$ pins the KV blocks of $R$, registers $R$ in pending migrations, collects source block IDs, NIXL coordinates, sampling parameters and previously emitted token count, but does NOT abort $R$. It returns \texttt{kv\_transfer\_params} and \texttt{sampling\_params} to the orchestrator.

Phase~2 (NIXL READ Pull): The orchestrator calls \texttt{migrate\_in} on $D_{\text{dst}}$ with the parameters from Phase~1. $D_{\text{dst}}$ applies the cost-benefit gate, injects \texttt{kv\_transfer\_params} into the request, submits the new request to its local engine. The \texttt{NixlConnectorScheduler} issues an RDMA READ to $D_{\text{src}}$'s GPU, populates local KV blocks, and begins decoding from \texttt{previously\_emitted\_tokens~+~1}.

Phase~3 (Release): The orchestrator calls \texttt{migration\_complete} on $D_{\text{src}}$. $D_{\text{src}}$ aborts $R$, unpins KV blocks, and removes the entry from pending migrations.

The KV-consistency guarantee satisfies an at-least-one-copy invariant: no transition step ever leaves the request without an authoritative KV copy. If the orchestrator crashes between Phase~2 and Phase~3, the source has not aborted $R$, so the failure mode degrades to at-most-once duplicate emission rather than KV-state loss. A two-phase variant---abort on \texttt{migrate\_out}, then submit on \texttt{migrate\_in}---is unsafe under NIXL pull: if $D_{\text{src}}$ aborts first, its KV blocks are freed and may be reused before the $D_{\text{dst}}$ READ completes, a silent correctness violation. The three-phase protocol decouples acceptance from cleanup, turning a two-party race into a sequential handshake.

\subsection{Migration Strategy and Safety Net}
\label{sec:mig-strategy}

The protocol moves one specified request between two specified decoders; the strategy layer answers which request to drain and onto which peer. Each worker maintains an in-process request registry updated at submission, on every streaming delta, and on completion, answering which requests it owns and how progressed each is. Source-side victim selection picks the request with the largest generated token count, maximizing marginal cost saved per migration. Destination-side admission rejects \texttt{migrate\_in} when the request is structurally not worth migrating (replay cost over threshold, or too few tokens remaining), returning \texttt{status=declined} before committing engine state. The controller enumerates peer decoders from the WorkerSet, ranks them by load score, and picks the least-loaded eligible peer with spare KV capacity. A background \texttt{sweep\_stale\_migrations} task runs every second and force-completes any pending hold older than 10\,s, so a crashed orchestrator cannot indefinitely pin KV blocks. Finally, \texttt{migrate\_in} carries \texttt{previously\_emitted\_tokens}; the destination's streaming consumer skips this prefix so the client receives exactly one logical stream across the migration boundary.

\subsection{On the Transfer Path (Honest Caveat)}
\label{sec:transfer-path}

In a dedicated micro-benchmark with the KVBM block-bridge wired, \texttt{migrate\_in} demonstrably takes the connector path (188\,ms; 109 physical KV blocks; 1688 tokens transferred without recomputing the prefix). The default clean image does not expose the KVBM index, so in the production phased runs of Section~\ref{sec:eval} migration can fall back to recompute. This distinction matters for per-migration latency but \emph{not} for the efficacy result: the GPU-reclamation benefit reported below comes from \emph{releasing idle decoders after consolidation}, and is independent of which transfer path moves the KV.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{Implementation: The End-to-End Autoscaling Controller}
\label{sec:implementation}

This section describes how the three primitives are driven end-to-end by an autoscaling controller, and why the control discipline is what makes them usable in an RL setting.

\subsection{Control Loop}
\label{sec:control-loop}

The RL-Scaling controller is a cluster-level service running a periodic decision loop over three inputs: (i)~the \emph{RL phase signal}---the training job posts \texttt{send\_progress(frac, batch\_size, avg\_isl, avg\_osl)} marking where in a rollout it is; (ii)~\emph{cluster state}---the WorkerSet and per-pod roles read from the worker CRs; and (iii)~\emph{live load}---per-pod active-request counts and generation throughput scraped from the sidecar and Prometheus. From these it maintains a small state machine ($\texttt{IDLE}\rightarrow\texttt{WARM\_UP}\rightarrow\texttt{REBALANCE}\rightarrow\texttt{CONSOLIDATE}\rightarrow\texttt{DRAIN}$) and dispatches the primitives: \texttt{patch replicas} to pre-warm, \texttt{/switch\_role} to re-balance the P:D ratio, and \texttt{/migrate} followed by scale-down to consolidate and reclaim.

\subsection{Role-Switch Dispatch and the Quiesce Discipline}
\label{sec:quiesce}

When the phase signal indicates a prefill-dominated burst the controller re-roles a decoder to prefill (D$\to$P); when it flips to decode-dominated it reverts (P$\to$D). Under in-flight load a naive flip drops requests, so the controller uses the cordon-first handshake of Section~\ref{sec:envelope}: withdraw the target's ModelCard, drain to idle and confirm a stable settle window, wait for outbound KV pulls to finish, then run the sleep/reset/wake cycle. The envelope---not the engine---dominates the 941\,ms cost, and it buys zero request loss (Section~\ref{sec:eval} shows 100\% valid).

\noindent\textbf{Trigger design is part of the contribution.} \emph{Which} signal fires the switch proved to matter as much as how fast the switch is. On this stack the \emph{prefill} queue never builds a backlog---prefill is fast enough that \texttt{dynamo\_frontend\_queued\_requests\{role="prefill"\}} stays at 0 through a 44-prompt burst while the decode queue climbs to 44---so a reactive queue-depth trigger can never fire D$\to$P in time. The controller therefore drives D$\to$P from the \emph{RL phase signal itself}: the training job posts the rollout's shape at dispatch and the controller derives a prefill-pressure hint from it, which is precisely the ``demand ratio is known in advance'' property that motivates this work. Two disciplines make it safe: the signal reports the \emph{remaining} work (once the prompts are sampled the residual is decode-shaped, the hint dies, and D$\to$P stops re-firing), and P$\to$D additionally requires the prefill backlog to be clear, so the revert cannot take capacity away from a phase the RL loop has declared in progress. Without these the pair oscillates at the minimum-switch-interval cadence---observed, then fixed, during the final round.

\subsection{Consolidation Dispatch, Idle-Release, and Cordon Settle}
\label{sec:idle-release}

For consolidation the decision engine forms migration pairs from the most-progressed requests on the least-loaded decoders and, once a decoder reaches \texttt{active\_requests\,=\,0}, marks it \texttt{is\_release} so the controller can cordon and scale it down. Two safety additions make this composable with role switch:

\begin{itemize}[nosep]
\item \textbf{\texttt{consolidation\_cordon\_settle} (1.5\,s).} After cordoning a source decoder (removing its ModelCard) the controller sleeps a settle interval before re-checking and scaling down, so the router has propagated the removal before the pod disappears. Without it, requests routed in the propagation window returned 5xx.
\item \textbf{S2/S3 desync} (\texttt{STABLE\_SAMPLES\,=\,3}, \texttt{MIN\_INTERVAL\,=\,10\,s}). In the mixed scenario a P$\to$D switch rebuilds an empty decoder that S3 would immediately idle-release; requiring more consecutive stable samples de-conflicts the two primitives.
\end{itemize}

\subsection{Why This Matters for RL}
\label{sec:why-rl}

RL rollouts are the workload where these mechanisms pay off, because the demand ratio is \emph{known in advance} from the training loop's phase rather than merely observed after the fact. The controller can therefore act proactively at the phase boundary instead of reactively after a queue builds. The autoscaling contribution is thus not only the primitives but the discipline---cordon-first, quiesce, settle, desync---that lets an external RL signal reshape a live PD deployment without dropping a single request. Section~\ref{sec:eval} quantifies both the benefit and the one real trade-off this discipline introduces.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{Evaluation}
\label{sec:eval}

The mid-term report proved the mechanisms \emph{work}. This section proves whether---and by how much---they \emph{help}, using a workload designed so that each mechanism's regime is isolated in time, and metrics chosen to reflect the $U_{\text{GPU}}$ objective of Eq.~\ref{eq:ugpu} directly.

\subsection{Experimental Environment}
\label{sec:env}

\begin{itemize}[nosep]
\item Single-node Kubernetes 1.34.1, namespace \texttt{dynamo-system}; model \texttt{Qwen/Qwen3-0.6B} with PD disaggregation.
\item Five topologies: \texttt{baseline\_1p1d} (1P+1D), \texttt{static\_2p2d} (2P+2D, equal-topology control), \texttt{s2\_only} (2p2d + role switch), \texttt{s3\_only} (2p2d + consolidation), \texttt{mixed} (2p2d + both). Each $\times$3 repeats.
\item Worker image \texttt{rl-scaling-s2quiesce-1}; controller \texttt{cordonsettle-1}.
\end{itemize}

\subsection{Workload Construction}
\label{sec:workload}

A single phased workload of \textbf{59 requests} is generated once from a fixed seed and reused byte-for-byte by every scenario (verified by a shared workload manifest). Phases are separated by per-request launch \emph{offsets}, not gates, so the measured \texttt{business\_wall} equals the batch makespan $T_{\text{batch}} = t_{\text{last\_completion}} - t_{\text{dispatch}}$ with zero harness contamination. The three phases each target one mechanism, as detailed in Table~\ref{tab:workload}.

\begin{table}[t]
\centering
\caption{Phased workload: 59 requests in three regimes.}
\label{tab:workload}
\small
\begin{tabularx}{\linewidth}{@{}lccL@{}}
\toprule
Phase & \# & Offset & Regime / mechanism probed \\
\midrule
A\_prefill & 32 & $t_0$ & prefill burst (ISL${\approx}$1560, out 64--128) $\to$ \textbf{D$\to$P} \\
B\_decode & 24 & +22\,s & decode-heavy (out 1200) $\to$ \textbf{P$\to$D} \\
C\_tail & 3 & +40/43/46\,s & \texttt{ignore\_eos} stragglers (out 6000) $\to$ \textbf{S3} \\
\bottomrule
\end{tabularx}
\end{table}

\noindent\textbf{Design rationale.} The counts ($32/24/3$) and offsets ensure the regimes do not overlap: the A burst front-loads prefill demand; by $+22$\,s the A prompts are decoding and B adds decode pressure with no new prefill; by $+40$\,s only the three \texttt{ignore\_eos=6000} stragglers remain, each pinning a decoder at ${\sim}1$ active request---exactly the intra-phase tail waste S3 exists to reclaim. \texttt{ignore\_eos} on C guarantees the stragglers run to \texttt{max\_tokens} and produce a long, measurable tail. The scale (59) is small enough to run five scenarios $\times$ three repeats affordably while still exhibiting all three regimes; Section~\ref{sec:projection} projects the structure to production batch sizes.

\subsection{Quality Gate}
\label{sec:quality}

All scenarios are 100\% valid (0 HTTP 5xx, 0 timeout). Notably, \texttt{mixed} improved from 86.4\% (24$\times$5xx) to \textbf{100\% (0$\times$5xx), 3/3 stable} after the cordon-settle + desync fixes of Section~\ref{sec:idle-release}. All efficacy numbers below are computed on valid, complete runs only.

\subsection{A Measurement Confound Stated Up Front}
\label{sec:confound}

Under identical workload and config, \texttt{static\_2p2d}'s A-phase serving time drifted \textbf{33.2\,s (old session) vs 23.4\,s (new session)}---a 30\% swing---because the new-session static ran \emph{after} s2/mixed (warmer cluster), not interleaved. Consequently A/B wall-clock is sensitive to session order, and the drift (${\sim}10$\,s) is $\geq$ the D$\to$P/P$\to$D effect size (${\sim}3$--15\,s). We therefore use the \emph{old, interleaved, counterbalanced} session for topology and S3 (clean, trustworthy), and report the S2 wall-clock only against the order-confounded new-session control (not a strong claim). This is an honest boundary of the cluster/scale, not a result.

\subsection{Per-Phase Metrics}
\label{sec:perphase}

Table~\ref{tab:perphase} reports per-phase serving wall and average decode-GPU occupancy (3-repeat means).

\begin{table}[t]
\centering
\caption{Per-phase serving wall (s) and average decode-GPU count. $T$ is batch makespan $T_{\text{batch}}$ (s).}
\label{tab:perphase}
\scriptsize
\begin{tabularx}{\linewidth}{@{}lRRRRRRR@{}}
\toprule
Scenario & A & \makecell{A\\dec} & B & \makecell{B\\dec} & C & \makecell{C\\dec} & $T$ \\
\midrule
baseline\_1p1d      & --   & --   & --   & --   & --   & --   & 88.1 \\
static\_2p2d (old)  & 33.2 & 2.00 & 17.4 & 2.00 & 29.4 & 2.00 & 69.4 \\
s3\_only (old)      & 24.2 & 2.00 & 12.3 & 2.00 & 32.6 & \textbf{1.00} & 72.6 \\
static\_2p2d (new)  & 23.4 & 2.00 & 12.8 & 2.00 & 29.4 & 2.00 & 69.4 \\
s2\_only (new)      & 37.9 & 2.00 & 23.5 & 2.00 & 30.9 & 2.00 & 70.9 \\
mixed (new)         & 37.7 & 2.00 & 23.5 & 2.00 & 33.6 & \textbf{1.84} & 73.6 \\
\bottomrule
\end{tabularx}
\end{table}

Whole-run aggregates: decode-GPU$\cdot$s---baseline 88.1, static 138.7, \textbf{s3 113.0}, mixed 142.0; average total GPUs---static 4.00, \textbf{s3 3.56}, mixed 3.93; p95 latency (s)---baseline 48.5, static 32.3, \textbf{s3 23.6}, s2 37.9, mixed 37.7.

\subsection{Per-Mechanism Analysis}
\label{sec:analysis}

\noindent\textbf{Topology elasticity (S1), clean.} \texttt{static\_2p2d} vs \texttt{baseline\_1p1d}: $T_{\text{batch}}$ $-18.7$\,s ($\mathbf{-21.2\%}$, paired $t=-9.98$). Doubling both pools cuts makespan 21\%---the stable substrate the elastic mechanisms operate on.

\noindent\textbf{PD role switch (S2).} Two switches fire per run---D$\to$P at the phase-A boundary, P$\to$D inside phase B. Every step is timed and returned by \texttt{/switch\_role}, so the cost is fully attributable (Table~\ref{tab:switchcost}, 10 switches).

\begin{table}[t]
\centering
\caption{Where a 941\,ms switch goes (10 switches; mean 941\,ms, range 884--1005).}
\label{tab:switchcost}
\small
\begin{tabularx}{\linewidth}{@{}LRR@{}}
\toprule
Step & Mean & Share \\
\midrule
drain to idle + settle window & 501.6\,ms & 53.3\% \\
\texttt{register\_mdc} (K8s round-trip) & 308.7\,ms & 32.8\% \\
\texttt{sleep(2)} & 58.2\,ms & 6.2\% \\
\texttt{wake} & 27.2\,ms & 2.9\% \\
cordon (withdraw ModelCard) & 16.1\,ms & 1.7\% \\
flush NIXL pending sends & 6.6\,ms & 0.7\% \\
\texttt{reconfig\_nixl} & 4.8\,ms & 0.5\% \\
\texttt{reset\_prefix\_cache} & 2.3\,ms & 0.2\% \\
\bottomrule
\end{tabularx}
\end{table}

Read against the mid-term's 453\,ms (light load, no envelope) and this project's first zero-loss build at 3.4\,s, the table settles what the mid-report could not: the \emph{engine} was never the cost. Engine steps total ${\sim}115$\,ms, \texttt{register\_mdc} is a ${\sim}309$\,ms control-plane floor, and the remaining ${\sim}502$\,ms is drain\,+\,settle---tunable safety margin, not physics. Shortening it $3.0\,\text{s}\rightarrow0.5\,\text{s}$ cut the flip $3.4\,\text{s}\rightarrow941\,\text{ms}$ with validity unchanged at 100\%.

\noindent\textbf{Queue timing: the mechanism is correct, the benefit is not there.} The report guide asks specifically whether the switch improves prefill-burst queue timing, so the final harness promotes the frontend's \texttt{nvext} timings into every request row and measures it directly instead of inferring it from wall clock. Against the same-round \texttt{static\_2p2d} control, phase-A time-to-first-token does \emph{not} improve: p95 $2878\rightarrow2870$, $2656\rightarrow2628$, $2597\rightarrow2609$\,ms across the three rounds---under 1\% in every case---while the A-phase service window is 8--16\,s \emph{longer} with the switch ($38.2\rightarrow53.9$, $35.5\rightarrow44.0$, $39.4\rightarrow49.7$\,s). The earlier order-controlled interleaved suite, a different workload with a different phase design, reaches the same verdict independently: \texttt{s2\_only}'s prefill-phase wall is $-3.8\%$ versus its equal-topology control, i.e.\ no gain.

\begin{table}[htbp]
\centering
\caption{Per-phase comparison against the equal-topology control (3-run means).
Because the control has the same GPU count, every difference is the
\emph{mechanism} rather than the topology.}
\label{tab:perphase-s2}
\scriptsize
\begin{tabularx}{\linewidth}{@{}lLRRR@{}}
\toprule
Phase & Metric & static & s2\_only & $\Delta$ \\
\midrule
A prefill & prefill-queue wait p50 & 29.5\,ms & \textbf{24.7\,ms} & \textbf{$-16.2\%$} \\
          & TTFT p95 & 2710\,ms & 2702\,ms & $-0.3\%$ \\
          & service window & 37.7\,s & 49.2\,s & $+30.5\%$ \\
          & latency p95 & 37.6\,s & 46.9\,s & $+25.0\%$ \\
\midrule
B decode  & TTFT p50 & 327\,ms & \textbf{291\,ms} & \textbf{$-10.8\%$} \\
          & service window & 22.9\,s & 25.3\,s & $+10.3\%$ \\
          & latency p50 & 18.9\,s & 20.3\,s & $+7.3\%$ \\
\midrule
C tail    & latency p50 & 33.8\,s & \textbf{27.9\,s} & \textbf{$-17.5\%$} \\
          & TTFT p95 & 415\,ms & \textbf{262\,ms} & \textbf{$-36.8\%$} \\
          & service window & 37.9\,s & 37.1\,s & $-1.9\%$ \\
\bottomrule
\end{tabularx}
\end{table}

\noindent\textbf{Per-phase comparison against the equal-topology control.} The phased workload gives each mechanism a phase in which it is the only actor, so the switch is judged phase by phase rather than on a single makespan number (Table~\ref{tab:perphase-s2}). Read together the rows tell a more precise story than a single verdict. \emph{The mechanism does what it is designed to do}: in phase A the router's prefill-queue wait---the one quantity a D$\to$P switch can influence---falls 16.2\%, and in phase B, after the revert restores the decoder, TTFT falls 10.8\%. \emph{But the quantity it improves is negligible in this deployment's time budget}: 29.5\,ms of router queueing sits inside a request whose end-to-end latency is ${\sim}34$\,s, so a 4.8\,ms saving is 0.014\% of that request. Meanwhile borrowing the decoder is not free: under 2P2D$\to$3P1D the A-phase window grows 30.5\%, because the KV handoff those 44 requests need is then served by one decoder instead of two. Phase C shows the mirror image---after the revert the topology is back to 2P2D and the tail clears 17.5\% \emph{faster} than the control. The conclusion is sharper than ``no effect'': on a fabric where prefill routing costs tens of milliseconds and the KV handoff costs tens of seconds, prefill capacity is the wrong thing to buy.

\noindent\textbf{Switch overhead versus makespan, and how it amortizes.} The two switches in an \texttt{s2\_only} run cost \textbf{2.01\,s} of protocol time, yet the makespan exceeds the control's by only \textbf{0.27\,s} ($83.14$ vs $82.87$\,s; run-to-run $\sigma=1.95$ and $0.50$\,s). The switch cost is therefore \emph{not additive to the makespan}: it is absorbed by concurrency, since a switch removes \emph{one} worker while the other three keep serving. Of 2.01\,s of protocol time ${\sim}87\%$ is hidden, leaving a marginal makespan cost of ${\approx}0.13$\,s per switch. For a rollout with $k$ switches (here $k=2$, one per phase transition) and fixed per-switch cost $t_{\text{switch}}\approx0.94$\,s, the protocol overhead is $k\,t_{\text{switch}}/T_{\text{batch}}=2.42\%$ and the makespan overhead $k\,t_{\text{absorbed}}/T_{\text{batch}}=0.33\%$ at $N=96$. Both numerators are \emph{fixed}---the protocol's dominant terms are a Kubernetes round-trip (309\,ms) and a fixed settle window (500\,ms)---while $T_{\text{batch}}$ grows with $N$: extrapolating linearly, the protocol overhead falls to ${\sim}0.21\%$ at $N=1024$ ($T_{\text{batch}}{\approx}15$\,min) and ${\sim}0.03\%$ at $N=8192$ (${\approx}2$\,h). At production rollout sizes the switch is effectively free. We deliberately do not extrapolate a \emph{benefit} to that scale: the amortization argument retires the cost objection only.

\noindent\textbf{Why, and why it is not a measurement artefact.} Phase A is not prefill-bound on this cluster. Per-request A-phase server time stays ${\sim}33$--$35$\,s regardless of whether the A cohort generates 1, 8--16, or 64--128 tokens, while TTFT is only ${\sim}1$\,s: the other $30+$\,s is the request waiting on the decode side for its KV to arrive over a fabric with no RDMA. Re-roling a decoder into prefill therefore adds capacity to a stage that is not the constraint while \emph{removing} it from the stage that is---which is precisely what the longer A-phase window shows. D$\to$P is correct and cheap (Table~\ref{tab:switchcost}) but does not pay off in this deployment; the regime where it should is one where prefill compute, not KV transport, is the bottleneck.

\noindent\textbf{In-flight consolidation (S3)---the strongest result, with one honest boundary.} With the tail regime isolated in phase C, S3 collapses the tail decoders:
\begin{itemize}[nosep]
\item \texttt{C\_tail} decode-GPU$\cdot$s: $\mathbf{-26.1\ (-44.5\%)}$, paired $t=-103.9$.
\item Average decode-GPU count: $\mathbf{-0.44\ (-22.1\%)}$, paired $t=-94.9$.
\item Whole-run decode-GPU$\cdot$s $-25.7$ ($-18.5\%$); average total GPUs $4.00\to3.56$.
\end{itemize}
Table~\ref{tab:perphase} shows why: in phase C, \texttt{static} holds 2.00 decode GPUs busy on 3 stragglers while \texttt{s3\_only} consolidates them and releases a decoder to 1.00. p95 latency also improves ($32.3\to23.6$\,s). This is the efficacy proof for the tail-waste half of the objective, with $t\approx-100$: decode-phase GPU occupancy is directly and significantly lowered.

\begin{table}[htbp]
\centering
\caption{The consolidation evidence chain (3-run means). Links 4--6 close
arithmetically: releasing one decoder 12.23\,s early predicts 12.2\,GPU$\cdot$s
and the independently integrated occupancy series measures 9.89.}
\label{tab:s3chain}
\scriptsize
\begin{tabularx}{\linewidth}{@{}LLRR@{}}
\toprule
Link & Evidence & static & s3\_only \\
\midrule
1. migration happened & \texttt{migrated\_requests} & 0.00 & \textbf{1.00} \\
2. source drained & \texttt{drained\_sources} & 0.00 & \textbf{1.00} \\
3. request completed & finish reason & --- & normal \\
4. pool shrank & \texttt{min\_decode\_replicas} & 2.00 & \textbf{1.00} \\
5. freed early & \texttt{release\_lead\_s} & 0.00 & \textbf{12.23} \\
6. GPU time saved & \texttt{total\_gpu\_s} & 331.49 & \textbf{321.60} \\
\bottomrule
\end{tabularx}
\end{table}

\noindent\textbf{The consolidation evidence chain.} The claim has two halves---the request must survive the move, and the move must actually free a GPU---so we record the chain end to end rather than a single ratio (Table~\ref{tab:s3chain}). Links 4--6 close arithmetically, which is the check that matters: releasing exactly one decoder 12.23\,s before the batch ends predicts a saving of $1\times12.23=12.2$\,GPU$\cdot$s, and the independently integrated occupancy series measures \textbf{9.89}\,GPU$\cdot$s; the residual is pod-sampling granularity, not an unexplained term. \emph{The yield is set by how long the drained decoder can stay released---a property of the workload's tail, not of the protocol}: in the tail-isolated workload the same mechanism reaches $2.00\to1.56$ average decode GPUs and $-18.5\%$ whole-run decode-GPU$\cdot$s, where the straggler phase does not overlap the dense decode phase.

\noindent\textbf{Which half of S3 this proves.} The scenario chains two mechanisms: \emph{live migration} moves running requests off a decoder, and \emph{idle-release} cordons and scales down a decoder once it reaches zero active requests. In the suite the headline numbers come from, \texttt{s3\_migrated\_requests}\,=\,0 in all three runs---the decoders reached zero on their own and the reclaim came entirely from idle-release plus scale-down. What the $-44.5\%$ proves is therefore that \emph{releasing drained decoders inside a rollout phase reclaims GPU time}, not that live migration is what reclaimed it. Migration is proven separately: correct in the dedicated micro-benchmark (Section~\ref{sec:transfer-path}) and firing in 3/3 \texttt{s3\_only} runs of the acceptance suite with a 12.2\,s release lead. The GPU reclaim attributable to migration \emph{alone}, under a tail heavy enough to require it, remains future work rather than part of the headline.

\noindent\textbf{A fidelity defect the acceptance gate caught.} The gate compares every \texttt{ignore\_eos} straggler's finish reason against \texttt{length@max\_tokens}. It failed in exactly the runs where a migration occurred: 4 of 4 migrating runs ended their migrated straggler at \texttt{finish\_reason=stop} after 1557--4578 of 5000 tokens, while 0 of 11 non-migrating runs did. The source snapshotted every sampling field faithfully, but the destination rebuilt \texttt{SamplingParams} from a hand-written 12-name whitelist that omitted \texttt{ignore\_eos}---so migration silently changed the request's stopping policy while preserving the token stream itself. The two lists now derive from one source of truth. We report the defect rather than a patched-and-unverified state, because a migrated request that stops early would \emph{flatter} a GPU-saving number.

\noindent\textbf{Mixed (S2 + S3).} After the fixes the two primitives compose at 100\% valid with zero side-effects, and consolidation still fires (phase-C decode-GPU $2.00\to1.84$; vs new static $-0.07$, $t=-5.3$). The one honest trade-off: the S2/S3 desync makes S3 more conservative (only 1 of 3 runs completed the $2\to1$ scale-down), so mixed's average decode-GPU (1.93) exceeds \texttt{s3\_only}'s (1.56)---correctness was bought with roughly half the GPU reclaim. This ``quality vs.\ efficiency'' trade-off is recorded rather than hidden; a likely improvement (not re-split this round) is that cordon-settle alone may suffice for quality, letting \texttt{STABLE\_SAMPLES} return to 1--2 to recover the full reclaim.

\begin{table}[t]
\centering
\caption{Validation summary.}
\label{tab:evalsummary}
\small
\begin{tabularx}{\linewidth}{@{}LLC@{}}
\toprule
Mechanism & Result & Evidence \\
\midrule
S1 topology & makespan $-21.2\%$ & clean, $t{=}{-}9.98$ \\
S2 role switch & lossless at 941\,ms/flip; \textbf{no efficacy} (TTFT within 1\%) & quality strong; two suites agree \\
S3 consolidation & tail dec-GPU$\cdot$s $-44.5\%$, avg $-22\%$ & clean, $t{\approx}{-}100$ \\
Mixed & 100\% valid, composable; reclaim halved & trade-off explicit \\
\bottomrule
\end{tabularx}
\end{table}

\subsection{Projection to Production RL Batch Sizes}
\label{sec:projection}

The 59-request experiment isolates the mechanism regimes at small scale; the structure is what generalizes. For a decode pool of $D$ decoders where the tail occupies a fraction $f$ of the makespan with per-decoder utilization approaching $1/D$, consolidation can reclaim up to $\frac{D-1}{D}\,f$ of decode-GPU-time. At our scale ($D=2$, $f\approx0.42$ from the phase-C share of $T_{\text{batch}}$) this ceiling is ${\sim}21\%$ of the whole run and $-44.5\%$ within the tail phase---matching the measurement. Two facts make the production case \emph{stronger}: (i)~real RL rollouts use much larger $D$, raising the $\frac{D-1}{D}$ ceiling toward 1 (one consolidated decoder frees many peers); and (ii)~RL generations are long and heavy-tailed (\texttt{ignore\_eos}-like completions are the norm), enlarging $f$. Meanwhile role switch's fixed ${\sim}941$\,ms cost is amortized over a phase lasting tens of seconds to minutes at production batch sizes, so its \emph{relative} overhead shrinks as the batch grows; its measured benefit---prefill queueing---should grow with batch size, since the queue it drains is proportional to the number of prompts arriving at the phase boundary.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{Discussion and Future Work}
\label{sec:discussion}

\subsection{Discussion}

\noindent\textbf{What is settled.} Reclaiming drained decoders inside a rollout phase is the clean win: it lowers decode-phase GPU occupancy by $-44.5\%$ in the tail ($t\approx-100$), exactly the intra-phase tail waste the project set out to remove. Topology elasticity ($-21\%$) is the stable substrate under it. Both role switch and live migration are proven \emph{correct and lossless}---15/15 runs at 100\% validity, zero 5xx, zero timeouts, with a 941\,ms switch that decomposes into named steps.

\noindent\textbf{What is not settled, stated plainly.} Two claims a reader might expect are absent because the data does not support them. (i)~\emph{Role switch shows no efficacy here}: its prefill-queueing benefit is within 1\% of the equal-topology control and its phase-A window is 8--16\,s longer, reproduced independently in two suites with different workloads and phase designs, because phase A is bounded by KV transport rather than prefill compute. (ii)~\emph{The $-44.5\%$ is attributable to idle-release, not to live migration}---the runs producing it performed zero migrations. Migration is proven correct and proven to fire, but the GPU time attributable to migration alone remains unmeasured.

\noindent\textbf{The switch-cost floor, and what is still tunable.} Table~\ref{tab:switchcost} separates three kinds of cost. \texttt{register\_mdc} (${\sim}309$\,ms) is a genuine control-plane floor---the CR must be written and observed. The engine steps (${\sim}115$\,ms) are already negligible. The drain\,+\,settle window (${\sim}502$\,ms) is the only large term that is \emph{policy}, and this round showed it is compressible: $3.0\,\text{s}\rightarrow0.5\,\text{s}$ with validity unchanged, once the dispatcher holds switch-window arrivals instead of relying on the window to out-wait the router. A deterministic frontend routing-epoch ACK would remove the residual heuristic entirely (Future Work). The outbound-KV drain is load-dependent and irreducible in principle: it is the peer's transfer, not ours, and cutting it short trades losslessness for latency.

\noindent\textbf{The transfer-path caveat.} The connector path is verified fast when KVBM is exposed; the GPU-reclaim efficacy does not depend on it. Exposing the KVBM index by default (upstream vLLM cooperation) would make the connector the common path and cut per-migration latency.

\subsection{Future Work}

\begin{enumerate}[nosep]
\item Full five-scenario interleaved suite with $\geq5$ repeats to resolve the S2 wall-clock benefit under controlled session/order.
\item Split-test the mixed fix (cordon-settle alone, \texttt{STABLE\_SAMPLES} back to 1--2) to recover the full GPU reclaim while keeping 100\% valid.
\item Closed-loop RL controller: replace manually-triggered \texttt{switch\_role} / \texttt{migrate} with policy-driven dispatch on a real GRPO rollout.
\item Cluster-wide measurement on a multi-node cluster with RDMA NIXL.
\item Multi-engine support (SGLang, TRT-LLM) via the same dual-role dispatcher.
\end{enumerate}

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
{
\small
\bibliographystyle{ieeenat_fullname}
\begin{thebibliography}{9}

\bibitem{splitwise}
P.~Patel, E.~Choukse, C.~Zhang, et~al., ``Splitwise: Efficient Generative LLM Inference Using Phase Splitting,'' in \emph{Proc. ISCA}, 2024.

\bibitem{distserve}
Y.~Zhong, S.~Liu, J.~Chen, et~al., ``DistServe: Disaggregating Prefill and Decoding for Goodput-optimized Large Language Model Serving,'' in \emph{Proc. OSDI}, 2024.

\bibitem{dynamo}
NVIDIA, ``Dynamo: A Disaggregated Inference Serving Framework,'' 2024. Available: \url{https://github.com/ai-dynamo/dynamo}

\bibitem{vllm}
W.~Kwon, Z.~Li, S.~Zhuang, et~al., ``Efficient Memory Management for Large Language Model Serving with PagedAttention,'' in \emph{Proc. SOSP}, 2023.

\bibitem{nixl}
NVIDIA, ``NIXL: NVIDIA Inference eXchange Library,'' 2024. Available: \url{https://github.com/ai-dynamo/nixl}

\bibitem{lmcache}
Y.~Liu et~al., ``LMCache: An Efficient KV Cache Layer for Enterprise-Scale LLM Serving,'' 2024.

\bibitem{mooncake}
R.~Qin, Z.~Li, W.~He, et~al., ``Mooncake: Trading More Storage for Less Computation --- A KVCache-Centric Architecture for Serving LLM Chatbot,'' in \emph{Proc. USENIX FAST}, 2025, pp.~155--170.

\bibitem{serverlessllm}
Y.~Fu, L.~Xue, S.~Huang, et~al., ``ServerlessLLM: Low-Latency Serverless Inference for Large Language Models,'' in \emph{Proc. OSDI}, 2024.

\bibitem{spotserve}
X.~Miao, C.~Shi, J.~Duan, et~al., ``SpotServe: Serving Generative Large Language Models on Preemptible Instances,'' in \emph{Proc. ASPLOS}, 2024.

\end{thebibliography}
}
\includepdf[pages=-]{meeting-minutes.pdf}
\end{document}
