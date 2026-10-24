module "vpc" {
  source = "./modules/vpc"

  project  = var.project
  region   = var.region
  vpc_cidr = var.vpc_cidr
}

module "eks" {
  source = "./modules/eks"

  project            = var.project
  kubernetes_version = var.kubernetes_version
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnets
}

module "s3" {
  source = "./modules/s3"

  project = var.project

  depends_on = [module.eks]
}

module "karpenter" {
  source = "./modules/karpenter"

  cluster_name                = module.eks.cluster_name
  cluster_endpoint            = module.eks.cluster_endpoint
  gpu_prefill_instance_types  = var.gpu_prefill_instance_types
  gpu_decode_instance_types   = var.gpu_decode_instance_types
  gpu_nodes_max               = var.gpu_nodes_max
  model_store_read_policy_arn = module.s3.read_policy_arn
}

module "istio" {
  source = "./modules/istio"

  istio_version = var.istio_version

  depends_on = [module.eks]
}

module "opa" {
  source = "./modules/opa"

  istio_system_namespace = module.istio.istio_system_namespace
  policy_rego            = file("${path.module}/../policies/inference_authz.rego")
}

module "vllm" {
  source = "./modules/vllm"

  namespace    = module.istio.inference_namespace
  model_id     = var.model_id
  vllm_image   = var.vllm_image
  model_bucket = module.s3.bucket_name

  depends_on = [module.karpenter]
}

module "keda" {
  source = "./modules/keda"

  namespace           = module.istio.inference_namespace
  decode_min_replicas = var.decode_min_replicas
  decode_max_replicas = var.decode_max_replicas

  depends_on = [module.vllm]
}

module "observability" {
  source = "./modules/observability"

  depends_on = [module.eks]
}
