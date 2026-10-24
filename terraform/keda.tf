# Autoscaling: scale on inference signals (queue depth, KV utilization),
# never on CPU (problem 20). KEDA scales the Deployments; Karpenter adds
# or removes the GPU nodes underneath them, down to zero when idle.

resource "helm_release" "keda" {
  name             = "keda"
  namespace        = "keda"
  create_namespace = true
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = "2.16.0"

  values = [yamlencode({
    nodeSelector = { "workload-tier" = "control" }
  })]

  depends_on = [module.eks]
}

locals {
  prometheus_url = "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090"
}

resource "kubectl_manifest" "scaledobject_decode" {
  yaml_body = yamlencode({
    apiVersion = "keda.sh/v1alpha1"
    kind       = "ScaledObject"
    metadata = {
      name      = "vllm-decode"
      namespace = kubernetes_namespace.inference.metadata[0].name
    }
    spec = {
      scaleTargetRef  = { name = "vllm-decode" }
      minReplicaCount = var.decode_min_replicas
      maxReplicaCount = var.decode_max_replicas
      # GPU cold starts take minutes: scale out early on the arrival slope,
      # scale in slowly to avoid flapping.
      cooldownPeriod  = 1200
      pollingInterval = 15
      advanced = {
        horizontalPodAutoscalerConfig = {
          behavior = {
            scaleUp   = { stabilizationWindowSeconds = 0 }
            scaleDown = { stabilizationWindowSeconds = 600 }
          }
        }
      }
      triggers = [
        {
          type = "prometheus"
          metadata = {
            serverAddress = local.prometheus_url
            # requests waiting per replica: scale before the queue melts TTFT
            query     = "sum(vllm:num_requests_waiting{app=\"vllm-decode\"})"
            threshold = "16"
          }
        },
        {
          type = "prometheus"
          metadata = {
            serverAddress = local.prometheus_url
            # sustained KV pressure causes preemptions; add a replica first
            query     = "avg(vllm:gpu_cache_usage_perc{app=\"vllm-decode\"})"
            threshold = "0.85"
          }
        }
      ]
    }
  })

  depends_on = [helm_release.keda, kubernetes_deployment.vllm_decode]
}

resource "kubectl_manifest" "scaledobject_prefill" {
  yaml_body = yamlencode({
    apiVersion = "keda.sh/v1alpha1"
    kind       = "ScaledObject"
    metadata = {
      name      = "vllm-prefill"
      namespace = kubernetes_namespace.inference.metadata[0].name
    }
    spec = {
      scaleTargetRef  = { name = "vllm-prefill" }
      minReplicaCount = 0
      maxReplicaCount = var.decode_max_replicas
      cooldownPeriod  = 1200
      pollingInterval = 15
      triggers = [
        {
          type = "prometheus"
          metadata = {
            serverAddress = local.prometheus_url
            query         = "sum(vllm:num_requests_waiting{app=\"vllm-prefill\"})"
            threshold     = "8"
          }
        }
      ]
    }
  })

  depends_on = [helm_release.keda, kubernetes_deployment.vllm_prefill]
}
