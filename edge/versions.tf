terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.72.0" # matches cluster/ and satisfies the routes module's "~> 6.72.0"
    }
  }

  # Same bucket and lock table as cluster/, separate state file.
  #   terraform init -backend-config=../cluster/backend.hcl
  backend "s3" {
    key     = "edge/terraform.tfstate"
    encrypt = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "gateway"
      Stack     = "edge"
      ManagedBy = "terraform"
    }
  }
}
