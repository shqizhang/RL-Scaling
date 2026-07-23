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

Beyond confirming correctness, we evaluate efficacy on a Kubernetes deployment of \texttt{Qwen3-0.6B} with a phased workload that isolates each mechanism's regime in time, run across five topologies ($\times3$ repeats, interleaved and counterbalanced) and gated by eight automated acceptance checks. Because the elastic scenarios run at the same GPU count as a static control, every reported difference is attributable to the mechanism rather than to added resources. All 15 accepted runs are 100\% valid with zero HTTP errors and zero timeouts. Against that control, consolidation reclaims decode GPUs inside the rollout: the decode pool contracts from 2.00 to 1.00 replicas, the released GPU is freed $12.2$\,s before the batch ends, and whole-run GPU time falls by $9.9$\,GPU$\cdot$s---closing arithmetically against the $12.2$\,GPU$\cdot$s the release predicts---rising to $-44.5$\% of tail-phase decode-GPU$\cdot$s ($t=-103.9$) when the straggler phase is isolated. A role switch completes in $941$\,ms (range $884$--$1005$) with zero request loss, and costs only $0.27$\,s of additional makespan because the protocol time is absorbed by concurrency. We also report two boundaries the data imposes: role switching improves the quantity it targets (prefill routing wait $-16.2$\%) but that quantity is negligible on a fabric where KV transport, not prefill compute, bounds the burst; and the tail reclaim is attributable to releasing drained decoders, since the runs producing it performed no live migration.
\end{abstract}

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{Introduction}
\label{sec:intro}

The cost of large-language-model inference is measured in GPU-hours, and the dominant architectural answer to that cost is prefill--decode (PD) disaggregation: the two phases of a request have different bottlenecks, so they are served by separate GPU pools connected by a high-bandwidth KV fabric. NVIDIA Dynamo is the de-facto open-source realisation of that architecture---a Rust runtime that routes requests across prefill and decode worker pools and discovers those workers through Kubernetes Custom Resources---and it is the system this work extends. Section~\ref{sec:dynamo-arch} describes the three of its subsystems that the design depends on.

This paper concerns a workload for which that architecture is mis-provisioned by construction: the reinforcement-learning rollout loop. We show that its characteristic waste can be removed by changing a deployment's \emph{shape} rather than its \emph{size}, and we develop, deploy and measure two runtime primitives that do so.

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
\item (C1) A two-layer in-place role-switch protocol: a three-stage zero-loss envelope
(cordon, drain and settle, outbound-KV drain) that establishes the preconditions for a role
flip, enclosing a five-stage engine core that performs it. It transitions a worker between
decode and prefill roles without a pod restart or an engine rebuild, and without losing a
request either on the worker or on a peer exchanging KV with it.
\item (C2) A single-TCP-slot dispatcher for partner-prefill that lets the same vLLM engine serve both decode and prefill traffic at run-time without socket re-binding.
\item (C3) A three-phase block-hold NIXL-pull migration protocol that consolidates running decoders with zero KV loss, bounded by a safety-net sweep timer.
\item (C4) An RL-signal-driven autoscaling controller that dispatches the above primitives with a cordon-first quiesce/settle discipline that makes them composable without dropping requests.
\item (C5) A phase-attributed evaluation in which every elastic scenario is compared against a static control at identical GPU count, gated by eight automated acceptance checks that rejected six suites before one was analysed. It establishes correctness (15/15 runs 100\% valid, zero 5xx, zero timeouts), quantifies consolidation end to end (decode replicas $2.00\to1.00$, GPU released $12.2$\,s early, whole-run $-9.9$\,GPU$\cdot$s, rising to $-44.5\%$ of tail decode-GPU$\cdot$s when the tail is isolated), and bounds the switch cost ($941$\,ms protocol, $0.27$\,s makespan), while reporting where the data refuses a claim.
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

Three of Dynamo's subsystems determine what an in-place elasticity mechanism can and cannot do, and we introduce each together with the consequence this work relies on.

\noindent\textbf{Discovery: membership is metadata.} One Kubernetes Custom Resource per worker pod is the single source of truth for membership. Each worker strategic-merge-patches its own CR and the frontend's \texttt{ModelWatcher} reconstructs the WorkerSet by \texttt{list+watch}; there is no etcd and no central registry. \emph{Consequence:} a role change is a single metadata mutation visible to the whole system, so it needs neither a pod restart nor an engine rebuild---the property the switch protocol is built on.

\noindent\textbf{Routing: the routers are stateful.} \texttt{KvRouter} maintains a radix-tree index over the KV blocks held by each decoder and scores candidates by prefix-overlap, queue load and remaining capacity; \texttt{PrefillRouter} fans prefill traffic to any prefill-role worker discovered through the CRs. \emph{Consequence:} that state must reconverge after every role change, and because convergence is eventually consistent, a worker keeps receiving old-role traffic for a short interval after it is withdrawn. Absorbing that interval safely is the central difficulty of Section~\ref{sec:protocol}.

\noindent\textbf{Transport: KV is addressable across GPUs.} The NIXL connector performs zero-copy KV transfer, selecting a transport per pair of endpoints from those actually reachable between them, and the KV-Block Manager tracks the per-request block layout. Which transport is selected on the deployment measured here, and why it matters for the results, is established in Section~\ref{sec:transport}. \emph{Consequence:} one decoder can read another's KV blocks directly from VRAM, which is what makes migrating a \emph{running} request feasible at all (Section~\ref{sec:three-phase}).

\subsection{KV Cache, Prefix Caching, and the Coherence Problem}
\label{sec:kv-cache}

Decode is only affordable because the keys and values of every prior token are retained: the KV cache turns a quadratic re-computation into an incremental one. Prefix caching~\cite{lmcache} extends the same idea across requests, reusing blocks whenever two prompts share a prefix. The implementation detail that matters for this work is that vLLM~0.16 splits the structure in two: an \emph{index} in CPU memory that maps token prefixes to block identifiers, and the \emph{blocks} themselves, pinned in GPU VRAM.

That split is what makes an in-place role change delicate. Reclaiming a worker's GPU memory (via \texttt{engine.sleep(level=2)}) returns the blocks to the allocator but leaves the index intact, so the two halves can disagree: an index entry may point at a block that now belongs to a different request. A hit on such an entry after wake-up would silently splice another request's state into the current one. Any protocol that cycles the engine must therefore treat the index and the blocks as a single object and re-establish their agreement while the engine is quiescent---the constraint developed in Section~\ref{sec:ordering}. The same split has a second consequence used later: because the blocks are addressable GPU memory, a peer worker can read them directly over NIXL, which is the mechanism that makes live request migration possible at all (Section~\ref{sec:three-phase}).

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

Cluster scaling is the foundation the other two primitives stand on. It does not avoid cold start; it moves the cost outside the phase that is being optimised. The rollout's first phase signal takes the controller from \texttt{IDLE} to \texttt{WARM\_UP}, where replicas are raised and the engines load; only when the workers report Ready does the controller enter \texttt{ACTIVE}, and between consecutive batches a cooldown grace period keeps the pods warm rather than releasing them. Role switching and consolidation therefore always act on already-running engines, which is what makes their sub-second and few-second costs meaningful---an equivalent reaction by pod replication would pay tens of seconds of cold start and start with an empty prefix cache. Figure~\ref{fig:rl-controller} shows the resulting control plane.



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

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{Elastic PD Role Switching}
\label{sec:role-switch}

\subsection{Problem Definition}
\label{sec:switch-problem}

Consider a running disaggregated deployment with $D$ decoder pods and $P$ prefill pods
behind a single frontend. At a rollout phase boundary the controller must convert a
specific decoder $D_i$ into a prefill worker, and later convert it back. A call to
\texttt{POST~<$D_i$>/switch\_role} must satisfy six requirements. Five of them define
what a role change \emph{is}:

\begin{enumerate}[nosep]
\item \textbf{Withdrawal.} The frontend's \texttt{KvRouter} stops selecting $D_i$ for
decode traffic, because its decode ModelCard is removed from the worker's CR.
\item \textbf{Release.} $D_i$'s decode-side transient KV state is released, so the new
role begins with a clean prefix-cache index and the full block budget.
\item \textbf{Admission.} $D_i$ subsequently serves prefill traffic dispatched by the
frontend's \texttt{PrefillRouter}, as a first-class member of the prefill WorkerSet.
\item \textbf{Symmetry.} A reverse call with \texttt{target\_role="decode"} restores the
previous condition by the same protocol, with no special-cased inverse path.
\item \textbf{Invariance.} Pod name, IP address, engine identity and prefix-cache
infrastructure are unchanged; only the role registered in the CR and the engine's
transient state are mutated.
\end{enumerate}

\noindent The sixth constrains what may happen \emph{while} the change takes place:

\begin{enumerate}[nosep, start=6]
\item \textbf{Losslessness.} No request may be lost---neither one in flight on $D_i$ nor
one on a peer that is exchanging KV with it---at any point in the transition.
\end{enumerate}

Requirements~1--5 could be met by a short sequence of engine and registry calls.
Requirement~6 cannot, because two of the transition's effects are not instantaneous: the
withdrawal in~(1) reaches the routers only after the discovery layer converges, and the
release in~(2) reclaims memory that a peer may still be reading. The protocol is
therefore a state machine, structured as a safety envelope that establishes the
preconditions for a role flip, enclosing an engine core that performs it.

\subsection{The Switch Protocol}
\label{sec:protocol}

\noindent\textbf{What makes an in-place flip possible.} Three properties of the stack
keep the protocol short. First, every dual-mode worker is constructed with
\texttt{NixlConnector kv\_both}, so the engine registers NIXL metadata for both prefill-
and decode-side semantics at boot; since \texttt{kv\_transfer\_config} is otherwise fixed
at construction, this is what avoids an engine rebuild. Second, the worker registers a
single TCP handler and selects between the decode and partner-prefill paths at request
time on its current role, so a switch never rebinds a socket---it only renames the entry
the frontend observes. Third, membership is metadata (Section~\ref{sec:dynamo-arch}), so
publishing and withdrawing a role is a CR mutation rather than a topology change. What
the third property costs is that the mutation is seen only eventually, which is the
condition the envelope exists to absorb.

\texttt{DualModeWorker.switch\_role(target)} runs under a per-worker asynchronous lock
and proceeds through eight timed stages, each surfaced in the response's
\texttt{timings\_ms} field: three envelope stages (E1--E3) followed by five core stages
(C1--C5), with one untimed transition between them. Figure~\ref{fig:role-switch} shows
the sequence, which is also the order in which we describe it.

\noindent\textbf{E1 --- Cordon.} The worker withdraws its current-role ModelCard from its
CR. This closes the intake, and because propagation to the routers is eventually
consistent, it is done first so that convergence overlaps everything that follows.

\noindent\textbf{E2 --- Drain and settle.} The worker waits for its in-flight requests to
finish naturally, then requires the engine to remain idle for a continuous observation
window. Any arrival during the window restarts it, so the condition asserts that the
routers have stopped selecting this worker---not merely that the engine is momentarily
idle. Requests that do arrive in this interval are not rejected: between E1 and C4 the
routers can only be acting on the old ModelCard, so such a request is old-role traffic by
construction, and the request-time dispatcher suspends it until the switch completes and
then serves it under the pre-switch role. Losslessness is thereby a property of the
protocol rather than of waiting long enough, which is what permits a short window.

\noindent\textbf{E3 --- Outbound-KV drain.} If the worker has been serving prefill, peers
may still be reading KV it produced. The worker polls the connector's pending-send
registry and the block pool's pinned state until neither reports outstanding work, under
a bound; whatever remains at the bound is an orphan no peer claimed and is expired. Only
now is it safe to release GPU memory (Section~\ref{sec:ordering}, constraint~4).

\noindent\textbf{C1--C3 --- Cycle the engine.} \texttt{sleep(level=2)} pauses generation
and returns the KV blocks to the allocator; \texttt{reconfig\_nixl} rebinds the connector
handle for the target role; and \texttt{reset\_prefix\_cache} clears the cache index while
the engine is asleep, so index and blocks are made consistent atomically with respect to
the scheduler.

\noindent\textbf{Role commit (untimed).} The handler's role marker and the dispatcher's
view are updated together, so the worker is internally in the target role before any
target-role traffic can reach it.

\noindent\textbf{C4--C5 --- Republish and resume.} \texttt{register\_mdc} publishes a
fresh ModelCard under the target-role endpoint URI, admitting the worker to the new
WorkerSet, and \texttt{wake} resumes the engine.

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
\node[env] (c) {E1 cordon};
\node[env, below=of c] (d) {E2 drain + settle};
\node[env, below=of d] (k) {E3 outbound-KV drain};
\node[core, below=of k] (sl) {C1 sleep(2)};
\node[core, below=of sl] (rn) {C2 reconfig\_nixl};
\node[core, below=of rn] (rp) {C3 reset\_prefix};
\node[core, below=of rp] (rg) {C4 register\_mdc};
\node[core, below=of rg] (w) {C5 wake};
\draw[arr] (c) -- (d);
\draw[arr] (d) -- (k);
\draw[arr] (k) -- (sl);
\draw[arr] (sl) -- (rn);
\draw[arr] (rn) -- (rp);
\draw[arr] (rp) -- (rg);
\draw[arr] (rg) -- (w);
\node[ann, right=3mm of c]  {withdraw the old-role ModelCard \emph{first}};
\node[ann, right=3mm of d]  {in-flight work finishes; continuous idle confirms the router converged};
\node[ann, right=3mm of k]  {no peer still pulling KV we produced};
\node[ann, right=3mm of sl] {frees the GPU KV blocks};
\node[ann, right=3mm of rp] {reset while asleep: no stale hit};
\node[ann, right=3mm of rg] {publish only in the target role};
\node[ann, right=3mm of w]  {engine resumes in the target role};
\end{tikzpicture}
\caption{The \texttt{switch\_role} protocol: a three-stage zero-loss envelope (E1--E3, blue) that establishes the preconditions for a role flip, enclosing a five-stage engine core (C1--C5, green) that performs it. Requests arriving between E1 and C4 are held by the dispatcher and served under the pre-switch role. Per-stage costs are reported in Section~\ref{sec:eval}.}
\label{fig:role-switch}
\end{figure}

\subsection{Ordering Constraints}
\label{sec:ordering}

Four orderings make the protocol safe. Each states an invariant, and each rules out a
distinct failure.

\noindent\textbf{(1) Withdraw before draining.} Removing the ModelCard is what closes the
intake, and its effect is eventually consistent. Draining behind a published card lets
the routers refill the worker, so the drain never terminates on a busy deployment.

\noindent\textbf{(2) Drain and confirm before sleeping.} \texttt{sleep(2)} does not
guarantee that running requests finish. Their blocks retain a non-zero reference count, so
the subsequent cache reset cannot free them and the new role starts with a diminished
block budget.

\noindent\textbf{(3) Reset the cache inside the sleep window, and publish only after.}
Sleeping returns cached blocks to the allocator while the index still references them, so
a reset after wake races a new request onto a block that has been reused; performed while
the engine is asleep, the reset is atomic from the scheduler's perspective. Symmetrically,
the new ModelCard is published only once the engine is already in the target role, so
traffic arriving on it can be served.

\noindent\textbf{(4) Never sleep while a peer is reading our KV.}
\texttt{sleep(level=2)} frees GPU memory. If a peer decoder's NIXL read against this
worker's KV is still in flight, sleeping destroys the transfer and the peer's request
stalls until its client timeout. Force-expiring the connector's pending sends is equally
destructive for a send a peer is about to read. The protocol therefore waits for the
transfers to complete and expires only what no peer claimed, which is why E3 precedes C1.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{In-Flight Decoder Request Consolidation}
\label{sec:consolidation}

\subsection{Problem Definition}
\label{sec:consol-problem}

Role switching can shrink the decoder pool only when the target decoder has no live
requests, and a switch issued mid-flight terminates whatever is running. Near the end of a
rollout that is exactly the wrong property: a handful of long completions, each holding
thousands of already-generated tokens, are scattered one per decoder. We therefore need an
operator-callable primitive that moves a \emph{running} request from one decoder to
another, leaving the source drainable, with no KV state lost or corrupted---and, since a
migrated request is only useful if the freed GPU is actually reclaimed, a path from
``source is drained'' to ``GPU is released''.

\subsection{The Three-Phase Block-Hold Protocol}
\label{sec:three-phase}

The protocol moves a request $R$ from a source decoder $D_{\text{src}}$ to a destination
decoder $D_{\text{dst}}$ in three coordinated phases (Figure~\ref{fig:migration}). Its
defining property is that $D_{\text{src}}$ keeps $R$ alive and its KV blocks pinned across
the entire handshake, releasing them only after $D_{\text{dst}}$ has confirmed acceptance.

\noindent\textbf{Phase 1 (Block-Hold).} The orchestrator calls \texttt{migrate\_out} on
$D_{\text{src}}$, which pins the KV blocks of $R$, registers $R$ in its pending-migration
table, and collects the source block identifiers, the transfer coordinates of the local
NIXL agent, the sampling parameters and the count of already-emitted tokens---but does
\emph{not} abort $R$. It returns these to the orchestrator.

\noindent\textbf{Phase 2 (Pull).} The orchestrator passes them to \texttt{migrate\_in} on
$D_{\text{dst}}$. The destination applies a cost--benefit gate, injects the transfer
parameters into a new request and submits it locally; the connector then reads the KV
blocks from $D_{\text{src}}$'s memory and decoding resumes from the token after the last
one already emitted, so the client observes a single continuous stream across the
boundary. Reconstructing the \emph{complete} sampling configuration is a correctness
requirement rather than a detail: if any field is dropped---a stopping policy, in
particular---the migration silently alters the request's semantics while appearing to
succeed.

\noindent\textbf{Phase 3 (Release).} The orchestrator calls \texttt{migration\_complete}
on $D_{\text{src}}$, which aborts $R$, unpins its blocks and clears the pending entry.

\noindent\textbf{The at-least-one-copy invariant.} No transition leaves the request
without an authoritative KV copy. If the orchestrator fails between Phases~2 and~3 the
source has not aborted, so the failure degrades to at-most-once duplicate emission rather
than KV loss; a background sweep force-completes any hold older than a bounded age, so a
crashed orchestrator cannot pin blocks indefinitely. The two-phase alternative---abort on
\texttt{migrate\_out}, then submit on \texttt{migrate\_in}---is unsafe under a pull
transport, because the source's blocks are freed and may be reused before the
destination's read completes. The three-phase form converts a two-party race into a
sequential handshake.

\begin{figure}[htbp]
\centering
\includegraphics[width=\linewidth]{request-consolidation.png}
\caption{Three-phase block-hold migration. The source keeps the request alive and its blocks pinned for the whole handshake, so an authoritative KV copy exists at every instant. The read is issued through NIXL, whose transport is selected per agent pair (Section~\ref{sec:transport}); recompute is the fallback when the block index is unavailable. The stage that reclaims the GPU follows in Section~\ref{sec:idle-release-mech}.}
\label{fig:migration}
\end{figure}

\subsection{What Actually Carries the KV}
\label{sec:transport}

The protocol is written against \emph{read} semantics---the destination fetches from the
source's memory---and is deliberately indifferent to how that read is realised. Realising
it is NIXL's responsibility, and understanding the abstraction matters for interpreting
the evaluation.

NIXL is configured with the UCX backend, and UCX selects a transport per agent pair at
connection time from those actually reachable between the two endpoints, in descending
order of capability: intra-node device-to-device paths (CUDA IPC over NVLink), RDMA over
an InfiniBand or RoCE device, and TCP as the universal fallback. The protocol issues the
same read regardless; only the achieved bandwidth differs.

On the deployment measured here the selected transport is \textbf{TCP}. Each worker is a
single-GPU pod in its own network namespace, so the NVLink peer-to-peer path---present on
the hardware and benchmarked at 48\,GB/s---is not reachable across the pod boundary, and
the cluster exposes no InfiniBand or RoCE device. Direct measurement confirms the
fallback: \texttt{ucx\_perftest} moves GPU-resident buffers at 2.9\,GB/s, against
3.76\,GB/s for host-to-host TCP on the same link. We state this explicitly because it
bounds what any scheduling mechanism in this system can achieve, and Section~\ref{sec:eval}
returns to it: on this fabric the time a request spends waiting for its KV dominates the
time it spends being computed, which is a property of the transport rather than of the
policies being evaluated.

Two consequences follow for the design. First, migration cost scales with the KV volume
moved, so the destination's admission gate---which declines a migration whose replay cost
exceeds its benefit---is load-bearing rather than defensive. Second, because the
mechanism's value comes from releasing a decoder rather than from the speed of the
transfer, the reclaim reported in Section~\ref{sec:eval} does not depend on which
transport UCX selected; a faster fabric would shorten the handshake, not change its
outcome.

\subsection{Selecting the Request and the Destination}
\label{sec:mig-strategy}

Each worker maintains an in-process registry of its active requests, updated at
submission, on every streaming delta and at completion. Source-side victim selection picks
the most-progressed request, which maximises the replay cost avoided per migration.
Destination-side admission declines when the replay cost exceeds a threshold or too few
tokens remain to justify the transfer. The controller ranks candidate peers by load and
chooses the least-loaded decoder with spare KV capacity.

\subsection{From a Drained Decoder to a Reclaimed GPU}
\label{sec:idle-release-mech}

Migration makes a decoder drainable; it does not by itself return the GPU. The controller
completes the chain: once a decoder reports no active requests it is marked for release,
its ModelCard is withdrawn, and---after a settle interval that lets the withdrawal
propagate to the routers---its Deployment replica count is decremented. The settle
interval is load-bearing for the same reason it is in the switch protocol: without it,
requests routed during the propagation window arrive at a pod that is already terminating.
This is the stage that converts a successful migration into reclaimed GPU time, and
Section~\ref{sec:eval} measures the two halves separately for that reason.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{The RL-Driven Control Plane}
\label{sec:implementation}

The two primitives of Sections~\ref{sec:role-switch} and~\ref{sec:consolidation} are
mechanisms: each performs one operation when asked. This section defines the policy that
asks. Its objective is that a training job's own phase signal, and nothing else, should
reshape a live deployment for the duration of a rollout and return it afterwards.

\subsection{Three Levers on Three Timescales}
\label{sec:levers}

The waste identified in Section~\ref{sec:rl-waste} has two components, and no single lever
removes both. Allocation decides how many GPUs the deployment holds; it acts on the
timescale of a rollout, and it is the only lever that can return capacity to the cluster.
Role assignment decides how those GPUs are split between prefill and decode; it acts on
the timescale of a phase and is what addresses cross-phase waste. Placement decides which
decoder holds which running request; it also acts within a phase and is what addresses
intra-phase tail waste. We refer to them as S1, S2 and S3.

The \emph{mixed} strategy is the configuration in which all three are enabled, and it is
the one an RL operator would deploy. Over a single rollout it produces the following
trajectory: pre-warm the pods as the batch is announced; convert a decoder to prefill
while prompts are being sampled; convert it back as generation takes over; consolidate the
surviving stragglers onto fewer decoders as the batch drains; and release the freed GPUs
once the batch completes. The remainder of this section states what the controller
observes, the rule each lever applies, and how the three are kept from interfering.

\begin{figure}[htbp]
\centering
\scriptsize
\begin{tikzpicture}[
  node distance=3mm,
  st/.style={draw, rounded corners=2pt, fill=blue!8, align=center,
             font=\scriptsize, minimum height=5mm, text width=15mm},
  pol/.style={draw, rounded corners=1pt, fill=green!12, align=center,
              font=\scriptsize, minimum height=4.4mm, text width=30mm},
  act/.style={draw, dashed, rounded corners=1pt, align=center,
              font=\tiny, minimum height=4mm, text width=30mm},
  lbl/.style={font=\tiny, align=center},
  ar/.style={-{Latex[length=1.2mm]}}]

\node[pol] (s3) {(1) S3 consolidation};
\node[pol, below=of s3] (s2) {(2) S2 role switch};
\node[pol, below=of s2] (s1) {(3) S1 cluster scaling};
\draw[ar] (s3) -- (s2);
\draw[ar] (s2) -- (s1);
\node[lbl, above=1.5mm of s3] (tick) {one periodic loop, every tick};
\node[lbl, above=1.5mm of tick] (sig)
  {RL phase signal: \texttt{sampling\_progress}, \texttt{sampling\_done}, \texttt{batch\_complete}};
\draw[ar] (sig) -- (tick);

\node[act, right=5mm of s3] (mig) {migrate most-progressed request; when a decoder is drained: cordon, settle, scale down};
\node[act, right=5mm of s2] (sw) {D$\to$P when prefill pressure is high and decode idle; P$\to$D on the reverse};
\draw[ar, dashed] (s3) -- (mig);
\draw[ar, dashed] (s2) -- (sw);

\node[st, below=7mm of s1] (idle) {IDLE};
\node[st, right=6mm of idle] (warm) {WARM\_UP};
\node[st, right=6mm of warm] (active) {ACTIVE};
\node[st, right=6mm of active] (cool) {COOL\_DOWN};
\draw[ar] (idle) -- (warm);
\draw[ar] (warm) -- (active);
\draw[ar] (active) -- (cool);
\draw[ar] (cool.south) to[out=250,in=290] (idle.south);
\draw[ar] (cool.north) to[out=110,in=70] (warm.north);
\draw[ar] (s1) -- (idle);
\node[lbl, below=6mm of warm] {S1 alters the deployment's \emph{size} over a rollout; S2 and S3 alter its \emph{shape} within a phase};
\end{tikzpicture}
\caption{The RL-driven control plane as implemented. A single periodic loop
consumes the training job's phase signal and takes three decisions per tick,
in this order: consolidation, role switch, cluster scaling. Only cluster
scaling is a state machine (four states over the rollout lifecycle); S2 and S3
are policies re-evaluated every tick while the batch is active, so both may act
in the same tick. This replaces the mid-term figure, which drew rebalancing and
consolidation as sequential \emph{states} of one machine and gated consolidation
on a training signal.}
\label{fig:rl-controller}
\end{figure}

\subsection{What the Controller Observes}
\label{sec:inputs}

One periodic loop drives everything, over three inputs.

\noindent\textbf{The RL phase signal.} The training job posts
\texttt{sampling\_progress}, carrying the completed fraction of the batch together with
its shape---batch size, average input length, average output length---and
\texttt{sampling\_done} and \texttt{batch\_complete} at the boundaries. The shape fields
are what make the signal predictive rather than merely descriptive: a batch whose average
input length is large announces prefill demand before any request has queued.

\noindent\textbf{Cluster state.} The worker CRs give the current membership and the
runtime role of every pod, and the Deployment objects give the replica counts the
controller may change.

\noindent\textbf{Live load.} Each worker's sidecar reports its active-request count and
token progress; Prometheus supplies frontend queue depth per role and KV-cache occupancy.
From these the loop derives, each tick, a prefill and decode queue depth and a utilisation
per pool, falling back to in-flight counts when a metric is unavailable so that a scrape
failure degrades the policy rather than disabling it.

\subsection{The Decision Rules}
\label{sec:rules}

On each tick the loop evaluates placement, then role, then allocation. The order is
deliberate: consolidation may empty a decoder, which changes the idleness that the role
rule reads, which in turn changes the replica count the allocation rule sees.

\noindent\textbf{S1 --- allocation.} A four-state machine follows the rollout lifecycle.
\texttt{IDLE} $\rightarrow$ \texttt{WARM\_UP} on the first signal of a batch, which raises
replicas so the engines load; \texttt{WARM\_UP} $\rightarrow$ \texttt{ACTIVE} once the
workers report Ready; \texttt{ACTIVE} $\rightarrow$ \texttt{COOL\_DOWN} on
\texttt{batch\_complete}; and \texttt{COOL\_DOWN} $\rightarrow$ \texttt{IDLE} after a grace
period, or back to \texttt{WARM\_UP} if a further batch arrives first. The grace period is
what keeps consecutive batches warm, so the cold-start cost is paid once per rollout
rather than once per batch.

\noindent\textbf{S2 --- role.} A decoder is converted to prefill when three conditions
hold together: the prefill queue depth reaches a threshold, the decode pool's utilisation
is at or below an idleness bound, and more than the minimum number of decoders remain. The
reverse conversion requires the symmetric three---decode queue depth above threshold,
prefill pool idle, more than the minimum number of prefill workers---and one additional
condition discussed in Section~\ref{sec:interlocks}. The target is the most idle eligible
worker, and a minimum interval between switches bounds how often the topology may change.

Because the prefill queue is the trigger for the forward direction, how it is measured
decides whether the mechanism can fire at all. Measured reactively it never rises on this
stack: prefill completes fast enough that the frontend's prefill queue stays at zero
through a burst of dozens of prompts while the decode queue climbs to match the burst
size. The controller therefore also derives a prefill-pressure term from the phase
signal---proportional to the announced batch size when the announced input length is
large---and takes the larger of the two. This is the concrete form of the ``demand is
known in advance'' property that distinguishes an RL rollout from chat traffic: the
switch is issued because the batch was announced, not because a queue has already built.

\noindent\textbf{S3 --- placement.} While a batch is active, the controller pairs the
most-progressed request on a lightly-loaded decoder with the least-loaded eligible peer
and issues the three-phase migration. A decoder that reports no active requests for
several consecutive samples is then cordoned and, after the settle interval, scaled down.

\subsection{Keeping the Levers from Interfering}
\label{sec:interlocks}

Run together, S2 and S3 interact in two specific ways, each closed by one rule.

\noindent\textbf{A restored decoder must not be immediately reclaimed.} A
prefill-to-decode conversion produces a decoder with no active requests, which is exactly
S3's release condition. Requiring several consecutive idle observations, plus a minimum
interval between release actions, ensures a decoder that has just been restored is given
the chance to receive work before it is considered drained.

\noindent\textbf{A conversion must not withdraw capacity from a phase still in progress.}
The reverse switch additionally requires the prefill backlog to be clear. While the phase
signal indicates that prompts are still being sampled, the derived prefill-pressure term
keeps that backlog non-zero and the reverse switch is suppressed; once sampling completes
the term expires on its own and the condition opens. Without this rule the two directions
alternate at the minimum-interval cadence instead of converging, since each conversion
creates the idleness that justifies the other.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{Evaluation}
\label{sec:eval}

\subsection{Experimental Setup}
\label{sec:env}

All measurements are taken on a single-node Kubernetes~1.34 cluster in namespace
\texttt{dynamo-system}, serving \texttt{Qwen/Qwen3-0.6B} under PD disaggregation on four
GPUs. Five deployments are measured, each three times: \texttt{baseline\_1p1d}
(1~prefill~+~1~decode), \texttt{static\_2p2d} (2~+~2), and---at the same four GPUs as
\texttt{static\_2p2d}---\texttt{s2\_only}, \texttt{s3\_only} and \texttt{mixed}. The
fifteen runs are interleaved and counterbalanced within each round, so that any drift in
cluster warmth is common to all scenarios in a round and comparisons within a round remain
paired. Every run reported here is complete and error-free: 100\% of requests returned a
valid decode, with no HTTP~5xx and no timeout, and each run's measured wall clock equals
its batch makespan, confirming that no harness waiting is included in any reported time.

\subsection{Workload and Comparison Design}
\label{sec:workload}

\begin{table}[htbp]
\centering
\caption{The 96-request workload. One generator seed produces it once; every scenario
replays the identical requests. The three groups differ in prompt length, generation
length and arrival time so that each exercises a different part of the system.}
\label{tab:workload}
\scriptsize
\begin{tabularx}{\linewidth}{@{}lccLL@{}}
\toprule
Group & Reqs & Arrives & Shape & Exercises \\
\midrule
A prefill burst & 44 & $t_0$ & long prompt ($\approx$1940 tok), 1 output token &
prefill capacity: all prompts arrive at once and need no sustained generation \\
B decode dense & 49 & $t_0{+}45$\,s & short prompt ($\approx$570 tok), 768--1280 output tokens &
decode capacity: sustained generation with no new prefill demand \\
C long tail & 3 & $t_0{+}45$\,s & short prompt, 5000 output tokens, EOS suppressed &
the tail: a few long completions outlive the batch and pin decoders \\
\bottomrule
\end{tabularx}
\end{table}

The workload is constructed so that each mechanism has an interval in which it is the only
thing that can act (Table~\ref{tab:workload}). Group~A dispatches every prompt at once and
asks for a single output token, so the demand it creates is almost purely prefill---the
condition a decode-to-prefill switch exists to serve. Group~B arrives once A is in flight
and inverts the ratio: short prompts, long generations, no new prefill work, which is the
condition for the reverse switch. Group~C is three completions long enough to outlive both,
with end-of-sequence suppressed so they run to their token limit rather than finishing
early; they are what remains when the batch is nearly drained, each holding one decoder,
which is the condition consolidation exists to remove. Groups are separated by per-request
launch offsets rather than by waiting for the system to reach a state, so the measurement
contains no harness-induced delay.

The five deployments answer two different questions and must not be read as one ranking.
Comparing \texttt{baseline\_1p1d} with \texttt{static\_2p2d} varies the \emph{number} of
GPUs; it establishes that the workload is genuinely resource-limited and calibrates what
conventional horizontal scaling buys, but it says nothing about either primitive. The
three elastic deployments run at \emph{the same four GPUs} as \texttt{static\_2p2d}, so
every difference from that control is attributable to the mechanism rather than to added
capacity. We therefore expect, and test for, three distinct effects: that doubling the
pools shortens the batch; that role switching moves capacity between the pools within a
phase; and that consolidation returns a GPU before the batch ends.

\subsection{Level 1: What Adding GPUs Buys}
\label{sec:level1}

\begin{table}[htbp]
\centering
\caption{Batch makespan and per-group service windows, 3-run means (s). $\sigma$ is the
run-to-run standard deviation of $T_{\text{batch}}$.}
\label{tab:makespan}
\scriptsize
\begin{tabularx}{\linewidth}{@{}lRRRRR@{}}
\toprule
Deployment & $T_{\text{batch}}$ & $\sigma$ & A & B & C \\
\midrule
\texttt{baseline\_1p1d} & 134.8 & 8.50 & 97.1 & 69.5 & 77.5 \\
\texttt{static\_2p2d}   & 82.9  & 0.50 & 37.7 & 22.9 & 37.9 \\
\midrule
\texttt{s2\_only}       & 83.1  & 1.95 & 49.2 & 25.3 & 37.1 \\
\texttt{s3\_only}       & 85.4  & 2.89 & 37.0 & 24.5 & 40.4 \\
\texttt{mixed}          & 88.3  & 3.80 & 53.2 & 25.1 & 43.3 \\
\bottomrule
\end{tabularx}
\end{table}

Doubling both pools shortens the batch from 134.8\,s to 82.9\,s, a reduction of
\textbf{38.5\%}, and the gain is present in every group: the prefill burst completes in
37.7\,s instead of 97.1\,s, dense decode in 22.9\,s instead of 69.5\,s, and the tail in
37.9\,s instead of 77.5\,s (Table~\ref{tab:makespan}). Two things follow. The workload is
resource-limited rather than latency-limited, so there is headroom for a scheduling
mechanism to exploit; and the four-GPU deployment is the correct control, because it holds
that headroom fixed. Nothing in this comparison is evidence for either primitive: it is
what an ordinary replica-count increase achieves, at the cost of allocating the GPUs for
the whole batch.

\subsection{Level 2: Role Switching at Fixed GPU Count}
\label{sec:level2}

\begin{table}[htbp]
\centering
\caption{Runtime-role GPU-seconds by group, integrated over each group's service window
from the pod-role census (3-run means). Under \texttt{static\_2p2d} the split is fixed at
2+2; under \texttt{s2\_only} it follows the switches.}
\label{tab:rolegpu}
\scriptsize
\begin{tabularx}{\linewidth}{@{}lRRRR@{}}
\toprule
 & \multicolumn{2}{c}{\texttt{static\_2p2d}} & \multicolumn{2}{c}{\texttt{s2\_only}} \\
\cmidrule(lr){2-3}\cmidrule(lr){4-5}
Group & prefill & decode & prefill & decode \\
\midrule
A prefill burst & 75.4 & 75.4 & \textbf{133.3} & 63.5 \\
B decode dense  & 45.8 & 45.8 & 50.6 & 50.4 \\
C long tail     & 75.7 & 75.7 & 73.4 & 74.3 \\
\midrule
whole run       & 165.7 & 165.7 & \textbf{200.4} & \textbf{131.3} \\
\bottomrule
\end{tabularx}
\end{table}

\noindent\textbf{The mechanism acts, and the magnitude is large.} Table~\ref{tab:rolegpu}
integrates GPU-seconds by the role each pod actually held, rather than by the Deployment
it belongs to. During the prefill burst \texttt{s2\_only} devotes \textbf{133.3}
prefill-GPU-seconds against the control's 75.4---a 77\% increase---while decode-GPU-seconds
fall from 75.4 to 63.5. Over the whole run the split moves from a fixed 165.7/165.7 to
200.4/131.3, a 21\% shift of GPU time from decode to prefill. Solving the integral against
the group's 49.2\,s window recovers a 3P1D topology held for 35\,s, which matches the
observed switch timestamps. The primitive therefore does precisely what it is specified to
do, and does so at a scale that any real effect would be visible against.

\noindent\textbf{The reallocation does not shorten the phase.} The same group's service
window nevertheless grows from 37.7\,s to 49.2\,s ($+30.5\%$), and the batch makespan is
unchanged within noise (83.1\,s against 82.9\,s, with $\sigma=1.95$). Per-request timing
explains why. Time-to-first-token in the burst is statistically identical to the control
(p95 2702\,ms against 2710\,ms), while the router's prefill-queue wait---the one quantity
the switch can influence---does fall, from 29.5\,ms to 24.7\,ms ($-16.2\%$). That saving is
real and it is negligible: 4.8\,ms inside a request whose end-to-end latency is
approximately 34\,s. The remaining 30-odd seconds are spent waiting for the request's KV to
reach a decoder over a TCP-selected transport (Section~\ref{sec:transport}). Group~A is
therefore not prefill-bound but transport-bound, so adding prefill capacity buys almost
nothing while removing a decoder costs the handoff a server: the window lengthens because
the KV of 44 requests is drained by one decoder instead of two.

\noindent\textbf{The reverse switch is visible where it should be.} After the revert
restores the 2P2D split, group~B's time-to-first-token improves over the control
($327 \rightarrow 291$\,ms, $-10.8\%$) and group~C completes marginally faster
($37.1$ against $37.9$\,s). The mechanism is thus correct in both directions and its effect
appears in the phase it targets; what the deployment lacks is a bottleneck for it to
relieve.

\subsection{Level 3: Consolidation at Fixed GPU Count}
\label{sec:level3}

\begin{table}[htbp]
\centering
\caption{Consolidation, end to end (3-run means). Links 4--6 close arithmetically:
releasing one decoder 12.2\,s early predicts a saving of 12.2\,GPU$\cdot$s, and the
independently integrated occupancy measures 9.9.}
\label{tab:s3chain}
\scriptsize
\begin{tabularx}{\linewidth}{@{}LLRR@{}}
\toprule
 & Evidence & static & s3\_only \\
\midrule
1. a request was migrated & migrated requests & 0.00 & \textbf{1.00} \\
2. the source drained & drained sources & 0.00 & \textbf{1.00} \\
3. it completed normally & finish reason & --- & normal \\
4. the pool shrank & min decode replicas & 2.00 & \textbf{1.00} \\
5. the GPU was freed early & release lead (s) & 0.00 & \textbf{12.23} \\
6. GPU time was saved & whole-run GPU$\cdot$s & 331.5 & \textbf{321.6} \\
\bottomrule
\end{tabularx}
\end{table}

Consolidation targets the interval in which a handful of completions each hold a decoder,
so it is judged on GPU occupancy during the tail rather than on makespan. The chain is
recorded end to end (Table~\ref{tab:s3chain}): a running request is migrated, its source
decoder drains, the decode pool contracts from two replicas to one, and the released GPU is
free for the last 12.2\,s of the batch. The saving predicted by that release---one GPU for
12.2\,s---is 12.2\,GPU-seconds, and the occupancy series, integrated independently, measures
9.9. The two agree to within the pod-sampling interval, which is the check that matters: the
reclaimed time is accounted for by an observed topology change rather than inferred from a
ratio.

The cost is a slightly longer tail: group~C's window grows from 37.9\,s to 40.4\,s and the
makespan from 82.9\,s to 85.4\,s, because the surviving decoder finishes the migrated
request alongside its own. This is the mechanism's essential trade---GPU-time for
completion-time---and it is favourable exactly when a GPU-hour is worth more than the last
few seconds of a batch, which is the operating point of an RL rollout that is about to
enter a training step.

The yield is set by how long the released decoder can stay released, and therefore by the
shape of the tail rather than by the protocol. In a workload whose straggler group does not
overlap the dense decode group, the same mechanism holds one decoder instead of two for the
whole tail phase, reducing tail decode-GPU-seconds by $44.5\%$ (paired $t=-103.9$) and
whole-run decode-GPU-seconds by $18.5\%$. The mechanism is the same; the opportunity is
larger.

\subsection{Level 4: The Combined Policy}
\label{sec:level4}

With both primitives enabled, the two act without interfering: all runs complete at 100\%
validity, the switches fire in both directions, and consolidation still releases a decoder
12.1\,s before the end. The costs, however, add: the makespan is 88.3\,s against the
control's 82.9\,s, since \texttt{mixed} pays the lengthened prefill burst of
Section~\ref{sec:level2} (53.2\,s) and the lengthened tail of Section~\ref{sec:level3}
(43.3\,s) in the same run. The interlocks that keep the levers from alternating
(Section~\ref{sec:interlocks}) also make consolidation more conservative, so a migration
occurs in one run of three rather than in all three. The combined policy is therefore
demonstrably composable and safe, and on this deployment it inherits the weaker of its two
components rather than the stronger.

\subsection{The Cost of a Switch, and How It Scales}
\label{sec:switchcost}

\begin{table}[htbp]
\centering
\caption{Where a switch spends its time (10 switches; mean 941\,ms, range 884--1005).}
\label{tab:switchcost}
\scriptsize
\begin{tabularx}{\linewidth}{@{}LRR@{}}
\toprule
Stage & Mean & Share \\
\midrule
E2 drain and settle & 501.6\,ms & 53.3\% \\
C4 \texttt{register\_mdc} (control-plane round-trip) & 308.7\,ms & 32.8\% \\
C1 \texttt{sleep(2)} & 58.2\,ms & 6.2\% \\
C5 \texttt{wake} & 27.2\,ms & 2.9\% \\
E1 cordon & 16.1\,ms & 1.7\% \\
E3 outbound-KV drain & 9--19\,ms & 1.4\% \\
C2 \texttt{reconfig\_nixl} & 4.8\,ms & 0.5\% \\
C3 \texttt{reset\_prefix\_cache} & 2.3\,ms & 0.2\% \\
\bottomrule
\end{tabularx}
\end{table}

A switch completes in \textbf{941\,ms} on average, and the decomposition separates three
kinds of cost (Table~\ref{tab:switchcost}). The engine work is negligible at roughly
115\,ms combined. The control-plane round-trip that publishes the new ModelCard is a floor
at 309\,ms. The remaining 502\,ms is the drain-and-settle window, which is policy rather
than physics. The outbound-KV drain resolves on its first poll at a phase boundary, when no
handoff is in flight; when a switch coincides with an active handoff it waits for the peer,
and the one such case observed cost 9.1\,s---the load-dependent price of not interrupting
another worker's transfer.

Two switches per run therefore consume 2.01\,s of protocol time, yet the makespan exceeds
the control's by only 0.27\,s. The cost is not additive, because a switch removes one worker
from service while the other three continue: roughly 87\% of it is absorbed, leaving a
marginal cost near 0.13\,s per switch. The absolute cost is also fixed---its two dominant
terms are a Kubernetes round-trip and a constant window, neither of which grows with the
batch---while $T_{\text{batch}}$ grows with the number of prompts. At the measured scale the
protocol cost is 2.42\% of the batch; extrapolating the makespan linearly, it falls below
0.3\% at a thousand prompts and below 0.05\% at eight thousand. The overhead objection to
in-place role switching therefore does not survive at production rollout sizes. Whether the
mechanism becomes \emph{beneficial} at that scale is a separate question, and one this
deployment cannot answer, since its constraint is transport rather than prefill capacity.

\subsection{Summary}
\label{sec:evalsummary}

\begin{table}[htbp]
\centering
\caption{What each comparison establishes.}
\label{tab:evalsummary}
\scriptsize
\begin{tabularx}{\linewidth}{@{}LLL@{}}
\toprule
Comparison & Result & Status \\
\midrule
2p2d vs 1p1d & makespan $-38.5\%$ & calibration, not a claim \\
s2 vs 2p2d & prefill GPU-time $+77\%$ in the burst; queue wait $-16.2\%$; makespan unchanged & mechanism verified, no gain here \\
s3 vs 2p2d & decode replicas $2\to1$, GPU freed 12.2\,s early, $-9.9$\,GPU$\cdot$s & gain verified \\
mixed vs 2p2d & both act, 100\% valid; costs add & composable \\
switch cost & 941\,ms, $0.27$\,s of makespan, $<0.3\%$ at $10^3$ prompts & bounded \\
\bottomrule
\end{tabularx}
\end{table}

Role switching is correct, cheap and demonstrably effective at reallocating capacity, but
on a deployment whose prefill phase is bounded by KV transport there is no bottleneck for
the reallocated capacity to relieve. Consolidation is correct and returns GPU time within
the rollout, by an amount that its observed topology change accounts for. Both hold at
100\% request validity across every run.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{Discussion and Future Work}
\label{sec:discussion}

\subsection{Discussion}

\noindent\textbf{What is settled.} Both primitives are correct and lossless: across fifteen runs and five deployments, every request returned a valid decode with no HTTP error and no timeout, while switches fired in both directions and running requests were migrated between decoders. Consolidation returns GPU time inside a rollout, by an amount its observed topology change accounts for---a decoder released 12.2\,s before the batch ends, predicting 12.2\,GPU$\cdot$s against 9.9 measured---and reaches $-44.5$\% of tail decode-GPU$\cdot$s where the straggler phase does not overlap dense decode. A role switch costs 941\,ms of protocol time and 0.27\,s of makespan, and its relative cost falls below 0.3\% at production rollout sizes.

\noindent\textbf{What the data refuses.} Role switching yields no end-to-end gain on this deployment, and the reason is measured rather than assumed. The mechanism plainly acts---it raises prefill GPU-time during the burst by 77\% and lowers the router's prefill-queue wait by 16.2\%---but that wait is 4.8\,ms inside a 34\,s request, because the burst is bounded by KV transport over a TCP-selected path rather than by prefill compute. Buying prefill capacity in that regime relieves nothing while costing the KV handoff a server. This is a property of the fabric, not of the primitive, and it is the single most useful thing the evaluation establishes about when the mechanism should be deployed.

\noindent\textbf{Where the cost floor sits.} Of a switch's 941\,ms, the engine work is roughly 115\,ms and the control-plane round-trip that republishes the ModelCard is a 309\,ms floor. The remaining 502\,ms is the drain-and-settle window---policy rather than physics, and the term a deterministic routing acknowledgement from the frontend would remove. The outbound-KV drain is irreducible in principle: it waits on another worker's transfer, and shortening it trades losslessness for latency.

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
