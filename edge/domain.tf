# Optional custom domain: https://api.<domain_name> instead of the execute-api URL.
# Everything here is gated by enable_custom_domain (default false). When off, nothing in this file is created.

locals {
  custom_domain = var.enable_custom_domain ? "api.${var.domain_name}" : null
  zone_id = !var.enable_custom_domain ? null : (
    var.create_hosted_zone ? aws_route53_zone.this[0].zone_id : data.aws_route53_zone.existing[0].zone_id
  )
}

# Hosted zone: look up the existing public zone for domain_name (default),
# or create one when create_hosted_zone = true ($0.50/month; then point your registrar at its name servers).
data "aws_route53_zone" "existing" {
  count        = var.enable_custom_domain && !var.create_hosted_zone ? 1 : 0
  name         = var.domain_name
  private_zone = false
}

resource "aws_route53_zone" "this" {
  count = var.enable_custom_domain && var.create_hosted_zone ? 1 : 0
  name  = var.domain_name
}

# Public TLS certificate for api.<domain> (free). It must be in the same region as the API for a REGIONAL endpoint.
resource "aws_acm_certificate" "api" {
  count             = var.enable_custom_domain ? 1 : 0
  domain_name       = local.custom_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# DNS record that proves to ACM you own the domain.
# Keyed by the domain name (known at plan time), not by validation options (only known after the certificate exists).
resource "aws_route53_record" "cert_validation" {
  for_each = var.enable_custom_domain ? toset([local.custom_domain]) : toset([])

  zone_id         = local.zone_id
  name            = one([for o in aws_acm_certificate.api[0].domain_validation_options : o.resource_record_name if o.domain_name == each.key])
  type            = one([for o in aws_acm_certificate.api[0].domain_validation_options : o.resource_record_type if o.domain_name == each.key])
  records         = [one([for o in aws_acm_certificate.api[0].domain_validation_options : o.resource_record_value if o.domain_name == each.key])]
  ttl             = 60
  allow_overwrite = true
}

# Waits until ACM has issued the certificate (usually 1-5 minutes once DNS has propagated).
resource "aws_acm_certificate_validation" "api" {
  count                   = var.enable_custom_domain ? 1 : 0
  certificate_arn         = aws_acm_certificate.api[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# The custom domain on API Gateway, using the validated certificate. TLS 1.2 minimum.
resource "aws_apigatewayv2_domain_name" "api" {
  count       = var.enable_custom_domain ? 1 : 0
  domain_name = local.custom_domain

  domain_name_configuration {
    certificate_arn = aws_acm_certificate_validation.api[0].certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }
}

# Maps https://api.<domain>/ to this API's $default stage.
resource "aws_apigatewayv2_api_mapping" "api" {
  count       = var.enable_custom_domain ? 1 : 0
  api_id      = aws_apigatewayv2_api.gateway.id
  domain_name = aws_apigatewayv2_domain_name.api[0].id
  stage       = aws_apigatewayv2_stage.default.id
}

# DNS: api.<domain> -> API Gateway's regional endpoint (alias record: free queries, no fixed IP).
resource "aws_route53_record" "api" {
  count   = var.enable_custom_domain ? 1 : 0
  zone_id = local.zone_id
  name    = local.custom_domain
  type    = "A"

  alias {
    name                   = aws_apigatewayv2_domain_name.api[0].domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.api[0].domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}
