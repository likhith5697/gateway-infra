data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# VPC across 2 AZs, with a public and a private subnet in each.
# One shared NAT gateway (not one per AZ) lets the private nodes reach the internet; it's the main fixed cost here.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = var.name
  cidr = "10.0.0.0/16"

  azs             = local.azs
  public_subnets  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnets = ["10.0.10.0/24", "10.0.11.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  # Tags the AWS Load Balancer Controller uses to pick subnets:
  # internet-facing load balancers go in public subnets, internal ones in private subnets.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

# EKS control plane plus one managed node group of 2 x t3.small in the private subnets.
# Logging and KMS secrets encryption are off to avoid CloudWatch and KMS charges; turn them on for anything real.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = var.name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Public API endpoint so you can run kubectl from your laptop; restrict it with api_allowed_cidrs.
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.api_allowed_cidrs

  # Gives whoever runs terraform apply cluster-admin access.
  enable_cluster_creator_admin_permissions = true

  # No IRSA: it needs an IAM OIDC provider, which this free-plan account's SCP denies
  # (iam:CreateOpenIDConnectProvider). Pods get AWS credentials via EKS Pod Identity instead (see ../platform).
  enable_irsa = false

  # Cost savers: no control-plane log group, no customer-managed KMS key ($1/month).
  enabled_log_types           = []
  create_cloudwatch_log_group = false
  create_kms_key              = false
  encryption_config           = null

  addons = {
    vpc-cni = {
      before_compute = true
    }
    kube-proxy = {}
    coredns    = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
  }

  eks_managed_node_groups = {
    default = {
      instance_types = [var.node_instance_type]
      ami_type       = "AL2023_x86_64_STANDARD"
      capacity_type  = "ON_DEMAND"

      min_size     = 2
      max_size     = 2
      desired_size = 2

      disk_size = 20
    }
  }
}

# Private container registry for the orders image.
# Images can be overwritten by tag, and every push is scanned for known vulnerabilities (basic scanning is free).
resource "aws_ecr_repository" "orders" {
  name                 = "orders"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # lets terraform destroy remove the repo even if it still has images

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Keeps only the 10 newest images.
# This stays well under the 500 MB of free ECR storage.
resource "aws_ecr_lifecycle_policy" "orders" {
  repository = aws_ecr_repository.orders.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
