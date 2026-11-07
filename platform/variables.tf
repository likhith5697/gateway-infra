variable "region" {
  description = "AWS region (free-plan account: us-east-2 only)."
  type        = string
  default     = "us-east-2"
}

variable "state_bucket" {
  description = "Remote state bucket that holds cluster/terraform.tfstate."
  type        = string
  default     = "gateway-tfstate-923832452634-us-east-2"
}

variable "name" {
  description = "Name prefix."
  type        = string
  default     = "gateway"
}

# --- pinned versions (confirmed against the published charts) -----------------------------------

variable "envoy_gateway_version" {
  description = "Envoy Gateway chart (oci://docker.io/envoyproxy/gateway-helm). v1.9.x supports Kubernetes 1.33-1.36 and bundles Gateway API v1.6.1 CRDs."
  type        = string
  default     = "v1.9.3"
}

variable "aws_lbc_version" {
  description = "AWS Load Balancer Controller chart (eks-charts). Must match iam/aws-load-balancer-controller-<version>.json."
  type        = string
  default     = "3.5.0"
}

# --- gateway ----------------------------------------------------------------------------------------

variable "gateway_name" {
  description = "Gateway that render_httproutes.py attaches routes to."
  type        = string
  default     = "public-gateway"
}

variable "gateway_namespace" {
  type    = string
  default = "gateway-system"
}

variable "listener_port" {
  description = "Port of the Gateway's HTTP listener and of the NLB listener."
  type        = number
  default     = 80
}

variable "envoy_container_port" {
  description = "Port Envoy actually listens on. Envoy Gateway maps privileged listener ports (<1024) to port + 10000."
  type        = number
  default     = 10080
}
