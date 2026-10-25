<div align="center">

<p>
  <img src="docs/images/eks.png" alt="Amazon EKS" height="84" />
  &nbsp;&nbsp;&nbsp;
  <img src="docs/images/vllm.png" alt="vLLM" height="84" />
  &nbsp;&nbsp;&nbsp;
  <img src="docs/images/istio.png" alt="Istio" height="84" />
  &nbsp;&nbsp;&nbsp;
  <img src="docs/images/karpenter.png" alt="Karpenter" height="84" />
</p>

# Enterprise AI Inference on EKS

**A production reference architecture for serving large language models on Amazon EKS** -
disaggregated vLLM prefill/decode pools, Karpenter-provisioned GPU capacity with scale-to-zero,
Istio strict-mTLS zero-trust mesh, OPA policy enforcement at the edge, and inference-native
autoscaling and observability. All as Terraform.


[![License](https://img.shields.io/badge/License-Apache%202.0-green.svg)](LICENSE)

[Architecture](docs/architecture.md) · [Cheat Sheet](docs/cheat-sheet.md) · [Zero-Trust (Istio + OPA)](docs/zero-trust-istio-opa.md) · [Original PDF](docs/ai-inference-on-eks-cheat-sheet.pdf)

</div>

---

<p align="center">
  <img src="docs/images/request-flow.svg" alt="Reference architecture: animated request path from the internet through NLB, Istio gateway with OPA authz, inference router, and disaggregated vLLM prefill/decode GPU pools, with S3 model store, autoscaling and zero-trust control panels" width="900" />
</p>

## The architecture

One EKS cluster with a **CPU control tier** and a **GPU data tier**. A request flows **edge → router → prefill pool → decode pool**, then SSE-streams back the same path.

```mermaid
flowchart TB
    client([Client: browser or SDK])

    subgraph edge [Edge]
        gw[Istio Ingress Gateway · NLB<br/>TLS, SSE pass-through, long idle timeouts]
        opa[OPA ext-authz<br/>tenant auth · path allow-list · max_tokens caps]
    end

    subgraph cpu [CPU control tier]
        router[Inference Router<br/>admission control · priority queues · prefix-hash routing]
    end

    subgraph gpu [GPU data tier - Karpenter, scale-to-zero]
        prefill[Prefill pool · p5 H100<br/>chunked prefill - compute-bound]
        decode[Decode pool · p5e H200<br/>continuous batching, FP8 - bandwidth-bound]
    end

    client --> gw
    gw -.-> opa
    gw --> router
    router --> prefill
    prefill -->|KV blocks| decode
    decode -->|SSE tokens| client

    s3[(S3 model store)] -.-> gpu
    keda[KEDA: queue depth + KV util] -.-> gpu
    prom[Prometheus · DCGM · Grafana] -.-> gpu
```

Prefill and decode are different workloads wearing the same model - **prefill is a matmul over N tokens (compute-bound); decode is a matvec per token that re-reads all weights and KV (bandwidth-bound)** - so they get separate pools, separate GPU types, and separate scaling policies. The full reasoning lives in [docs/architecture.md](docs/architecture.md).

## What's in the box

| Layer | Implementation | File |
|---|---|---|
| Network | VPC, 3 AZs, S3 gateway endpoint (weights bypass NAT) | [`modules/vpc`](terraform/modules/vpc) |
| Cluster | EKS 1.31, managed CPU node group for the control tier | [`modules/eks`](terraform/modules/eks) |
| GPU capacity | Karpenter NodePools: `gpu-prefill` (p5/H100) and `gpu-decode` (p5e/H200), Bottlerocket + 1 TB NVMe, scale-to-zero, GPU Operator + DCGM | [`modules/karpenter`](terraform/modules/karpenter) |
| Serving | vLLM prefill pool (chunked prefill) + decode pool (FP8 weights & KV, prefix caching) + prefix-aware router | [`modules/vllm`](terraform/modules/vllm) |
| Model store | S3 (versioned, KMS) + Mountpoint CSI with NVMe cache - weights pinned by hash, never "latest" | [`modules/s3`](terraform/modules/s3) |
| Mesh | Istio strict mTLS, default-deny, gateway→router→engines as the only legal path, SSE-safe timeouts | [`modules/istio`](terraform/modules/istio) |
| Policy | OPA as Envoy ext-authz at the gateway: tenant auth, path allow-list, per-tenant `max_tokens` caps - rejected requests cost zero GPU-seconds | [`modules/opa`](terraform/modules/opa) · [`inference_authz.rego`](policies/inference_authz.rego) |
| Autoscaling | KEDA on queue depth + KV utilization (never CPU), slow scale-in for GPU cold starts | [`modules/keda`](terraform/modules/keda) |
| Observability | kube-prometheus-stack + vLLM engine metrics + SLO alert rules (TTFT p95, KV saturation, batch-stuck, GPU-idle-with-queue) | [`modules/observability`](terraform/modules/observability) |

## Quick start

> **Cost warning:** the default GPU types are p5-class (8× H100/H200). Plan first, and set instance types to something you actually want to pay for. Everything GPU scales to zero when idle.

```bash
cd terraform

terraform init
terraform plan

# smaller pockets: serve a 7B on L40S instead
terraform apply \
  -var gpu_prefill_instance_types='["g6e.12xlarge"]' \
  -var gpu_decode_instance_types='["g6e.12xlarge"]' \
  -var model_id="meta-llama/Llama-3.1-8B-Instruct"

# upload weights to the model store (pinned, not "latest")
aws s3 sync ./llama-3.1-8b s3://$(terraform output -raw model_store_bucket)/meta-llama/Llama-3.1-8B-Instruct

# talk to it
GATEWAY=$(kubectl -n istio-system get svc istio-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -N http://$GATEWAY/v1/chat/completions \
  -H "Authorization: Bearer tenant-interactive-key" \
  -H "Content-Type: application/json" \
  -d '{"model":"meta-llama/Llama-3.1-8B-Instruct","messages":[{"role":"user","content":"hello"}],"stream":true}'
```

## Where the model weights live

Weights never ship inside container images and are never pulled from the Hugging Face hub at runtime (`HF_HUB_OFFLINE=1`). The path is:

```text
S3 model store (versioned, KMS)            terraform output -raw model_store_bucket
  s3://<bucket>/meta-llama/Llama-3.1-70B-Instruct/   <- you upload here, pinned per version
        |
        v  Mountpoint for Amazon S3 CSI driver (read-only volume in modules/vllm)
/models/meta-llama/Llama-3.1-70B-Instruct/           <- what the vLLM pods see
        |
        v  block cache on the node's 1 TB NVMe data volume (modules/karpenter)
GPU HBM at engine startup (--model=/models/<model_id>)
```

1. **Upload** a model version to the bucket under its `model_id` prefix (see Quick start). The bucket is versioned, so a rollback is pointing back to the previous object versions, never a re-download from upstream.
2. **Mount**: each vLLM pod mounts the bucket read-only at `/models` through the Mountpoint S3 CSI driver; the S3 gateway endpoint keeps this traffic off the NAT gateway.
3. **Cache**: Mountpoint caches blocks on the node's NVMe, so a pod restart on a warm node reloads weights from local disk (1-3 min cold start instead of 5-15).

## The cheat sheet

This repo is the executable companion to a 25-problem study guide covering the entire LLM serving stack - KV cache math, PagedAttention, continuous batching, chunked prefill, prefix caching, speculative decoding, quantization, GPU selection, Nsight profiling, tail-latency diagnosis, canary rollouts, multi-tenancy, MoE parallelism, and capacity planning.

- **[Original PDF](docs/ai-inference-on-eks-cheat-sheet.pdf)** - the full 19 pages
- **[Markdown digest](docs/cheat-sheet.md)** - the quick-reference version

A taste - the numbers worth memorizing:

| Constant | Value |
|---|---|
| KV per token, 70B FP16 | ~320 KB (FP8: 160 KB) |
| 70B weights | 140 GB FP16 / 70 GB FP8 |
| H100 / H200 / B200 bandwidth | ~3.3 / ~4.8 / ~8 TB/s |
| Decode step floor, 70B FP16 on H100 | 140 GB ÷ 3.3 TB/s ≈ 42 ms |
| Interactive SLO (typical) | TTFT p95 < 500 ms · ITL p95 < 50 ms |
| GPU cold start | 5-15 min bare · 1-3 min with pre-pulled weights |

## Design principles

1. **Reject work before it reaches a GPU.** OPA at the gateway, admission control at the router - a bad request should cost CPU microseconds, not KV memory.
2. **Scale on inference signals, never CPU.** Queue depth and KV utilization predict SLO breaches; CPU tells you nothing about a bandwidth-bound decode loop.
3. **Weights are immutable artifacts.** Pinned by content hash in versioned S3; a rollback is a weight flip, not a cold start.
4. **Identity, not network position.** Strict mTLS everywhere; the only legal path is gateway → router → engines.
5. **Every GPU dollar is utilization ÷ bytes-per-token.** FP8, prefix caching, scale-to-zero, and per-phase GPU right-sizing are built in, not bolted on.

## License

[Apache 2.0](LICENSE) - use it, fork it, ship it.
