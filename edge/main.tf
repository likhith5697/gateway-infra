locals {
  routes_raw = yamldecode(file(var.routes_file)).routes

  # Every route must have all 7 fields, non-empty. Checked with try() so a missing field gives a clear
  # precondition error (below) instead of a type-conversion crash inside the module.
  route_fields = ["name", "path", "method", "namespace", "service", "port", "auth"]
  routes_complete = alltrue([
    for r in local.routes_raw : alltrue([
      for f in local.route_fields : try(r[f] != null && tostring(r[f]) != "", false)
    ])
  ])

  # Incomplete file -> the module gets NO routes (and the precondition fails the plan).
  routes = local.routes_complete ? local.routes_raw : []
}

data "aws_vpc" "this" {
  id = var.vpc_id
}

# The public HTTP API. Its only routes are the ones the module creates from routes.yaml.
resource "aws_apigatewayv2_api" "gateway" {
  name          = "${var.name}-http-api"
  protocol_type = "HTTP"
}

# Default stage: served at the root of the invoke URL, deploys automatically on every change.
# Throttling caps traffic so a flood of requests can't run up your bill.
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.gateway.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_rate_limit  = var.throttle_rate_limit
    throttling_burst_limit = var.throttle_burst_limit
  }

  lifecycle {
    # Defense in depth: CI's validator already enforces these; refuse them here too.
    precondition {
      condition     = local.routes_complete
      error_message = "Every route in ${var.routes_file} needs non-empty name, path, method, namespace, service, port and auth (run validate_routes.py)."
    }
    precondition {
      condition     = alltrue([for r in local.routes : r.auth == "custom"])
      error_message = "Every route in ${var.routes_file} must use auth: custom (run validate_routes.py)."
    }
  }
}

# Security group for the VPC Link ENIs: no inbound rules, outbound only to the VPC (where the internal LB is).
resource "aws_security_group" "vpc_link" {
  name        = "${var.name}-apigw-vpc-link"
  description = "API Gateway VPC Link to internal load balancer"
  vpc_id      = var.vpc_id

  egress {
    description = "To the internal load balancer inside the VPC"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.this.cidr_block]
  }
}

# Private connection from API Gateway into the VPC's private subnets.
resource "aws_apigatewayv2_vpc_link" "this" {
  name               = "${var.name}-vpc-link"
  subnet_ids         = var.vpc_link_subnet_ids
  security_group_ids = [aws_security_group.vpc_link.id]
}

# One route + integration per routes.yaml entry; "custom" routes use the Lambda authorizer.
module "routes" {
  source = "github.com/likhith5697/platform-templates//modules/api-gateway-routes?ref=v0.1.0"

  api_id        = aws_apigatewayv2_api.gateway.id
  routes        = local.routes
  authorizer_id = aws_apigatewayv2_authorizer.lambda.id
  vpc_link_id   = aws_apigatewayv2_vpc_link.this.id
  listener_arn  = var.internal_listener_arn
}
