terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.72.0"
    }
  }

  # Remote state in the bucket/table created by ../bootstrap.
  # Bucket name, region and lock table come from backend.hcl (see README):
  #   terraform init -backend-config=backend.hcl
  backend "s3" {
    key     = "cluster/terraform.tfstate"
    encrypt = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "gateway"
      Stack     = "cluster"
      ManagedBy = "terraform"
    }
  }
}
