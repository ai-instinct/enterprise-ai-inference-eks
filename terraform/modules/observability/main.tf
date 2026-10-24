
resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "66.3.0"

  values = [yamlencode({
    prometheus = {
      prometheusSpec = {
        nodeSelector   = { "workload-tier" = "control" }
        retention      = "15d"
        scrapeInterval = "15s"

        additionalScrapeConfigs = [
          {
            job_name = "vllm-engines"
            kubernetes_sd_configs = [
              { role = "pod", namespaces = { names = ["inference"] } }
            ]
            relabel_configs = [
              {
                source_labels = ["__meta_kubernetes_pod_annotation_prometheus_io_scrape"]
                action        = "keep"
                regex         = "true"
              },
              {
                source_labels = ["__meta_kubernetes_pod_label_app"]
                target_label  = "app"
              },
              {
                source_labels = ["__address__", "__meta_kubernetes_pod_annotation_prometheus_io_port"]
                action        = "replace"
                regex         = "([^:]+)(?::\\d+)?;(\\d+)"
                replacement   = "$1:$2"
                target_label  = "__address__"
              }
            ]
          }
        ]
      }
    }
    grafana = {
      nodeSelector = { "workload-tier" = "control" }
    }
    alertmanager = {
      alertmanagerSpec = {
        nodeSelector = { "workload-tier" = "control" }
      }
    }
  })]

}

resource "kubectl_manifest" "inference_alert_rules" {
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata = {
      name      = "inference-slo"
      namespace = "monitoring"
      labels    = { release = "kube-prometheus-stack" }
    }
    spec = {
      groups = [
        {
          name = "inference.slo"
          rules = [
            {
              alert  = "TTFTBudgetBreach"
              expr   = "histogram_quantile(0.95, sum(rate(vllm:time_to_first_token_seconds_bucket[5m])) by (le, app)) > 0.5"
              for    = "5m"
              labels = { severity = "page" }
              annotations = {
                summary = "p95 TTFT above 500ms for 5m - check queue wait vs prefill before touching the model"
              }
            },
            {
              alert  = "KVCacheSaturation"
              expr   = "avg(vllm:gpu_cache_usage_perc) > 0.9"
              for    = "10m"
              labels = { severity = "warn" }
              annotations = {
                summary = "KV cache above 90% sustained - preemptions imminent; scale decode or quantize KV"
              }
            },
            {
              alert  = "BatchStuckSmallUnderLoad"
              expr   = "avg(vllm:num_requests_running) < 2 and sum(vllm:num_requests_waiting) > 0"
              for    = "10m"
              labels = { severity = "warn" }
              annotations = {
                summary = "Batch stuck at 1-2 with a waiting queue - GPU is waiting on bandwidth or the scheduler"
              }
            },
            {
              alert  = "GPUIdleWithQueue"
              expr   = "avg(DCGM_FI_PROF_SM_ACTIVE) < 0.4 and sum(vllm:num_requests_waiting) > 0"
              for    = "10m"
              labels = { severity = "warn" }
              annotations = {
                summary = "SM activity under 40% with requests queued - look at the CPU front end, batch size, or kernel launches"
              }
            }
          ]
        }
      ]
    }
  })

  depends_on = [helm_release.kube_prometheus_stack]
}
