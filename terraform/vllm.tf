# Serving tier: a CPU router in front of disaggregated vLLM pools.
# Prefill is compute-bound (chunked prefill, long-prompt isolation);
# decode is bandwidth-bound (continuous batching, FP8 weights).

locals {
  model_mount_path = "/models"

  vllm_common_env = {
    VLLM_WORKER_MULTIPROC_METHOD = "spawn"
    HF_HUB_OFFLINE               = "1" # weights come from the S3 model store, never the hub
  }
}

resource "kubernetes_service_account" "router" {
  metadata {
    name      = "inference-router"
    namespace = kubernetes_namespace.inference.metadata[0].name
  }
}

resource "kubernetes_service_account" "prefill" {
  metadata {
    name      = "vllm-prefill"
    namespace = kubernetes_namespace.inference.metadata[0].name
  }
}

resource "kubernetes_service_account" "decode" {
  metadata {
    name      = "vllm-decode"
    namespace = kubernetes_namespace.inference.metadata[0].name
  }
}

# ---------------------------------------------------------------------------
# Router: admission control, priority queues, prefix-hash routing.
# Runs on the CPU control tier; stateless, scales on CPU.
# ---------------------------------------------------------------------------
resource "kubernetes_deployment" "router" {
  metadata {
    name      = "inference-router"
    namespace = kubernetes_namespace.inference.metadata[0].name
    labels    = { app = "inference-router" }
  }

  spec {
    replicas = 2

    selector {
      match_labels = { app = "inference-router" }
    }

    template {
      metadata {
        labels = { app = "inference-router" }
      }

      spec {
        service_account_name = kubernetes_service_account.router.metadata[0].name
        node_selector        = { "workload-tier" = "control" }

        container {
          name = "router"
          # vLLM production-stack router: prefix-aware routing, per-tenant
          # queues. Swap for llm-d / NVIDIA Dynamo router or your own.
          image = "lmcache/lmstack-router:latest"

          args = [
            "--port=8000",
            "--service-discovery=k8s",
            "--k8s-namespace=$(POD_NAMESPACE)",
            "--k8s-label-selector=tier=engine",
            "--routing-logic=session", # prefix/session-affinity routing to the replica holding the KV
          ]

          env {
            name = "POD_NAMESPACE"
            value_from {
              field_ref {
                field_path = "metadata.namespace"
              }
            }
          }

          port {
            container_port = 8000
            name           = "http"
          }

          resources {
            requests = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "router" {
  metadata {
    name      = "inference-router"
    namespace = kubernetes_namespace.inference.metadata[0].name
    labels    = { app = "inference-router" }
  }

  spec {
    selector = { app = "inference-router" }

    port {
      name        = "http"
      port        = 8000
      target_port = 8000
    }
  }
}

# ---------------------------------------------------------------------------
# Decode pool: continuous batching, FP8 weights, KV headroom.
# One replica = one node's worth of GPUs with tensor parallelism inside
# the NVLink domain.
# ---------------------------------------------------------------------------
resource "kubernetes_deployment" "vllm_decode" {
  metadata {
    name      = "vllm-decode"
    namespace = kubernetes_namespace.inference.metadata[0].name
    labels    = { app = "vllm-decode", tier = "engine" }
  }

  spec {
    replicas = 1 # KEDA owns the replica count after apply (see keda.tf)

    selector {
      match_labels = { app = "vllm-decode" }
    }

    strategy {
      rolling_update {
        max_surge       = 1
        max_unavailable = 0 # a decode replica holds live KV; never kill before replacement is Ready
      }
    }

    template {
      metadata {
        labels = { app = "vllm-decode", tier = "engine" }
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "8000"
          "prometheus.io/path"   = "/metrics"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.decode.metadata[0].name
        node_selector        = { "workload-tier" = "gpu-decode" }

        toleration {
          key      = "nvidia.com/gpu"
          operator = "Exists"
          effect   = "NoSchedule"
        }

        # Allow in-flight generations to finish before the pod is killed
        termination_grace_period_seconds = 300

        container {
          name  = "vllm"
          image = var.vllm_image

          args = [
            "--model=${local.model_mount_path}/${var.model_id}",
            "--served-model-name=${var.model_id}",
            "--tensor-parallel-size=8",
            "--quantization=fp8",
            "--kv-cache-dtype=fp8",
            "--enable-prefix-caching",
            "--gpu-memory-utilization=0.92",
            "--max-num-batched-tokens=8192", # bounds step time so TPOT stays under budget
            "--port=8000",
          ]

          dynamic "env" {
            for_each = local.vllm_common_env
            content {
              name  = env.key
              value = env.value
            }
          }

          port {
            container_port = 8000
            name           = "http"
          }

          volume_mount {
            name       = "models"
            mount_path = local.model_mount_path
            read_only  = true
          }

          volume_mount {
            name       = "shm"
            mount_path = "/dev/shm"
          }

          resources {
            requests = {
              "nvidia.com/gpu" = "8"
              memory           = "480Gi"
            }
            limits = {
              "nvidia.com/gpu" = "8"
            }
          }

          startup_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            # weight load + CUDA graph capture takes minutes, not seconds
            failure_threshold = 120
            period_seconds    = 10
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            period_seconds = 10
          }
        }

        volume {
          name = "models"
          csi {
            driver    = "s3.csi.aws.com"
            read_only = true
            volume_attributes = {
              bucketName = aws_s3_bucket.model_store.bucket
            }
          }
        }

        volume {
          name = "shm"
          empty_dir {
            medium     = "Memory"
            size_limit = "64Gi"
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [spec[0].replicas] # KEDA scales this
  }
}

resource "kubernetes_service" "vllm_decode" {
  metadata {
    name      = "vllm-decode"
    namespace = kubernetes_namespace.inference.metadata[0].name
    labels    = { app = "vllm-decode" }
  }

  spec {
    selector = { app = "vllm-decode" }

    port {
      name        = "http"
      port        = 8000
      target_port = 8000
    }
  }
}

# ---------------------------------------------------------------------------
# Prefill pool: prefill-only replicas for long prompts. The router sends
# prompts above a length threshold here so one 100K-token prefill never
# stalls interactive decode traffic (problems 7 and 22).
# ---------------------------------------------------------------------------
resource "kubernetes_deployment" "vllm_prefill" {
  metadata {
    name      = "vllm-prefill"
    namespace = kubernetes_namespace.inference.metadata[0].name
    labels    = { app = "vllm-prefill", tier = "engine" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "vllm-prefill" }
    }

    template {
      metadata {
        labels = { app = "vllm-prefill", tier = "engine" }
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "8000"
          "prometheus.io/path"   = "/metrics"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.prefill.metadata[0].name
        node_selector        = { "workload-tier" = "gpu-prefill" }

        toleration {
          key      = "nvidia.com/gpu"
          operator = "Exists"
          effect   = "NoSchedule"
        }

        termination_grace_period_seconds = 300

        container {
          name  = "vllm"
          image = var.vllm_image

          args = [
            "--model=${local.model_mount_path}/${var.model_id}",
            "--served-model-name=${var.model_id}",
            "--tensor-parallel-size=8",
            "--enable-chunked-prefill",
            "--max-num-batched-tokens=4096", # chunk size: keeps each step bounded
            "--enable-prefix-caching",
            "--gpu-memory-utilization=0.92",
            "--port=8000",
          ]

          dynamic "env" {
            for_each = local.vllm_common_env
            content {
              name  = env.key
              value = env.value
            }
          }

          port {
            container_port = 8000
            name           = "http"
          }

          volume_mount {
            name       = "models"
            mount_path = local.model_mount_path
            read_only  = true
          }

          volume_mount {
            name       = "shm"
            mount_path = "/dev/shm"
          }

          resources {
            requests = {
              "nvidia.com/gpu" = "8"
              memory           = "480Gi"
            }
            limits = {
              "nvidia.com/gpu" = "8"
            }
          }

          startup_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            failure_threshold = 120
            period_seconds    = 10
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            period_seconds = 10
          }
        }

        volume {
          name = "models"
          csi {
            driver    = "s3.csi.aws.com"
            read_only = true
            volume_attributes = {
              bucketName = aws_s3_bucket.model_store.bucket
            }
          }
        }

        volume {
          name = "shm"
          empty_dir {
            medium     = "Memory"
            size_limit = "64Gi"
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [spec[0].replicas]
  }
}

resource "kubernetes_service" "vllm_prefill" {
  metadata {
    name      = "vllm-prefill"
    namespace = kubernetes_namespace.inference.metadata[0].name
    labels    = { app = "vllm-prefill" }
  }

  spec {
    selector = { app = "vllm-prefill" }

    port {
      name        = "http"
      port        = 8000
      target_port = 8000
    }
  }
}
