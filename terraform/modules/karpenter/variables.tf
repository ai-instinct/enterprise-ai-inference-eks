variable "cluster_name" {
  type = string
}

variable "cluster_endpoint" {
  type = string
}

variable "gpu_prefill_instance_types" {
  type = list(string)
}

variable "gpu_decode_instance_types" {
  type = list(string)
}

variable "gpu_nodes_max" {
  type = number
}

variable "model_store_read_policy_arn" {
  type = string
}
