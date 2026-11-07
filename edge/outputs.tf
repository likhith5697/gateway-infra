output "invoke_url" {
  description = "Base URL to call: https://api.<domain> when enable_custom_domain, otherwise the execute-api URL."
  value       = var.enable_custom_domain ? "https://${local.custom_domain}" : aws_apigatewayv2_stage.default.invoke_url
}

output "execute_api_url" {
  description = "Default API Gateway URL (always available)."
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "name_servers" {
  description = "Only when create_hosted_zone = true: set these at your domain registrar."
  value       = var.enable_custom_domain && var.create_hosted_zone ? aws_route53_zone.this[0].name_servers : null
}

output "route_keys" {
  description = "Routes created from routes.yaml."
  value       = module.routes.route_keys
}

output "authorizer_function_name" {
  value = aws_lambda_function.authorizer.function_name
}
