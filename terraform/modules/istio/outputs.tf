output "istio_system_namespace" {
  value = kubernetes_namespace.istio_system.metadata[0].name
}

output "inference_namespace" {
  value = kubernetes_namespace.inference.metadata[0].name
}
