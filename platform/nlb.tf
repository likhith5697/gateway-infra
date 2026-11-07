# The internal NLB is created HERE, by Terraform, not by a Kubernetes controller.
# That makes its listener ARN a plain Terraform output for ../edge, and `terraform destroy` removes it cleanly
# (a controller-created load balancer would be invisible to Terraform and block VPC deletion).
# Pods are registered into the target group by the AWS Load Balancer Controller (TargetGroupBinding).

# NLB security group: only the VPC (where API Gateway's VPC Link ENIs live) may connect, only on the listener port.
resource "aws_security_group" "nlb" {
  name        = "${var.name}-internal-nlb"
  description = "Internal NLB in front of Envoy Gateway"
  vpc_id      = local.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "nlb_from_vpc" {
  security_group_id = aws_security_group.nlb.id
  description       = "VPC Link ENIs (inside the VPC) to the NLB listener"
  cidr_ipv4         = local.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = var.listener_port
  to_port           = var.listener_port
}

resource "aws_vpc_security_group_egress_rule" "nlb_to_envoy" {
  security_group_id = aws_security_group.nlb.id
  description       = "NLB to Envoy pods (traffic + health checks)"
  cidr_ipv4         = local.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = var.envoy_container_port
  to_port           = var.envoy_container_port
}

# Let the NLB reach Envoy pods. With the VPC CNI, pod IPs sit on node ENIs, which carry the node security group.
resource "aws_vpc_security_group_ingress_rule" "nodes_from_nlb" {
  security_group_id            = local.node_sg_id
  description                  = "Internal NLB to Envoy pods"
  referenced_security_group_id = aws_security_group.nlb.id
  ip_protocol                  = "tcp"
  from_port                    = var.envoy_container_port
  to_port                      = var.envoy_container_port
}

resource "aws_lb" "internal" {
  name                             = "${var.name}-internal-nlb"
  load_balancer_type               = "network"
  internal                         = true # private IPs only; reachable from inside the VPC (and the VPC Link)
  subnets                          = local.private_subnet_ids
  security_groups                  = [aws_security_group.nlb.id]
  enable_cross_zone_load_balancing = true # one Envoy replica may sit in either AZ; both NLB nodes must reach it
}

# IP targets: the NLB sends traffic straight to Envoy pod IPs (no NodePort hop).
resource "aws_lb_target_group" "envoy" {
  name                 = "${var.name}-envoy"
  target_type          = "ip"
  protocol             = "TCP"
  port                 = var.envoy_container_port
  vpc_id               = local.vpc_id
  deregistration_delay = 30

  health_check {
    protocol            = "TCP"
    port                = "traffic-port"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.internal.arn
  port              = var.listener_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.envoy.arn
  }
}
