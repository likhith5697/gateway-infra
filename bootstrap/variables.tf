variable "region" {
  description = "AWS region for the state bucket and lock table."
  type        = string
  default     = "us-east-2"
}

variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
  default     = "gateway"
}
