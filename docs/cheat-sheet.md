# AI Inference on EKS — Cheat Sheet

Distilled from the full [PDF](ai-inference-on-eks-cheat-sheet.pdf) (19 pages, 25 problems). The PDF is the canonical version; this page is the quick-reference index.

## 1–2. Request lifecycle and streaming

TTFT is dominated by **queue wait + prefill**; everything after the first token is decode, one forward pass per token.

> Prefill is a matmul over N tokens; decode is a matvec per token that re-reads all weights and the KV cache. That is why they need different optimizations.

**SSE rules:** `Content-Type: text/event-stream`, `X-Accel-Buffering: no`, disable proxy buffering at every hop, ALB/NLB idle timeout ≥ max generation time, heartbeat every 10–15 s. Detect disconnects and call the engine's abort so a dead client never holds GPU memory.

## 3–5. KV cache, PagedAttention, FlashAttention

```text
KV bytes/token = 2 × L × H_kv × d_head × bytes
```

Llama-3-70B: 2 × 80 × 8 × 128 × 2 ≈ **320 KB/token FP16** (160 KB FP8; MHA would be 2.5 MB — GQA already saved 8×). 100 users at 32K context ≈ **1.07 TB FP16** before weights.

- **PagedAttention**: KV split into fixed 16-token blocks with a per-request block table (like an OS page table) — near-zero fragmentation, 2–4× more concurrent requests, and the foundation for prefix caching.
- **FlashAttention**: same FLOPs, O(N) memory traffic instead of O(N²) — never materializes the score matrix. Attention is memory-bound, so this is 2–4× speedup.

## 6–8. Scheduling: batching, chunked prefill, prefix caching

- **Continuous batching**: re-plan the batch every decode step; 2–10× throughput over static batching at the same latency. Bound step time with `max_num_batched_tokens` so TPOT stays under budget.
- **Chunked prefill**: split a 100K-token prefill into 2–8K chunks co-scheduled with running decode; decode keeps flowing, long prompt's TTFT grows only slightly. Route prompts above a threshold to the dedicated prefill pool.
- **Prefix caching**: hash each KV block by content; system prompts, few-shot examples, and multi-turn history become free prefill. At the routing level, send a request to the replica that already holds its prefix (consistent hashing, global prefix index, or sticky sessions). Spill evicted blocks HBM → host DRAM → NVMe → S3 (LMCache/Dynamo).

## 9–11. Latency levers: ITL, speculative decoding, quantization

Decode step time ≈ (weight bytes + KV bytes read) / HBM bandwidth. A 70B FP16 model on one H100 node reads 140 GB per step → ~40 ms floor at batch 1.

Levers in order of cheapness: **FP8 weights and KV** (halves bytes) → **CUDA graphs** (launch overhead) → **tensor parallel** (bandwidth adds up) → **speculative decoding** (helps at small batch, high acceptance; hurts at large batch) → cap batch size and add replicas.

| Format | Hardware | Use |
|---|---|---|
| FP8 (E4M3) | Hopper, Blackwell | Default for weights, activations, KV |
| INT8 (W8A8) | Ampere+ | Older GPUs |
| INT4 (AWQ/GPTQ) | Any | Memory-bound, small batch |
| NVFP4 | Blackwell | Large batch, near-FP8 quality |

Measure loss, not vibes: perplexity, task accuracy on your eval set, KL divergence vs FP16 logits, pairwise judge win rate on 200+ real prompts.

## 12–15. Hardware, profiling, kernels

| GPU | Memory | Bandwidth | Best for | EKS instance |
|---|---|---|---|---|
| H100 | 80 GB | ~3.3 TB/s | Balanced, widest support | p5 |
| H200 | 141 GB | ~4.8 TB/s | Long context, bigger KV | p5e / p5en |
| B200 | ~180 GB | ~8 TB/s | Max throughput, NVFP4, MoE | p6-b200 |
| L40S | 48 GB | ~0.86 TB/s | 7–13B models, cost-sensitive | g6e |

Pick by bottleneck: decode wants HBM bandwidth/capacity, prefill wants FLOPs. Price per million tokens per GPU, not price per hour.

**Profiling:** Nsight Systems first (gaps = launch overhead, long kernels = compute/memory, copies = H2D/D2H), then Nsight Compute on the hot kernel (high DRAM% + low SM% = memory-bound decode; the reverse = compute-bound prefill). GPU "at 30%"? Check DCGM SM activity (nvidia-smi lies), the CPU front end, batch size, kernel launches, KV pressure, I/O on the hot path, and topology.

## 16–17. Observability and tail latency

Track four engine signals per replica and per tenant — **TTFT, TPOT, queue depth, KV utilization** — plus prefix-cache hit rate and cost per request.

| Alert on | Why |
|---|---|
| TTFT p95 > SLO for 5 min | Queue or prefill regression |
| KV util > 90% sustained, preemptions > 0 | Preemption storm incoming |
| Batch stuck at 1–2 under load | GPU waiting on bandwidth/scheduler |
| SM activity < 40% with queue > 0 | CPU-bound front end or launch overhead |
| Hit rate drop after deploy | Router or cache regression |

A 10× p99/p50 gap almost always comes from **queueing or one slow path**, not the GPU being slow: split by phase (queue/prefill/decode), then by replica, then by tenant.

## 18–20. Engines, rollouts, autoscaling

- **vLLM**: widest coverage, fast to adopt. **TensorRT-LLM**: peak NVIDIA throughput, slower iteration. **SGLang**: RadixAttention prefix cache, strong agent/structured-output workloads. Benchmark on your own traffic shape at the latency SLO, not max throughput.
- **Rollout**: offline eval → 1–5% shadow → Argo Rollouts canary 1% → 5% → 25% → 100%, each step gated on TTFT p95, ITL p95, error rate, hit rate, and a quality judge. Both versions warm on separate pools so rollback is a weight flip. Weights pinned by content hash, never "latest".
- **Autoscaling**: cold start is 5–15 min if you do nothing. Pre-pull images and weights to NVMe, scale on queue depth/KV util (never CPU), scale out early, scale in slowly, keep admission control as the real defence against bursts.

## 21–23. Multi-tenant, disaggregation, MoE

- **Multi-tenant**: per-tenant token budgets enforced at the edge (429 + `Retry-After`), weighted fair queuing on tokens (not requests), priority tiers with aging, per-tenant KV share caps and prefix-cache accounting.
- **Disaggregated prefill/decode**: separate pools, KV moved over NVLink/EFA or a shared tier. Pays off with long/bimodal prompts, tight ITL SLOs, and enough GPUs.
- **MoE parallelism**: TP inside the NVLink domain for attention, EP across 8–32 GPUs for experts, PP only when it still doesn't fit. Mitigate all-to-all with load balancing, FP8 dispatch, and comm/compute overlap.

## 24–25. Cost and capacity planning

```text
Cost per 1M tokens = GPU $/hour ÷ tokens/hour actually served
```

| Lever | Typical saving |
|---|---|
| Raise utilization (time-of-day scaling, fill valleys with batch) | 1.5–2.5× |
| FP8 weights + KV | 1.5–2× |
| Prefix caching | 30–80% of prefill |
| Reserved/spot pricing | 30–60% |
| Model routing (small model for easy requests) | 20–50% |
| Disaggregate + right-size GPU per phase | 10–30% |

Stack three: utilization ×2, FP8 ×1.5, caching+pricing ×1.2 → **cost ÷ 3.6**. Guard with the same eval gate as a model rollout.

**Capacity math (1M DAU example):** 10M req/day → peak ~350 req/s; Little's law at 12.5 s/request → ~4,400 concurrent streams; ÷128 streams/replica → ~35 decode replicas + 6 prefill replicas + headroom → ~50 replicas (400 H100s) at peak, ~15–20 overnight. Every number is an assumption to be replaced by your real trace.

## Numbers worth memorizing

| Constant | Value |
|---|---|
| KV per token, 70B FP16 | ~320 KB (FP8: 160 KB) |
| 70B weights | 140 GB FP16 / 70 GB FP8 / ~40 GB INT4 |
| H100 / H200 / B200 HBM | 80 / 141 / ~180 GB |
| H100 / H200 / B200 bandwidth | ~3.3 / ~4.8 / ~8 TB/s |
| NVLink per GPU (Hopper) | ~900 GB/s |
| EFA per p5 node | 3.2 Tb/s |
| vLLM KV block | 16 tokens |
| Interactive SLO (typical) | TTFT p95 < 500 ms, ITL p95 < 50 ms |
| Cold start | 5–15 min bare; 1–3 min with pre-pulled weights |

Quick mental math: 70B FP16 on one H100 node → 140 GB ÷ 3.3 TB/s ≈ **42 ms per decode step** at batch 1; TP-8 divides it to ~5 ms plus all-reduce; FP8 halves it again.
