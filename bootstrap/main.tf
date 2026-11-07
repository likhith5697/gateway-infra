terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # No backend block: this stack keeps its own state locally, since it creates the remote backend.
}

provider "aws" {
  region = var.region
}

# Looks up the AWS account ID you're logged in as.
# Used to make the bucket name globally unique.
data "aws_caller_identity" "current" {}

locals {
  bucket_name = "${var.name_prefix}-tfstate-${data.aws_caller_identity.current.account_id}-${var.region}"
}

# The bucket that stores Terraform state files for the other stacks.
# Bucket names are global across all AWS accounts, so the account ID and region are in the name.
resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name
}

# Keeps every previous version of each state file.
# If a bad apply corrupts the state, you can restore an earlier version.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypts every object at rest with S3-managed keys (SSE-S3).
# State files can contain secrets, so they're never stored in plain text.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Blocks all public access, both through ACLs and through bucket policies.
# Even a misconfigured policy can't expose the state publicly.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lock table: Terraform writes a row keyed by LockID while it runs.
# A second apply on the same state waits instead of overwriting it. Billed per request, so it costs ~$0 when idle.
resource "aws_dynamodb_table" "lock" {
  name         = "${var.name_prefix}-tf-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
