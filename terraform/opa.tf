# OPA as an Envoy external authorizer. The Istio ingress gateway consults
# OPA on every request (action: CUSTOM) before anything reaches the router:
# tenant auth, path allow-list, and max_tokens caps happen at the edge,
# not on the GPU.

resource "kubernetes_namespace" "opa" {
  metadata {
    name = "opa"
    labels = {
      istio-injection = "enabled"
    }
  }
}

resource "kubernetes_config_map" "opa_policy" {
  metadata {
    name      = "opa-policy"
    namespace = kubernetes_namespace.opa.metadata[0].name
  }

  data = {
    "inference_authz.rego" = file("${path.module}/../policies/inference_authz.rego")
  }
}

resource "kubernetes_config_map" "opa_config" {
  metadata {
    name      = "opa-config"
    namespace = kubernetes_namespace.opa.metadata[0].name
  }

  data = {
    "config.yaml" = yamlencode({
      plugins = {
        envoy_ext_authz_grpc = {
          addr = ":9191"
          path = "inference/authz/decision"
        }
      }
      decision_logs = {
        console = true
      }
    })
  }
}

resource "kubernetes_deployment" "opa" {
  metadata {
    name      = "opa"
    namespace = kubernetes_namespace.opa.metadata[0].name
    labels    = { app = "opa" }
  }

  spec {
    replicas = 2

    selector {
      match_labels = { app = "opa" }
    }

    template {
      metadata {
        labels = { app = "opa" }
      }

      spec {
        node_selector = { "workload-tier" = "control" }

        container {
          name  = "opa"
          image = "openpolicyagent/opa:0.70.0-envoy"

          args = [
            "run",
            "--server",
            "--config-file=/config/config.yaml",
            "--addr=0.0.0.0:8181",
            "/policy/inference_authz.rego",
          ]

          port {
            container_port = 9191
            name           = "grpc"
          }

          port {
            container_port = 8181
            name           = "http"
          }

          volume_mount {
            name       = "policy"
            mount_path = "/policy"
            read_only  = true
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
            read_only  = true
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8181
            }
            initial_delay_seconds = 5
          }

          readiness_probe {
            http_get {
              path = "/health?plugins"
              port = 8181
            }
            initial_delay_seconds = 5
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }

        volume {
          name = "policy"
          config_map {
            name = kubernetes_config_map.opa_policy.metadata[0].name
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.opa_config.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "opa" {
  metadata {
    name      = "opa"
    namespace = kubernetes_namespace.opa.metadata[0].name
    labels    = { app = "opa" }
  }

  spec {
    selector = { app = "opa" }

    port {
      name        = "grpc"
      port        = 9191
      target_port = 9191
    }
  }
}

# Attach OPA to the ingress gateway: every /v1 request is authorized by
# the Rego policy before it is routed.
resource "kubectl_manifest" "authz_opa_gateway" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "opa-ext-authz"
      namespace = kubernetes_namespace.istio_system.metadata[0].name
    }
    spec = {
      selector = { matchLabels = { istio = "ingress" } }
      action   = "CUSTOM"
      provider = { name = "opa-ext-authz" }
      rules = [
        { to = [{ operation = { paths = ["/v1/*"] } }] }
      ]
    }
  })

  depends_on = [helm_release.istiod, kubernetes_service.opa]
}
