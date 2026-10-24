
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
      namespace = var.namespace
    }
    spec = {
      scaleTargetRef  = { name = "vllm-decode" }
      minReplicaCount = var.decode_min_replicas
      maxReplicaCount = var.decode_max_replicas
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
            query         = "sum(vllm:num_requests_waiting{app=\"vllm-decode\"})"
            threshold     = "16"
          }
        },
        {
          type = "prometheus"
          metadata = {
            serverAddress = local.prometheus_url
            query         = "avg(vllm:gpu_cache_usage_perc{app=\"vllm-decode\"})"
            threshold     = "0.85"
          }
        }
      ]
    }
  })

  depends_on = [helm_release.keda]
}

resource "kubectl_manifest" "scaledobject_prefill" {
  yaml_body = yamlencode({
    apiVersion = "keda.sh/v1alpha1"
    kind       = "ScaledObject"
    metadata = {
      name      = "vllm-prefill"
      namespace = var.namespace
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

  depends_on = [helm_release.keda]
}
