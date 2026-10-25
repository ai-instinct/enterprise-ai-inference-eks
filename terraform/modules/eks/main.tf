module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = "${var.project}-eks"
  cluster_version = var.kubernetes_version

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  cluster_endpoint_public_access = false
  enable_irsa                    = true

  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      most_recent = true
    }
    eks-pod-identity-agent = {}
    aws-ebs-csi-driver = {
      most_recent = true
    }
  }

  eks_managed_node_groups = {
    control = {
      instance_types = ["m6a.xlarge"]
      min_size       = 2
      max_size       = 4
      desired_size   = 2

      labels = {
        "workload-tier" = "control"
      }
    }
  }

  node_security_group_tags = {
    "karpenter.sh/discovery" = "${var.project}-eks"
  }
}
