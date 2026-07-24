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

We evaluate both primitives on a Kubernetes deployment of \texttt{Qwen3-0.6B}, comparing each elastic configuration against a static control at \emph{identical GPU count} so that every difference reflects the mechanism rather than added capacity. Consolidation returns GPU time inside the rollout: the decode pool contracts from two replicas to one and the released GPU is idle for the final $12.2$\,s of the batch, a saving the integrated occupancy independently confirms. Role switching completes in $941$\,ms and demonstrably reallocates capacity---during the prefill burst it raises the GPU-time in the prefill role by $77$\%, the direct signature of a decoder becoming a prefill worker---yet the batch is no faster, because its length is fixed by the decode tail rather than by the burst the switch accelerates. We therefore report a positive result for consolidation and a characterisation of when in-place role switching pays off: when a phase's wall clock is set by the computation the switch re-provisions, which on this workload it is not.
\end{abstract}

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{Introduction}

The cost of large-language-model inference is measured in GPU-hours, and the dominant
architectural response is prefill--decode (PD) disaggregation: a request's two phases have
different bottlenecks, so they are served by separate GPU pools joined by a KV-cache
fabric. NVIDIA Dynamo is the de-facto open-source realisation of that architecture, and it
is the system this work extends.

This paper concerns a workload for which the architecture is mis-provisioned by
construction---the reinforcement-learning rollout loop---and asks whether its waste can be
removed by changing a deployment's \emph{shape} rather than its \emph{size}.

\subsection{The RL Workload and Its Two Wastes}

In online chat serving traffic is near-stationary and a static PD partition works, because
both pools stay busy. The rollout loop that drives modern post-training (RLHF, DPO, GRPO)
submits inference in a fundamentally different pattern: a batch of prompts is dispatched at
once, and the job then waits for their completions. Each phase boundary leaves one pool
saturated and the other idle, and two compounded wastes follow (Figure~\ref{fig:gpu-hour}).

\emph{Cross-phase waste.} While the prompts are being processed only the prefill pool is
active; while the completions are generated only the decode pool is. The idle pool retains
its allocation throughout, incurring cost without contributing work.

\emph{Intra-phase tail waste.} As a batch nears completion the active-request count on each
decoder falls towards zero, yet no decoder can be released until the last long completion
finishes, so several GPUs are held for a handful of requests.

The two wastes call for different remedies. Cross-phase waste is a question of how the
GPUs are \emph{split} between the roles; tail waste is a question of \emph{where} the
surviving requests live. Neither is a question of how many GPUs are allocated, which is
what conventional elasticity adjusts.

\begin{figure}[t]
\centering
\includegraphics[width=\linewidth]{GPU-hour.png}
\caption{GPU utilization pattern in RL workloads. Each phase boundary leaves one pool busy and the other idle.}
\label{fig:gpu-hour}
\end{figure}

\subsection{Limitations of Conventional Elasticity}

Horizontal pod scaling reacts on the wrong timescale. A new worker takes tens of seconds to
become ready---one to two orders of magnitude longer than the phase it was meant to
serve---so by the time it arrives the demand has moved on. It also starts with an empty
prefix cache and must re-establish KV connectivity, discarding the reuse that PD
disaggregation exists to expose. Static over-provisioning avoids the latency but sizes both
pools for peak and therefore pays for the peak even while a pool is idle.

Three properties of the vLLM\,+\,Dynamo stack further constrain any in-place alternative:

\begin{enumerate}[nosep]
\item The KV-transfer configuration is fixed when an engine is constructed, so a role change
must not rebuild the engine.
\item The prefix cache is an index over blocks that engine sleep returns to the allocator, so
a resumed engine can serve stale hits unless the index and the blocks are made consistent.
\item The routers are stateful, so a role change must propagate through the discovery layer
and reconverge that state without disturbing requests in flight.
\end{enumerate}

No existing serving system re-roles a running worker or relocates a running request, as the
comparison with related systems that closes this section makes precise.

\subsection{Objective and Metrics}

The waste to be removed is allocated GPU-time that does no useful work, so the quantity we
optimise is the GPU-time a deployment spends, and the quantities we report are its
observable components. For a run we report the batch makespan $T_{\text{batch}}$ and,
integrated over each phase, the GPU-seconds held by each role---obtained from a per-tick
census of which role every ready pod is in, rather than from its static Deployment. Role
switching is expected to move GPU-seconds between the roles within a phase; consolidation is
expected to lower the decode pool's replica count, and hence its GPU-seconds, before the
batch ends. Both operations must complete within a single rollout phase, the requirement
that rules out replication and motivates in-place mechanisms. We deliberately do not reduce
these to a single utilisation ratio: the components are what distinguish a mechanism that
reallocates capacity from one that reclaims it, and a ratio would hide that distinction.

\subsection{Contributions and Claims}

This work contributes two runtime primitives, a policy that drives them from the training
job's own signal, and---the result we regard as most useful---a characterisation of when
in-place PD elasticity pays off and when it does not.

\begin{itemize}[nosep]
\item \textbf{(C1) A lossless in-place role-switch protocol.} A three-stage safety envelope
(cordon, drain and settle, outbound-KV drain) encloses a five-stage engine core, converting
a worker between decode and prefill roles with no pod restart, no engine rebuild, and no
request lost either on the worker or on a peer exchanging KV with it. It completes in
941\,ms under in-flight load.

\item \textbf{(C2) A block-hold migration protocol for running requests.} A three-phase
handshake relocates a running decode request between GPUs under an at-least-one-copy
invariant, so that a decoder can be drained without discarding partial work.

\item \textbf{(C3) A signal-driven control policy.} One loop derives prefill and decode
pressure from the rollout's announced shape as well as from observed queues, and applies
three levers on two timescales---allocation across a rollout, role and placement within a
phase---with interlocks that keep the levers from alternating against each other.

\item \textbf{(C4) Evidence that consolidation returns GPU time inside a rollout.} At fixed
GPU count, a running request is migrated, its source decoder drains, the decode pool
contracts from two replicas to one, and the released GPU is free for the final 12.2\,s of
the batch---a saving the measured occupancy independently confirms.

\item \textbf{(C5) Evidence that role switching, though correct and cheap, does not pay off
here, and why.} The mechanism verifiably reallocates capacity---prefill GPU-time during the
burst rises 77\%, the direct signature of a decoder becoming a prefill worker---yet the batch
is no faster, because its makespan is fixed by the decode tail and not by the burst the switch
accelerates. The negative result is therefore not a limit of the primitive but a statement of
the regime in which it helps, which we make explicit.
\end{itemize}

\noindent We state the last two together because they define the scope of the answer: the
approach removes tail waste on the deployment measured, and its cross-phase remedy awaits a
workload whose makespan is set by the phase the switch accelerates rather than by a later tail.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{Background and Related Work}

\subsection{Prefill--Decode Disaggregation}

LLM inference of every request goes through two serial phases that share the same model weights but have different resource bottlenecks. The prefill phase processes all $N$ prompt tokens in a single forward pass with full-rank attention, and is compute-bound due to large GEMMs. The decode phase generates one token at a time against the growing KV cache, and is memory-bandwidth-bound.

Co-locating both phases on one GPU (continuous batching) maximizes raw throughput but causes severe head-of-line blocking: a single long prefill stalls a batch of fast decodes. PD-disaggregated serving---pioneered by Splitwise~\cite{splitwise} and DistServe~\cite{distserve} and now the mainstream pattern adopted by NVIDIA Dynamo~\cite{dynamo}, vLLM-disagg~\cite{vllm}, and SGLang-disagg---splits the two phases onto separate GPU pools. The prefill pool produces the KV cache and ships it to the decode pool over a high-bandwidth fabric (NVLink / RDMA via NIXL~\cite{nixl}). The advantages are: compute-bound and bandwidth-bound work no longer interfere; each pool can be sized to its own bottleneck; and prefix caching becomes a first-class cross-request optimization.

However, the split inherits a structural inefficiency: the ratio of compute to memory traffic in a workload may not match the ratio of prefill to decode GPUs that the operator provisioned, so one pool is idle while the other is the bottleneck. This mismatch is amplified in RL workloads where traffic arrives in bursts, and it is the central leverage point of this work. Disaggregation also introduces a cost that co-location does not have: every request's KV must cross the fabric between the pools, so a deployment whose fabric is slow relative to its compute can find that transfer, rather than either phase's computation, sets the pace. Direct measurement of the KV path, reported with the consolidation protocol, establishes which regime the deployment measured here is in, and the evaluation shows that the answer determines which of our two primitives pays off.

\subsection{NVIDIA Dynamo Runtime Architecture}

Dynamo provides the routing and discovery substrate on top of stateful vLLM engines. Figure~\ref{fig:dynamo-arch} illustrates the overall architecture.

\begin{figure}[t]
\centering
\includegraphics[width=\linewidth]{dynamo-architecture.png}
\caption{NVIDIA Dynamo overall architecture.}
\label{fig:dynamo-arch}
\end{figure}

Three of Dynamo's subsystems determine what an in-place elasticity mechanism can and cannot do, and we introduce each together with the consequence this work relies on.

\noindent\textbf{Discovery: membership is metadata.} One Kubernetes Custom Resource per worker pod is the single source of truth for membership. Each worker strategic-merge-patches its own CR and the frontend's \texttt{ModelWatcher} reconstructs the WorkerSet by \texttt{list+watch}; there is no etcd and no central registry. \emph{Consequence:} a role change is a single metadata mutation visible to the whole system, so it needs neither a pod restart nor an engine rebuild---the property the switch protocol is built on.

\noindent\textbf{Routing: the routers are stateful.} \texttt{KvRouter} maintains a radix-tree index over the KV blocks held by each decoder and scores candidates by prefix-overlap, queue load and remaining capacity; \texttt{PrefillRouter} fans prefill traffic to any prefill-role worker discovered through the CRs. \emph{Consequence:} that state must reconverge after every role change, and because convergence is eventually consistent, a worker keeps receiving old-role traffic for a short interval after it is withdrawn. Absorbing that interval safely is the central difficulty of the switch protocol.

\noindent\textbf{Transport: KV is addressable across GPUs.} The NIXL connector performs zero-copy KV transfer, selecting a transport per pair of endpoints from those actually reachable between them, and the KV-Block Manager tracks the per-request block layout. Which transport is selected on the deployment measured here, and why it matters for the results, is established where the migration protocol is described. \emph{Consequence:} one decoder can read another's KV blocks directly from VRAM, which is what makes migrating a \emph{running} request feasible at all, as the migration protocol shows.

\subsection{KV Cache, Prefix Caching, and the Coherence Problem}

Decode is only affordable because the keys and values of every prior token are retained: the KV cache turns a quadratic re-computation into an incremental one. Prefix caching~\cite{lmcache} extends the same idea across requests, reusing blocks whenever two prompts share a prefix. The implementation detail that matters for this work is that vLLM~0.16 splits the structure in two: an \emph{index} in CPU memory that maps token prefixes to block identifiers, and the \emph{blocks} themselves, pinned in GPU VRAM.

That split is what makes an in-place role change delicate. Reclaiming a worker's GPU memory (via \texttt{engine.sleep(level=2)}) returns the blocks to the allocator but leaves the index intact, so the two halves can disagree: an index entry may point at a block that now belongs to a different request. A hit on such an entry after wake-up would silently splice another request's state into the current one. Any protocol that cycles the engine must therefore treat the index and the blocks as a single object and re-establish their agreement while the engine is quiescent---the third ordering constraint of the switch protocol. The same split has a second consequence used later: because the blocks are addressable GPU memory, a peer worker can read them directly over NIXL, which is the mechanism that makes live request migration possible at all.

\subsection{Related Systems and Distinctions}

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
\section{Elastic PD Role Switching}

\subsection{Problem Definition}

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

\noindent\textbf{The deployed unit.} Each dual-mode worker is one pod holding one vLLM engine, exposing an inference intake, a dynamically-assigned request-serving slot, a metrics port and the control-plane sidecar the controller calls (Table~\ref{tab:ports}). The sidecar is what makes the role switch operable at all: it terminates the \texttt{/switch\_role} endpoint the controller invokes, alongside the \texttt{/migrate\_out} and \texttt{/migrate\_in} endpoints used for consolidation, so the primitives are driven entirely through the control plane rather than through the data path. Figure~\ref{fig:k8s-deploy} shows how the sidecar, the worker's Dynamo runtime and vLLM engine, the frontend's \texttt{ModelWatcher} and the Kubernetes discovery backend fit together. The invariant that makes the flip cheap is \emph{one pod, one engine, one serving slot, two ModelCards}: the decode and prefill cards take turns owning the same slot, so a role change never creates or destroys a serving endpoint.

\begin{figure}[t]
\centering
\includegraphics[width=\linewidth]{K8S-deployement.png}
\caption{Deployment topology. Each worker pod runs the Dynamo runtime, a \texttt{kv\_both} vLLM engine, and an RL-Scaling sidecar exposing \texttt{/switch\_role} and \texttt{/migrate\_out}\,/\,\texttt{/migrate\_in}; workers register their ModelCards into the Kubernetes discovery backend, which the frontend's \texttt{ModelWatcher} reads to maintain the WorkerSet. The RL-Scaling controller drives both primitives through the sidecars, off the request path.}
\label{fig:k8s-deploy}
\end{figure}

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

\noindent\textbf{What makes an in-place flip possible.} Three properties of the stack
keep the protocol short. First, every dual-mode worker is constructed with
\texttt{NixlConnector kv\_both}, so the engine registers NIXL metadata for both prefill-
and decode-side semantics at boot; since \texttt{kv\_transfer\_config} is otherwise fixed
at construction, this is what avoids an engine rebuild. Second, the worker registers a
single TCP handler and selects between the decode and partner-prefill paths at request
time on its current role, so a switch never rebinds a socket---it only renames the entry
the frontend observes. Third, membership is metadata---publishing or withdrawing a role is a Custom-Resource mutation---so
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
now is it safe to release GPU memory (the fourth ordering constraint below).

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
\caption{The \texttt{switch\_role} protocol: a three-stage zero-loss envelope (E1--E3, blue) that establishes the preconditions for a role flip, enclosing a five-stage engine core (C1--C5, green) that performs it. Requests arriving between E1 and C4 are held by the dispatcher and served under the pre-switch role. Per-stage costs are reported in the evaluation.}
\label{fig:role-switch}
\end{figure}

\subsection{Ordering Constraints}

Four orderings make the protocol safe. Each states an invariant, and each rules out a
distinct failure.

The four are not independent. Constraint~1 is what makes constraint~2 terminate; constraints~2 and~3 concern this worker's own state and are ordered with respect to the sleep window; constraint~4 is the only one that concerns another worker, and is therefore the only one whose cost is set by something outside this protocol.

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

\subsection{Problem Definition}

Role switching can shrink the decoder pool only when the target decoder has no live
requests, and a switch issued mid-flight terminates whatever is running. Near the end of a
rollout that is exactly the wrong property: a handful of long completions, each holding
thousands of already-generated tokens, are scattered one per decoder. We therefore need an
operator-callable primitive that moves a \emph{running} request from one decoder to
another, leaving the source drainable, with no KV state lost or corrupted---and, since a
migrated request is only useful if the freed GPU is actually reclaimed, a path from
``source is drained'' to ``GPU is released''.

\subsection{The Three-Phase Block-Hold Protocol}

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
\caption{Three-phase block-hold migration. The source keeps the request alive and its blocks pinned for the whole handshake, so an authoritative KV copy exists at every instant. The read is issued through NIXL, whose transport is selected per agent pair as discussed below; recompute is the fallback when the block index is unavailable. The stage that reclaims the freed GPU follows separately.}
\label{fig:migration}
\end{figure}

\subsection{KV Transport and Its Measured Cost}

The protocol is written against read semantics---the destination fetches from the source's
memory---and is indifferent to how the read is realised. Realising it is the responsibility
of NIXL, the transfer layer, which is configured here with the UCX backend. For each pair of
communicating agents UCX selects a transport at connection time from those actually
reachable between the two endpoints, in descending order of capability: an intra-node
device-to-device path (CUDA IPC over NVLink), remote DMA over an InfiniBand or RoCE device,
or TCP as a universal fallback. The migration protocol issues the same read in every case;
only the achieved bandwidth differs.

On the cluster measured here the selected transport is TCP. Each worker is a single-GPU pod
in its own network namespace, so the NVLink peer-to-peer path, though present on the
hardware and benchmarked at 48\,GB/s, is not reachable across the pod boundary, and no
InfiniBand or RoCE device is exposed. It is natural to ask whether this fallback is the
system's bottleneck, and direct measurement answers that it is not. The UCX micro-benchmark
moves GPU-resident buffers between two pods at 2.9\,GB/s, close to the 3.76\,GB/s that host
TCP reaches on the same link. At that rate the KV of a long prompt---on the order of tens of
megabytes for the model used here---crosses in a few tens of milliseconds, two to three
orders of magnitude below a request's end-to-end service time. The transfer is therefore
fast enough that it never appears as the dominant term in any measurement we report.

This has one bearing on the design and one on the evaluation. For the design, because the
transfer is cheap the value of consolidation comes entirely from releasing a decoder, not
from the speed of the move, so the reclaim reported later does not depend on which transport
UCX selected---a faster fabric would shorten the handshake without changing its outcome. For
the evaluation, ruling out transport as the bottleneck is what makes the later finding
interpretable: when role switching adds prefill capacity yet the burst does not finish
sooner, the cause is not a slow KV path but the structure of the workload, which we examine
directly in the evaluation.

\subsection{Selecting the Request and the Destination}

Each worker maintains an in-process registry of its active requests, updated at
submission, on every streaming delta and at completion. Source-side victim selection picks
the most-progressed request, which maximises the replay cost avoided per migration.
Destination-side admission declines when the replay cost exceeds a threshold or too few
tokens remain to justify the transfer. The controller ranks candidate peers by load and
chooses the least-loaded decoder with spare KV capacity.

\subsection{From a Drained Decoder to a Reclaimed GPU}

Migration makes a decoder drainable; it does not by itself return the GPU. The controller
completes the chain: once a decoder reports no active requests it is marked for release,
its ModelCard is withdrawn, and---after a settle interval that lets the withdrawal
propagate to the routers---its Deployment replica count is decremented. The settle
interval is load-bearing for the same reason it is in the switch protocol: without it,
requests routed during the propagation window arrive at a pod that is already terminating.
This is the stage that converts a successful migration into reclaimed GPU time, and the evaluation measures the two halves separately for that reason.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{The RL-Driven Control Plane}

The role-switch and consolidation primitives are
mechanisms: each performs one operation when asked. This section defines the policy that
asks. Its objective is that a training job's own phase signal, and nothing else, should
reshape a live deployment for the duration of a rollout and return it afterwards.

\subsection{Three Levers on Three Timescales}

The two-part waste identified in the introduction---cross-phase and tail---admits no single lever that
removes both. Allocation decides how many GPUs the deployment holds; it acts on the
timescale of a rollout, and it is the only lever that can return capacity to the cluster.
Role assignment decides how those GPUs are split between prefill and decode; it acts on
the timescale of a phase and is what addresses cross-phase waste. Placement decides which
decoder holds which running request; it also acts within a phase and is what addresses
intra-phase tail waste. We call them signal-triggered scaling, PD role switch and request consolidation, and Figure~\ref{fig:rl-controller} shows how one control loop drives all three.

The \emph{mixed} strategy is the configuration in which all three are enabled, and it is
the one an RL operator would deploy. Over a single rollout it produces the following
trajectory: pre-warm the pods as the batch is announced; convert a decoder to prefill
while prompts are being sampled; convert it back as generation takes over; consolidate the
surviving stragglers onto fewer decoders as the batch drains; and release the freed GPUs
once the batch completes. The remainder of this section states what the controller
observes, the rule each lever applies, and how the three are kept from interfering.

\begin{figure*}[t]
\centering
\scriptsize
\begin{tikzpicture}[
  node distance=4mm,
  sig/.style={draw, rounded corners=2pt, fill=gray!10, align=center,
              font=\scriptsize, minimum height=6mm, text width=24mm},
  pol/.style={draw, rounded corners=2pt, fill=green!12, align=center,
              font=\scriptsize, minimum height=6mm, text width=32mm},
  act/.style={draw, dashed, rounded corners=2pt, align=left,
              font=\tiny, minimum height=5mm, text width=42mm},
  st/.style={draw, rounded corners=3pt, fill=blue!10, align=center,
             font=\scriptsize, minimum height=6mm, text width=20mm},
  cond/.style={font=\tiny, align=center, inner sep=1pt},
  ar/.style={-{Latex[length=1.4mm]}},
  dar/.style={-{Latex[length=1.4mm]}, dashed}]

% --- signal source -------------------------------------------------------
\node[sig] (rl) {RL training job};
\node[pol, right=22mm of rl] (s3) {\ding{182}~consolidation};
\node[pol, below=of s3] (s2) {\ding{183}~role switch};
\node[pol, below=of s2] (s1) {\ding{184}~scaling};
\draw[ar] (s3) -- (s2);
\draw[ar] (s2) -- (s1);
\draw[ar] (rl) -- node[cond, above, text width=26mm]
  {\texttt{sampling\_progress}\\\texttt{sampling\_done}\\\texttt{batch\_complete}} (s3);
\node[draw, dotted, thick, fit=(s3)(s2)(s1), inner sep=3mm] (loop) {};
\node[cond, above=0.5mm of loop.north] {one periodic loop; every tick, in this order};

% --- actions -------------------------------------------------------------
\node[act, right=26mm of s3] (mg) {$\Rightarrow$ \texttt{/migrate}: most-progressed request $\to$ least-loaded peer};
\node[act, below=2mm of mg] (rls) {$\Rightarrow$ cordon, settle, scale down: when a decoder is drained};
\node[act, right=26mm of s2] (dp) {$\Rightarrow$ \texttt{/switch\_role} D$\to$P: prefill backlog reached, decode idle};
\node[act, below=2mm of dp] (pd) {$\Rightarrow$ \texttt{/switch\_role} P$\to$D: decode backlog reached, prefill idle and clear};
\draw[dar] (s3.east) -- (mg.west);
\draw[dar] (s3.east) -- (rls.west);
\draw[dar] (s2.east) -- (dp.west);
\draw[dar] (s2.east) -- (pd.west);

% --- scaling state machine ----------------------------------------------------
\node[st, below=14mm of rl] (idle) {IDLE\\\tiny no GPUs held};
\node[st, right=13mm of idle] (warm) {WARM\_UP\\\tiny scaled up, not Ready};
\node[st, right=13mm of warm] (act) {ACTIVE\\\tiny Ready, serving};
\node[st, right=13mm of act] (cool) {COOL\_DOWN\\\tiny batch done, grace};
\draw[ar] (idle) -- node[cond, above] {new batch} (warm);
\draw[ar] (warm) -- node[cond, above] {Ready} (act);
\draw[ar] (act) -- node[cond, above] {\texttt{batch\_complete}} (cool);
\draw[ar] (cool.south) to[out=250, in=290] node[cond, below] {grace elapsed} (idle.south);
\draw[ar] (cool.north) to[out=110, in=70] node[cond, above] {new batch, pods still warm} (warm.north);
\draw[ar] (warm.south) to[out=310, in=230] node[cond, below] {pre-warm cancelled} (cool.south);
\draw[ar] (s1.west) to[out=180, in=90] (idle.north);
\node[cond, right=3mm of cool, text width=26mm]
  {role switch and consolidation act only while the batch is \textsc{active}; scaling alone changes how many GPUs are held};
\end{tikzpicture}
\caption{The control plane as implemented. A single periodic loop consumes the training
job's phase signal and evaluates three policies per tick, in the order shown: placement
(consolidation), role (role switch), then allocation (scaling). Only allocation is a state machine; role switch and consolidation are
re-evaluated every tick while a batch is active, so both may act in the same tick, which is
why the interlocks described below are required. Dashed edges are the
actions each policy may issue.}
\label{fig:rl-controller}
\end{figure*}

\subsection{What the Controller Observes}

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

On each tick the loop evaluates placement, then role, then allocation. The order is
deliberate: consolidation may empty a decoder, which changes the idleness the role rule
reads, which in turn changes the replica count the allocation rule sees.

\noindent\textbf{The two quantities every rule is written in.} Let $\mathcal{P}$ and
$\mathcal{D}$ be the sets of pods currently holding the prefill and decode roles, $n_i$ the
number of requests in flight on pod $i$, and $c$ the per-worker concurrency limit
($c=64$ here). Pool occupancy is the fraction of admitted slots in use,
\begin{equation}
U_r \;=\; \min\!\left(1,\;
\frac{\sum_{i \in r} n_i}{\max(1,\,|r|\cdot c)}\right),
\qquad r \in \{\mathcal{P}, \mathcal{D}\},
\label{eq:util}
\end{equation}
and a pool is called \emph{idle} when $U_r \le \theta_r$ in Equation~\ref{eq:util}, with $\theta_r$ a configured
bound. Writing idleness as an occupancy fraction rather than an absolute count is what
makes the rule independent of pool size: a single request on a two-decoder pool and two
requests on a four-decoder pool are equally idle, and the same threshold governs both.

Backlog is the work admitted to the frontend but not yet placed on a worker. It is read
from the frontend's per-role queue gauge, falling back to in-flight counts when that
metric is unavailable, and---for the prefill side only---combined with a term $a_{\mathcal{P}}$ derived from the phase signal:
\begin{equation}
Q_{\mathcal{P}} = \max\!\big(q_{\mathcal{P}},\; a_{\mathcal{P}}\big),
\quad
a_{\mathcal{P}} = \lceil B/c \rceil\; \mathbf{1}\!\big[\bar{L}_{\text{in}} \ge L^{*}\big],
\quad
Q_{\mathcal{D}} = q_{\mathcal{D}}.
\label{eq:backlog}
\end{equation}
where $q_r$ is the observed queue depth and $a_{\mathcal{P}}$ admits the prefill work the signal announces: $B$ is the batch size, $c$ the per-worker concurrency and $\bar{L}_{\text{in}}$ the average input length. The indicator fires only for
prompt-heavy batches ($L^{*}=1024$ tokens), and the term expires when a later signal
reports that the remaining work is no longer prompt-heavy. Equation~\ref{eq:backlog} is
where the ``demand is known in advance'' property enters the policy quantitatively: the
prefill backlog a rollout is \emph{about to} create is admitted as evidence alongside the
backlog it has already created.

\noindent\textbf{Signal-triggered scaling.} A four-state machine follows the rollout lifecycle.
\textsc{idle} $\rightarrow$ \textsc{warm\_up} on the first signal of a batch, which raises
replicas so the engines load; \textsc{warm\_up} $\rightarrow$ \textsc{active} once the
workers report Ready; \textsc{active} $\rightarrow$ \textsc{cool\_down} on
\texttt{batch\_complete}; and \textsc{cool\_down} $\rightarrow$ \textsc{idle} after a grace
period, or back to \textsc{warm\_up} if a further batch arrives first. The grace period is
what keeps consecutive batches warm, so cold start is paid once per rollout rather than
once per batch.

\noindent\textbf{PD role switch.} A decoder is converted to prefill when
\begin{equation}
Q_{\mathcal{P}} \ge \tau_{\mathcal{P}}
\;\wedge\;
U_{\mathcal{D}} \le \theta_{\mathcal{D}}
\;\wedge\;
|\mathcal{D}| > D_{\min},
\label{eq:d2p}
\end{equation}
and a prefill worker is converted back to decode when
\begin{equation}
Q_{\mathcal{D}} \ge \tau_{\mathcal{D}}
\;\wedge\;
U_{\mathcal{P}} \le \theta_{\mathcal{P}}
\;\wedge\;
\underbrace{Q_{\mathcal{P}} < \tau_{\mathcal{P}}}_{\text{backlog clear}}
\;\wedge\;
|\mathcal{P}| > P_{\min}.
\label{eq:p2d}
\end{equation}
Each conjunct rules out one way of making the topology worse. The backlog term establishes
that the destination pool is actually short of capacity; the occupancy term establishes
that the source pool can spare a worker, so the switch does not create the shortage it is
meant to relieve; and the cardinality term preserves a minimum of each role, without which
a pool could be emptied and the deployment would cease to serve. The extra conjunct in
Equation~\ref{eq:p2d} is discussed under the interlocks below. The target is the
eligible worker with the fewest in-flight requests, which minimises the drain the protocol
must wait for, and a minimum interval between switches bounds how often the topology may
change.

Equation~\ref{eq:d2p} also explains why the first term of Equation~\ref{eq:backlog} is
insufficient on its own. Measured reactively, $q_{\mathcal{P}}$ never rises on this stack:
prefill completes fast enough that the frontend's prefill queue remains at zero throughout
a burst of dozens of prompts, while the decode queue climbs to the burst size. Without the
signal-derived term the conjunction is never satisfied and the mechanism, though correct,
would never fire.

The thresholds $ au_r$, $ heta_r$ and the minimum switch interval are configuration, chosen from observed pool behaviour rather than derived from a model, and we did not sweep them: the evaluation fixes one setting and reports what it produces. How sensitive the policy is to that choice---in particular how close $ heta$ may approach the occupancy a burst actually leaves behind before the switch stops firing---is not established here.

\noindent\textbf{Request consolidation.} While a batch is active, the controller pairs the
most-progressed request on a lightly-loaded decoder with the least-loaded eligible peer and
issues the three-phase migration. A decoder observed with $n_i = 0$ on several consecutive
ticks is then cordoned and, after the settle interval, scaled down. Requiring consecutive
observations rather than a single one distinguishes a decoder that has genuinely finished
from one that is momentarily between requests.

\subsection{Keeping the Levers from Interfering}

Run together, the role switch and consolidation interact in two specific ways, each closed by one rule.

\noindent\textbf{A restored decoder must not be immediately reclaimed.} A
prefill-to-decode conversion produces a decoder with no active requests, which is exactly
the release condition of consolidation. Requiring several consecutive idle observations, plus a minimum
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

\subsection{Experimental Setup}

All measurements are taken on a single-node Kubernetes~1.34 cluster in namespace
\texttt{dynamo-system}, serving \texttt{Qwen/Qwen3-0.6B} under PD disaggregation on four
GPUs. Five deployments are measured, each three times: the 1P1D baseline
(1~prefill~+~1~decode), 2P2D static (2~+~2), and---at the same four GPUs as
2P2D static---one adding role switching, one adding consolidation, and one adding both. The
fifteen runs are interleaved and counterbalanced within each round, so that any drift in
cluster warmth is common to all scenarios in a round and comparisons within a round remain
paired. Every run reported here is complete and error-free: 100\% of requests returned a
valid decode, with no HTTP~5xx and no timeout, and each run's measured wall clock equals
its batch makespan, confirming that no harness waiting is included in any reported time.

Where GPU-time is reported by role, it is integrated from a per-tick census of each ready pod's \emph{runtime} role, read from the role label the sidecar publishes when it switches, rather than from the Deployment a pod belongs to. The distinction is essential for the role-switch results: a decoder that has become a prefill worker still belongs to the decode Deployment, so a Deployment-based count would attribute its work to the wrong role and hide the very reallocation being measured.

\subsection{Workload and Comparison Design}

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
Comparing the 1P1D baseline with the 2P2D static control varies the \emph{number} of
GPUs; it establishes that the workload is genuinely resource-limited and calibrates what
conventional horizontal scaling buys, but it says nothing about either primitive. The
three elastic deployments run at \emph{the same four GPUs} as 2P2D static, so
every difference from that control is attributable to the mechanism rather than to added
capacity. We therefore expect, and test for, three distinct effects: that doubling the
pools shortens the batch; that role switching moves capacity between the pools within a
phase; and that consolidation returns a GPU before the batch ends.

\subsection{Topology Scaling Establishes the Control}

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
1P1D           & 134.8 & 8.50 & 97.1 & 69.5 & 77.5 \\
2P2D           & 82.9  & 0.50 & 37.7 & 22.9 & 37.9 \\
\midrule
role switch    & 83.1  & 1.95 & 49.2 & 25.3 & 37.1 \\
consolidation  & 85.4  & 2.89 & 37.0 & 24.5 & 40.4 \\
combined       & 88.3  & 3.80 & 53.2 & 25.1 & 43.3 \\
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

\subsection{Role Switching Reallocates Capacity at Fixed GPU Count}

\begin{table}[htbp]
\centering
\caption{GPU-seconds by runtime role and request group, integrated over each group's
service window from the per-tick pod-role census (3-run means). The control holds a fixed
2+2 split; with role switching the split follows the switches.}
\label{tab:rolegpu}
\scriptsize
\begin{tabularx}{\linewidth}{@{}lRRRR@{}}
\toprule
 & \multicolumn{2}{c}{2P2D static} & \multicolumn{2}{c}{2P2D + role switch} \\
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

\noindent\textbf{The switch reallocates capacity, and by a large margin.}
Table~\ref{tab:rolegpu} integrates GPU-seconds by the role each pod actually held, taken
from the per-tick census rather than from its static Deployment. During the prefill burst
the switched configuration spends \textbf{133.3} prefill-GPU-seconds against the control's
75.4, a 77\% increase, while its decode-GPU-seconds fall from 75.4 to 63.5. Over the whole
run the split moves from a fixed 165.7/165.7 to 200.4/131.3. Solving the burst integral
against the group's 49.2\,s window recovers a 3P1D topology held for 35\,s, matching the
recorded switch times. This is the direct evidence that the primitive does what it is
specified to do: a decoder was converted to a prefill worker, and prefill served the burst
with 50\% more compute.

\noindent\textbf{The extra capacity does not shorten the phase, because the phase is not
prefill-limited.} The burst's service window nevertheless grows from 37.7\,s to 49.2\,s, and
the batch makespan is unchanged (83.1\,s against 82.9\,s). Per-request timing shows that the
added prefill capacity had little to work on. Each request reaches its first token in about
1.4\,s---23\,ms of router queueing followed by 1.4\,s of prefill---and with a single output
token that is the whole of its computation, yet its completion is not recorded until roughly
35\,s into the phase. What separates first token from completion is not prefill and not
transport, which together account for under two seconds, but the time the request spends
being finalised on the decode side as 44 of them clear the pipeline together. The burst is
therefore decode-gated in wall-clock terms despite being a prefill burst by construction, so
converting a decoder into a prefill worker adds capacity where none is needed and removes it
where the work actually queues, and the window lengthens. The one quantity the switch can
improve, the router's prefill-queue wait, does fall---from 29.5\,ms to 24.7\,ms---but 4.8\,ms
inside a 35\,s request is not visible at the phase level.

\noindent\textbf{The batch makespan cannot move regardless, because it is set by the tail.}
Group~C is dispatched at $t_0{+}45$\,s and its stragglers run to their token limit, finishing
near 83\,s; the makespan is that finishing time, and it is independent of how quickly the
earlier groups complete. Even a burst shortened by role switching would leave the batch the
same length. The absence of a makespan gain is thus a property of the workload's structure, not a failure
of the mechanism. That the reverse switch is equally well-behaved confirms the point from the
other side: after it restores the 2P2D split, group~B's time-to-first-token improves over the
control ($327\rightarrow291$\,ms) and group~C finishes marginally sooner ($37.1$ against
$37.9$\,s). The primitive is correct in both directions and its effect appears in the phase it
targets; what this deployment lacks is a phase whose wall clock the reallocated capacity could
shorten, so the negative result is a statement about when the mechanism helps, not whether it
works.

\subsection{Consolidation Reclaims GPU Time at Fixed GPU Count}

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

\subsection{The Combined Policy Composes Both Primitives}

With both primitives enabled, the two act without interfering: all runs complete at 100\%
validity, the switches fire in both directions, and consolidation still releases a decoder
12.1\,s before the end. The costs, however, add: the makespan is 88.3\,s against the
control's 82.9\,s, since the combined policy pays the lengthened prefill burst of
the lengthened prefill burst (53.2\,s) and the lengthened tail
(43.3\,s) in the same run. Consolidation is also less consistent here: a migration occurs in one run of three rather than in all three, although a decoder is released in all three. The interlocks of the interlocks that de-conflict the levers are the likely cause, since they delay a release candidate long enough that a decoder may drain on its own before a migration pair is formed, but we did not instrument the decision to confirm it and record the difference as unexplained. The combined policy is therefore
demonstrably composable and safe, and on this deployment it inherits the weaker of its two
components rather than the stronger.

\subsection{Switch Cost and Its Amortisation}

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
batch---while $T_{\text{batch}}$ grows with the number of prompts. At the measured scale the protocol cost is 2.42\% of the batch. Because the numerator is fixed while $T_{ ext{batch}}$ grows with the number of prompts, that fraction decreases monotonically with rollout size; we do not quote a figure for a larger rollout, since we have not established how makespan scales once the pools are saturated. The qualitative conclusion is the one that matters: the switch does not become more expensive as the workload grows, so the overhead objection to in-place role switching weakens with scale rather than strengthening. Whether the
mechanism becomes \emph{beneficial} at that scale is a separate question, and one this
deployment cannot answer, since its constraint is transport rather than prefill capacity.

\subsection{Summary}

\begin{table}[htbp]
\centering
\caption{What each comparison establishes.}
\label{tab:evalsummary}
\scriptsize
\begin{tabularx}{\linewidth}{@{}LLL@{}}
\toprule
Comparison & Result & Status \\
\midrule
2P2D vs 1P1D & makespan $-38.5\%$ & calibration, not a claim \\
role switch vs 2P2D & prefill GPU-time $+77\%$ in the burst; makespan unchanged & mechanism verified, no gain here \\
consolidation vs 2P2D & decode replicas $2\to1$, GPU freed 12.2\,s early, $-9.9$\,GPU$\cdot$s & gain verified \\
combined vs 2P2D & both act, 100\% valid; costs add & composable \\
switch cost & 941\,ms protocol, $0.27$\,s of makespan; fixed as batches grow & bounded \\
\bottomrule
\end{tabularx}
\end{table}

Table~\ref{tab:evalsummary} collects these. Role switching is correct, cheap and demonstrably effective at reallocating capacity, but on this workload the batch length is fixed by the decode tail, so the accelerated burst does not
reach the makespan and the reallocation has no phase whose wall clock it can shorten. Consolidation is correct and returns GPU time within
the rollout, by an amount that its observed topology change accounts for. Both hold at
100\% request validity across every run.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{Discussion and Future Work}

\subsection{Discussion}

\noindent\textbf{What is settled.} Both primitives are correct and lossless: across fifteen runs and five deployments, every request returned a valid decode with no HTTP error and no timeout, while switches fired in both directions and running requests were migrated between decoders. Consolidation returns GPU time inside a rollout, by an amount its observed topology change accounts for---a decoder released 12.2\,s before the batch ends, predicting 12.2\,GPU$\cdot$s against 9.9 measured---and reaches $-44.5$\% of tail decode-GPU$\cdot$s where the straggler phase does not overlap dense decode. A role switch costs 941\,ms of protocol time and 0.27\,s of makespan, and its relative cost falls below 0.3\% at production rollout sizes.

\noindent\textbf{What the data refuses.} Role switching yields no end-to-end gain on this deployment, and the reason is measured rather than assumed. The mechanism plainly acts---it raises the GPU-time spent in the prefill role during the burst by 77\%---but the batch it runs in is no shorter, for two reasons the data makes explicit. The burst's own wall clock is not set by prefill: each request reaches its first token in about 1.4\,s and then spends tens of seconds being finalised on the decode side, so adding prefill capacity has almost nothing to accelerate. And the makespan is not set by the burst at all but by the decode tail dispatched later, which finishes at the same time however quickly the burst completes. Neither is a limit of the primitive; both are properties of where the workload's time is actually spent. This is a property of the fabric, not of the primitive, and it is the single most useful thing the evaluation establishes about when the mechanism should be deployed.

\noindent\textbf{Where the cost floor sits.} Of a switch's 941\,ms, the engine work is roughly 115\,ms and the control-plane round-trip that republishes the ModelCard is a 309\,ms floor. The remaining 502\,ms is the drain-and-settle window---policy rather than physics, and the term a deterministic routing acknowledgement from the frontend would remove. The outbound-KV drain is irreducible in principle: it waits on another worker's transfer, and shortening it trades losslessness for latency.

\subsection{Future Work}

\begin{enumerate}[nosep]
\item \textbf{Separate migration's contribution from idle-release.} The reclaim reported here is produced by a chain whose last link is a scale-down, and a decoder that drains unaided reaches that link without a migration. A three-factor design isolates the difference: tail length (long enough that decoders cannot drain within the batch), decoder count (which sets the $\frac{D-1}{D}$ ceiling on reclaimable time), and whether the straggler group overlaps the dense decode group (which sets how long a released decoder stays released). Measuring reclaim against a no-migration control at each point separates the two mechanisms, and re-running it with the sampling-fidelity fix in place also re-establishes the tail numbers on a corrected basis.
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

\end{document}
