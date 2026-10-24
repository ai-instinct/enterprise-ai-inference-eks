
resource "kubernetes_namespace" "istio_system" {
  metadata {
    name = "istio-system"
  }
}

resource "kubernetes_namespace" "inference" {
  metadata {
    name = "inference"
    labels = {
      istio-injection = "enabled"
    }
  }
}

resource "helm_release" "istio_base" {
  name       = "istio-base"
  namespace  = kubernetes_namespace.istio_system.metadata[0].name
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "base"
  version    = var.istio_version
}

resource "helm_release" "istiod" {
  name       = "istiod"
  namespace  = kubernetes_namespace.istio_system.metadata[0].name
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = var.istio_version

  values = [yamlencode({
    pilot = {
      nodeSelector = { "workload-tier" = "control" }
    }
    meshConfig = {
      accessLogFile = "/dev/stdout"
      extensionProviders = [
        {
          name = "opa-ext-authz"
          envoyExtAuthzGrpc = {
            service = "opa.opa.svc.cluster.local"
            port    = 9191
          }
        }
      ]
      defaultConfig = {
        holdApplicationUntilProxyStarts = true
      }
    }
  })]

  depends_on = [helm_release.istio_base]
}

resource "helm_release" "istio_ingress" {
  name       = "istio-ingress"
  namespace  = kubernetes_namespace.istio_system.metadata[0].name
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "gateway"
  version    = var.istio_version

  values = [yamlencode({
    nodeSelector = { "workload-tier" = "control" }
    service = {
      type = "LoadBalancer"
      annotations = {
        "service.beta.kubernetes.io/aws-load-balancer-type"            = "external"
        "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
        "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internet-facing"
        "service.beta.kubernetes.io/aws-load-balancer-attributes"      = "idle_timeout.timeout_seconds=4000"
      }
    }
  })]

  depends_on = [helm_release.istiod]
}

resource "kubectl_manifest" "mesh_mtls_strict" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "PeerAuthentication"
    metadata = {
      name      = "default"
      namespace = kubernetes_namespace.istio_system.metadata[0].name
    }
    spec = {
      mtls = { mode = "STRICT" }
    }
  })

  depends_on = [helm_release.istiod]
}

resource "kubectl_manifest" "inference_gateway" {
  yaml_body = yamlencode({
    apiVersion = "networking.istio.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = "inference-gateway"
      namespace = kubernetes_namespace.inference.metadata[0].name
    }
    spec = {
      selector = { istio = "ingress" }
      servers = [
        {
          port  = { number = 80, name = "http", protocol = "HTTP" }
          hosts = ["*"]
        }
      ]
    }
  })

  depends_on = [helm_release.istio_ingress]
}

resource "kubectl_manifest" "inference_virtualservice" {
  yaml_body = yamlencode({
    apiVersion = "networking.istio.io/v1"
    kind       = "VirtualService"
    metadata = {
      name      = "inference-router"
      namespace = kubernetes_namespace.inference.metadata[0].name
    }
    spec = {
      hosts    = ["*"]
      gateways = ["inference-gateway"]
      http = [
        {
          match = [{ uri = { prefix = "/v1" } }]
          route = [
            {
              destination = {
                host = "inference-router.inference.svc.cluster.local"
                port = { number = 8000 }
              }
            }
          ]
          timeout = "3600s"
          retries = {
            attempts = 0
          }
        }
      ]
    }
  })

  depends_on = [kubectl_manifest.inference_gateway]
}

resource "kubectl_manifest" "authz_default_deny" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "default-deny"
      namespace = kubernetes_namespace.inference.metadata[0].name
    }
    spec = {}
  })

  depends_on = [helm_release.istiod]
}

resource "kubectl_manifest" "authz_gateway_to_router" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-gateway-to-router"
      namespace = kubernetes_namespace.inference.metadata[0].name
    }
    spec = {
      selector = { matchLabels = { app = "inference-router" } }
      action   = "ALLOW"
      rules = [
        {
          from = [
            { source = { principals = ["cluster.local/ns/istio-system/sa/istio-ingress"] } }
          ]
          to = [
            { operation = { methods = ["POST", "GET"], paths = ["/v1/*", "/health", "/metrics"] } }
          ]
        }
      ]
    }
  })

  depends_on = [kubectl_manifest.authz_default_deny]
}

resource "kubectl_manifest" "authz_router_to_engines" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-router-to-engines"
      namespace = kubernetes_namespace.inference.metadata[0].name
    }
    spec = {
      selector = { matchLabels = { tier = "engine" } }
      action   = "ALLOW"
      rules = [
        {
          from = [
            { source = { principals = ["cluster.local/ns/inference/sa/inference-router"] } }
          ]
        },
        {
          from = [
            { source = { principals = ["cluster.local/ns/inference/sa/vllm-prefill"] } }
          ]
        }
      ]
    }
  })

  depends_on = [kubectl_manifest.authz_default_deny]
}
