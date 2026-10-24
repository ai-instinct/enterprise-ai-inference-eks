output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "model_store_bucket" {
  value = module.s3.bucket_name
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "gateway_hint" {
  value = "kubectl -n istio-system get svc istio-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
}
