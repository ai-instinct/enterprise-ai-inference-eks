module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.31"

  cluster_name          = module.eks.cluster_name
  enable_v1_permissions = true

  enable_pod_identity             = true
  create_pod_identity_association = true

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    # GPU nodes pre-pull model weights from the model store at boot
    ModelStoreRead = aws_iam_policy.model_store_read.arn
  }
}

resource "helm_release" "karpenter" {
  namespace  = "kube-system"
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.1.1"
  wait       = true

  values = [yamlencode({
    settings = {
      clusterName       = module.eks.cluster_name
      clusterEndpoint   = module.eks.cluster_endpoint
      interruptionQueue = module.karpenter.queue_name
    }
    nodeSelector = {
      "workload-tier" = "control"
    }
  })]

  depends_on = [module.karpenter]
}

# Shared EC2NodeClass: Bottlerocket with a large NVMe data volume for
# container images and pre-pulled model weights (fast cold starts, problem 20).
resource "kubectl_manifest" "gpu_node_class" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "gpu"
    }
    spec = {
      amiFamily = "Bottlerocket"
      amiSelectorTerms = [
        { alias = "bottlerocket@latest" }
      ]
      role = module.karpenter.node_iam_role_name
      subnetSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = module.eks.cluster_name } }
      ]
      securityGroupSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = module.eks.cluster_name } }
      ]
      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs        = { volumeSize = "100Gi", volumeType = "gp3", deleteOnTermination = true }
        },
        {
          deviceName = "/dev/xvdb"
          ebs        = { volumeSize = "1000Gi", volumeType = "gp3", throughput = 1000, deleteOnTermination = true }
        }
      ]
    }
  })

  depends_on = [helm_release.karpenter]
}

# Prefill pool: compute-bound (one big matmul over all prompt tokens).
# Sized for FLOPs per dollar.
resource "kubectl_manifest" "nodepool_gpu_prefill" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "gpu-prefill"
    }
    spec = {
      template = {
        metadata = {
          labels = {
            "workload-tier" = "gpu-prefill"
          }
        }
        spec = {
          nodeClassRef = { group = "karpenter.k8s.aws", kind = "EC2NodeClass", name = "gpu" }
          requirements = [
            { key = "node.kubernetes.io/instance-type", operator = "In", values = var.gpu_prefill_instance_types },
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] }
          ]
          taints = [
            { key = "nvidia.com/gpu", value = "true", effect = "NoSchedule" }
          ]
        }
      }
      # Scale to zero when idle; consolidate aggressively off-peak
      limits = {
        "nvidia.com/gpu" = var.gpu_nodes_max * 8
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "10m"
      }
    }
  })

  depends_on = [kubectl_manifest.gpu_node_class]
}

# Decode pool: memory-bandwidth-bound (re-reads weights + KV every token).
# Sized for HBM capacity and bandwidth (H200-class), not FLOPs.
resource "kubectl_manifest" "nodepool_gpu_decode" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "gpu-decode"
    }
    spec = {
      template = {
        metadata = {
          labels = {
            "workload-tier" = "gpu-decode"
          }
        }
        spec = {
          nodeClassRef = { group = "karpenter.k8s.aws", kind = "EC2NodeClass", name = "gpu" }
          requirements = [
            { key = "node.kubernetes.io/instance-type", operator = "In", values = var.gpu_decode_instance_types },
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] }
          ]
          taints = [
            { key = "nvidia.com/gpu", value = "true", effect = "NoSchedule" }
          ]
        }
      }
      limits = {
        "nvidia.com/gpu" = var.gpu_nodes_max * 8
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "10m"
      }
    }
  })

  depends_on = [kubectl_manifest.gpu_node_class]
}

# NVIDIA device plugin + DCGM ship via the GPU Operator
resource "helm_release" "gpu_operator" {
  name             = "gpu-operator"
  namespace        = "gpu-operator"
  create_namespace = true
  repository       = "https://helm.ngc.nvidia.com/nvidia"
  chart            = "gpu-operator"
  version          = "v24.9.1"

  values = [yamlencode({
    # Bottlerocket ships the NVIDIA driver; the operator manages the rest
    driver  = { enabled = false }
    toolkit = { enabled = false }
    dcgmExporter = {
      enabled        = true
      serviceMonitor = { enabled = true }
    }
    operator = {
      defaultRuntime = "containerd"
    }
    daemonsets = {
      tolerations = [
        { key = "nvidia.com/gpu", operator = "Exists", effect = "NoSchedule" }
      ]
    }
  })]

  depends_on = [module.eks]
}
