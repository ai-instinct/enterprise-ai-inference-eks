output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS control plane endpoint"
  value       = module.eks.cluster_endpoint
}

output "model_store_bucket" {
  description = "S3 bucket holding model weights (upload weights here, pinned by content hash)"
  value       = aws_s3_bucket.model_store.bucket
}

output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "gateway_hint" {
  description = "Fetch the inference gateway address once the NLB is provisioned"
  value       = "kubectl -n istio-system get svc istio-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
}
