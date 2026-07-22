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
  # EBS CSI driver uses EKS Pod Identity instead (see aws_eks_pod_identity_association below).
  enable_irsa = false

  # Grant the Terraform caller (aws_mikael.sikora_test-developer) cluster-admin access
  # automatically. Without this, kubectl fails after every fresh cluster creation because
  # EKS module v21 does not add the caller to access entries by default.
  enable_cluster_creator_admin_permissions = true

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

# Sweep orphaned ENIs left by the VPC CNI or ELB controller before Terraform
# deletes the subnet and security group.  Without this, terraform destroy fails
# with DependencyViolation when AWS refuses to delete a subnet or SG that still
# has an attached (or available-but-not-yet-released) ENI.
#
# The provisioner runs on destroy only, before the VPC module tears down
# networking.  It finds every ENI in the VPC that is in "available" state
# (detached from any instance) and deletes them.  ENIs still attached to a
# running instance are intentionally skipped — they will be released when their
# owner resource is destroyed by Terraform.
resource "null_resource" "sweep_orphaned_enis" {
  triggers = {
    vpc_id       = module.vpc.vpc_id
    cluster_name = local.name
    region       = var.vpc_region
  }

  # --- ENI sweep ---
  # Deletes detached ("available") ENIs left behind by the VPC CNI or ELB
  # controller.  Must run before Terraform deletes subnets and security groups
  # or AWS raises DependencyViolation.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-BASH
      set -euo pipefail
      VPC_ID="${self.triggers.vpc_id}"
      REGION="${self.triggers.region}"
      echo "==> Sweeping orphaned ENIs in VPC $VPC_ID ($REGION)..."
      ENI_IDS=$(aws ec2 describe-network-interfaces \
        --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
        --query "NetworkInterfaces[*].NetworkInterfaceId" \
        --output text)
      if [[ -z "$ENI_IDS" ]]; then
        echo "  No orphaned ENIs found."
      else
        for ENI in $ENI_IDS; do
          echo "  Deleting ENI $ENI..."
          aws ec2 delete-network-interface \
            --network-interface-id "$ENI" \
            --region "$REGION"
        done
        echo "  Done."
      fi
    BASH
  }

  # --- EBS snapshot sweep ---
  # Deletes EBS snapshots tagged to this cluster (created by the EBS CSI driver
  # for VolumeSnapshot objects).  Snapshots are not managed by Terraform and are
  # not deleted when the EKS cluster or PVCs are removed, so they must be swept
  # explicitly to avoid orphaned cost.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-BASH
      set -euo pipefail
      CLUSTER="${self.triggers.cluster_name}"
      REGION="${self.triggers.region}"
      ACCOUNT=$(aws sts get-caller-identity --region "$REGION" --query Account --output text)
      echo "==> Sweeping EBS snapshots for cluster $CLUSTER ($REGION)..."
      SNAP_IDS=$(aws ec2 describe-snapshots \
        --region "$REGION" \
        --owner-ids "$ACCOUNT" \
        --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER" \
        --query "Snapshots[*].SnapshotId" \
        --output text)
      if [[ -z "$SNAP_IDS" ]]; then
        echo "  No cluster-tagged snapshots found."
      else
        for SNAP in $SNAP_IDS; do
          echo "  Deleting snapshot $SNAP..."
          aws ec2 delete-snapshot \
            --snapshot-id "$SNAP" \
            --region "$REGION"
        done
        echo "  Done."
      fi
    BASH
  }

  # --- EBS volume sweep ---
  # Deletes EBS volumes tagged to this cluster that are in "available" state
  # (detached).  The EBS CSI driver creates PersistentVolumes as gp2/gp3
  # volumes; when the PVC/PV is deleted inside Kubernetes the volume is
  # detached but may not be deleted if the reclaim policy is Retain, or if
  # the CSI driver pod was not running at the time of deletion.  Sweeping them
  # here prevents orphaned volumes from accruing cost after destroy.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-BASH
      set -euo pipefail
      CLUSTER="${self.triggers.cluster_name}"
      REGION="${self.triggers.region}"
      echo "==> Sweeping EBS volumes for cluster $CLUSTER ($REGION)..."
      VOL_IDS=$(aws ec2 describe-volumes \
        --region "$REGION" \
        --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER" \
                  "Name=status,Values=available" \
        --query "Volumes[*].VolumeId" \
        --output text)
      if [[ -z "$VOL_IDS" ]]; then
        echo "  No cluster-tagged available volumes found."
      else
        for VOL in $VOL_IDS; do
          echo "  Deleting volume $VOL..."
          aws ec2 delete-volume \
            --volume-id "$VOL" \
            --region "$REGION"
        done
        echo "  Done."
      fi
    BASH
  }

  depends_on = [
    null_resource.kubernetes_consul_resources,
    module.eks,
  ]
}


# ── EBS CSI Driver IAM — EKS Pod Identity ─────────────────────────────────────
# IRSA requires iam:CreateOpenIDConnectProvider, which is absent for the
# aws_mikael.sikora_test-developer role. Pod Identity is used instead.
#
# How it works:
#   1. eks-pod-identity-agent addon (installed below) intercepts credential requests
#      from pods and exchanges them for STS tokens via the IAM role trust policy.
#   2. aws_eks_pod_identity_association links the kube-system/ebs-csi-controller-sa
#      service account to the IAM role.
#   3. No OIDC provider is required.

# Install eks-pod-identity-agent as a managed addon (required for Pod Identity).
resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name = module.eks.cluster_name
  addon_name   = "eks-pod-identity-agent"
  depends_on   = [module.eks]
}

# IAM role for the EBS CSI controller pod.
data "aws_iam_policy_document" "ebs_csi_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "AmazonEKS_EBS_CSI_DriverRole_${module.eks.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
  tags = {
    "terraform" = "true"
  }
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# Bind the IAM role to the EBS CSI controller service account via Pod Identity.
resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn
  depends_on      = [aws_eks_addon.pod_identity_agent]
}

resource "aws_eks_addon" "ebs-csi" {
  cluster_name  = module.eks.cluster_name
  addon_name    = "aws-ebs-csi-driver"
  addon_version = "v1.62.0-eksbuild.1"
  tags = {
    "eks_addon" = "ebs-csi"
    "terraform" = "true"
  }
  depends_on = [aws_eks_pod_identity_association.ebs_csi]
}

# Mark gp2 as the default StorageClass so Consul server PVCs bind immediately
# after the EBS CSI addon becomes ACTIVE. Without this annotation EKS clusters
# have no default SC and PVCs stay Pending, causing the Consul Helm release to
# time out on first apply.
#
# Implemented as a null_resource local-exec (not kubernetes_annotations) so
# that the kubernetes provider is never contacted during `terraform destroy` —
# the StorageClass disappears with the cluster, so there is nothing to undo.
resource "null_resource" "gp2_default_storageclass" {
  triggers = {
    cluster_name = module.eks.cluster_name
    region       = var.vpc_region
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-BASH
      set -euo pipefail
      aws eks update-kubeconfig \
        --name "${module.eks.cluster_name}" \
        --region "${var.vpc_region}" \
        --alias "tf-gp2-${module.eks.cluster_name}" 2>/dev/null
      kubectl annotate storageclass gp2 \
        storageclass.kubernetes.io/is-default-class=true \
        --overwrite \
        --context "tf-gp2-${module.eks.cluster_name}" 2>/dev/null || true
      echo "gp2 StorageClass annotated as default"
    BASH
  }

  depends_on = [aws_eks_addon.ebs-csi]
}
