module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.31"

  cluster_name          = var.cluster_name
  enable_v1_permissions = true

  enable_pod_identity             = true
  create_pod_identity_association = true

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    ModelStoreRead               = var.model_store_read_policy_arn
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
      clusterName       = var.cluster_name
      clusterEndpoint   = var.cluster_endpoint
      interruptionQueue = module.karpenter.queue_name
    }
    nodeSelector = {
      "workload-tier" = "control"
    }
  })]

  depends_on = [module.karpenter]
}

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
        { tags = { "karpenter.sh/discovery" = var.cluster_name } }
      ]
      securityGroupSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = var.cluster_name } }
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

resource "helm_release" "gpu_operator" {
  name             = "gpu-operator"
  namespace        = "gpu-operator"
  create_namespace = true
  repository       = "https://helm.ngc.nvidia.com/nvidia"
  chart            = "gpu-operator"
  version          = "v24.9.1"

  values = [yamlencode({
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

}
