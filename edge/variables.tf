variable "region" {
  description = "AWS region. Must match cluster/ (the free-plan account only allows us-east-2)."
  type        = string
  default     = "us-east-2"
}

variable "name" {
  description = "Name prefix for edge resources."
  type        = string
  default     = "gateway"
}

variable "routes_file" {
  description = "Path to routes.yaml, e.g. ../../routes-repo/routes.yaml. Validate it with validate_routes.py first."
  type        = string
}

# --- from the cluster session ---------------------------------------------------

variable "vpc_id" {
  description = "VPC the internal load balancer lives in (cluster output)."
  type        = string
}

variable "vpc_link_subnet_ids" {
  description = "Private subnets for the VPC Link ENIs; use the cluster's private subnets."
  type        = list(string)

  validation {
    condition     = length(var.vpc_link_subnet_ids) >= 1
    error_message = "Pass at least one subnet (two, in different AZs, recommended)."
  }
}

variable "internal_listener_arn" {
  description = "ARN of the internal ALB/NLB listener in front of the cluster's gateway."
  type        = string
}

# --- authorizer -----------------------------------------------------------------

variable "authorizer_zip" {
  description = "Path to the authorizer package. Build it first: make -C ../authorizer zip"
  type        = string
  default     = null # null = ../authorizer/build/authorizer.zip
}

variable "jwt_issuer" {
  description = "Required 'iss' claim value."
  type        = string
}

variable "jwt_secret" {
  description = "HS256 signing secret (32+ random bytes). Stored in Lambda config and Terraform state."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.jwt_secret) >= 32
    error_message = "jwt_secret must be at least 32 characters."
  }
}

# --- optional custom domain (domain.tf) --------------------------------------------

variable "enable_custom_domain" {
  description = "Create Route53 records, an ACM certificate and an API Gateway custom domain for api.<domain_name>. Off = use the execute-api URL."
  type        = bool
  default     = false
}

variable "domain_name" {
  description = "Domain you own, e.g. example.com. The API is served at api.<domain_name>."
  type        = string
  default     = ""

  validation {
    condition     = !var.enable_custom_domain || can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.domain_name))
    error_message = "Set domain_name (e.g. example.com, lowercase, no trailing dot) when enable_custom_domain = true."
  }
}

variable "create_hosted_zone" {
  description = "true = create a public hosted zone for domain_name ($0.50/month). false = use an existing one."
  type        = bool
  default     = false
}

# --- cost / abuse protection -------------------------------------------------------

variable "throttle_rate_limit" {
  description = "Steady-state requests per second across the API."
  type        = number
  default     = 10
}

variable "throttle_burst_limit" {
  description = "Burst requests across the API."
  type        = number
  default     = 20
}
