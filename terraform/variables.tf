variable "project" {
  description = "Project name, used as a prefix for all resources"
  type        = string
  default     = "ai-inference"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "kubernetes_version" {
  description = "EKS control plane version"
  type        = string
  default     = "1.31"
}

variable "model_id" {
  description = "Hugging Face model ID served by the vLLM pools"
  type        = string
  default     = "meta-llama/Llama-3.1-70B-Instruct"
}

variable "vllm_image" {
  description = "vLLM OpenAI-compatible server image"
  type        = string
  default     = "vllm/vllm-openai:v0.8.4"
}

variable "gpu_prefill_instance_types" {
  description = "Instance types for the prefill pool (compute-bound: wants FLOPs)"
  type        = list(string)
  default     = ["p5.48xlarge"]
}

variable "gpu_decode_instance_types" {
  description = "Instance types for the decode pool (bandwidth-bound: wants HBM capacity/bandwidth)"
  type        = list(string)
  default     = ["p5e.48xlarge"]
}

variable "gpu_nodes_max" {
  description = "Maximum GPU nodes Karpenter may provision per pool"
  type        = number
  default     = 8
}

variable "decode_min_replicas" {
  description = "Minimum decode pool replicas (KEDA floor; 0 = scale to zero when idle)"
  type        = number
  default     = 0
}

variable "decode_max_replicas" {
  description = "Maximum decode pool replicas KEDA may scale to"
  type        = number
  default     = 8
}

variable "istio_version" {
  description = "Istio Helm chart version"
  type        = string
  default     = "1.24.2"
}

