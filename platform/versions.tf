terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.72.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "3.3.0"
    }
  }

  # Same bucket and lock table as cluster/ and edge/, separate state file.
  #   terraform init -backend-config=../cluster/backend.hcl
  backend "s3" {
    key     = "platform/terraform.tfstate"
    encrypt = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "gateway"
      Stack     = "platform"
      ManagedBy = "terraform"
    }
  }
}

# Helm talks to the cluster created by ../cluster, using a short-lived token from your AWS credentials.
provider "helm" {
  # Isolated Helm repo config/cache for this stack, so a stale entry in the machine's global
  # ~/.config/helm/repositories.yaml (e.g. a repo whose index was deleted) can't break chart lookups.
  repository_config_path = "${path.module}/.helm/repositories.yaml"
  repository_cache       = "${path.module}/.helm/cache"

  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}
