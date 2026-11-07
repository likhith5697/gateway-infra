variable "region" {
  description = "AWS region. Must match the bootstrap stack."
  type        = string
  default     = "us-east-2"
}

variable "name" {
  description = "Name for the cluster, VPC and related resources."
  type        = string
  default     = "gateway"
}

variable "kubernetes_version" {
  description = "EKS version. Keep it in standard support: extended support costs $0.60/hr instead of $0.10/hr."
  type        = string
  default     = "1.36"
}

variable "node_instance_type" {
  description = "Node instance type. t3.small is free-tier eligible on accounts created after July 15, 2025."
  type        = string
  default     = "t3.small"
}

variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint. Set this to your own IP, e.g. [\"203.0.113.7/32\"]."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
