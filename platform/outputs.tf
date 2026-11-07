# Everything ../edge needs.
output "internal_listener_arn" {
  description = "edge: internal_listener_arn"
  value       = aws_lb_listener.http.arn
}

output "vpc_id" {
  description = "edge: vpc_id"
  value       = local.vpc_id
}

output "vpc_link_subnet_ids" {
  description = "edge: vpc_link_subnet_ids (the cluster's private subnets)"
  value       = local.private_subnet_ids
}

output "nlb_dns_name" {
  description = "Internal DNS name; only resolvable/reachable from inside the VPC."
  value       = aws_lb.internal.dns_name
}

output "edge_tfvars" {
  description = "Paste into ../edge/terraform.tfvars."
  value       = <<-EOT
    vpc_id                = "${local.vpc_id}"
    vpc_link_subnet_ids   = ${jsonencode(local.private_subnet_ids)}
    internal_listener_arn = "${aws_lb_listener.http.arn}"
  EOT
}
