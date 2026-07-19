data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.21.0"

  name = local.name

  cidr = "10.0.0.0/16"
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]

  enable_nat_gateway          = true
  single_nat_gateway          = true
  enable_dns_hostnames        = true
  map_public_ip_on_launch     = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.name}" = "shared"
    "kubernetes.io/role/elb"              = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.name}" = "shared"
    "kubernetes.io/role/internal-elb"     = 1
  }
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.0.0"

  name               = local.name
  kubernetes_version = "1.36"

  vpc_id                 = module.vpc.vpc_id
  subnet_ids             = module.vpc.public_subnets
  endpoint_public_access = true

  # Disable IRSA — we lack iam:CreateOpenIDConnectProvider permission.
  # EBS CSI driver uses node-level IAM policy instead.
  enable_irsa = false

  # EKS module v21 requires explicit managed addons for networking.
  # before_compute=true installs vpc-cni before node groups so nodes
  # get network connectivity and can register with the API server.
  addons = {
    vpc-cni = {
      before_compute = true
      most_recent    = true
    }
    kube-proxy = {
      most_recent = true
    }
    coredns = {
      most_recent = true
    }
  }

  eks_managed_node_groups = {
    consul = {
      name = "${var.name}-server"

      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3a.medium"]

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size
    }
  }

  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    ingress_cluster_all = {
      description                   = "Cluster to node all ports/protocols"
      protocol                      = "-1"
      from_port                     = 0
      to_port                       = 0
      type                          = "ingress"
      source_cluster_security_group = true
    }
    egress_all = {
      description      = "Node all egress"
      protocol         = "-1"
      from_port        = 0
      to_port          = 0
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }
  }
}

# Uninstalls consul resources (API Gateway controller, Consul-UI, and AWS ELB, and removes associated AWS resources)
# on terraform destroy
resource "null_resource" "kubernetes_consul_resources" {
  provisioner "local-exec" {
    when    = destroy
    command = <<EOT
      (kubectl delete svc/consul-ui --namespace consul || true) && (kubectl delete svc/api-gateway --namespace consul || true)
    EOT
  }
  depends_on = [module.eks]
}


# Attach EBS CSI policy directly to the node IAM role.
# IRSA (OIDC-based) would require iam:CreateOpenIDConnectProvider which
# this role does not have. Node-level policy achieves the same result.
resource "aws_iam_role_policy_attachment" "ebs_csi_node" {
  role       = module.eks.eks_managed_node_groups["consul"].iam_role_name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs-csi" {
  cluster_name  = module.eks.cluster_name
  addon_name    = "aws-ebs-csi-driver"
  addon_version = "v1.62.0-eksbuild.1"
  tags = {
    "eks_addon" = "ebs-csi"
    "terraform" = "true"
  }
  depends_on = [aws_iam_role_policy_attachment.ebs_csi_node]
}

# Mark gp2 as the default StorageClass so Consul server PVCs bind immediately
# after the EBS CSI addon becomes ACTIVE. Without this annotation EKS clusters
# have no default SC and PVCs stay Pending, causing the Consul Helm release to
# time out on first apply.
resource "kubernetes_annotations" "gp2_default_storageclass" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata {
    name = "gp2"
  }
  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "true"
  }
  depends_on = [aws_eks_addon.ebs-csi]
}
