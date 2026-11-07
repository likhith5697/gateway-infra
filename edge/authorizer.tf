locals {
  authorizer_zip = coalesce(var.authorizer_zip, "${path.module}/../authorizer/build/authorizer.zip")
}

# Execution role: the Lambda can only write its own logs. No other AWS access.
data "aws_iam_policy_document" "authorizer_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "authorizer" {
  name               = "${var.name}-authorizer"
  assume_role_policy = data.aws_iam_policy_document.authorizer_assume.json
}

data "aws_iam_policy_document" "authorizer_logs" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.authorizer.arn}:*"]
  }
}

resource "aws_iam_role_policy" "authorizer_logs" {
  name   = "write-own-logs"
  role   = aws_iam_role.authorizer.id
  policy = data.aws_iam_policy_document.authorizer_logs.json
}

# Created by Terraform (not by Lambda on first run) so it has a short retention and is deleted on destroy.
resource "aws_cloudwatch_log_group" "authorizer" {
  name              = "/aws/lambda/${var.name}-authorizer"
  retention_in_days = 7
}

resource "aws_lambda_function" "authorizer" {
  function_name = "${var.name}-authorizer"
  role          = aws_iam_role.authorizer.arn
  runtime       = "python3.12"
  handler       = "handler.lambda_handler"
  architectures = ["arm64"]
  memory_size   = 128
  timeout       = 3

  filename         = local.authorizer_zip
  source_code_hash = filebase64sha256(local.authorizer_zip) # redeploy only when the zip's contents change

  environment {
    variables = {
      JWT_ISSUER = var.jwt_issuer
      JWT_SECRET = var.jwt_secret
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.authorizer.name
  }

  depends_on = [aws_iam_role_policy.authorizer_logs]
}

resource "aws_apigatewayv2_authorizer" "lambda" {
  api_id                            = aws_apigatewayv2_api.gateway.id
  name                              = "jwt-hs256"
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = aws_lambda_function.authorizer.invoke_arn
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true # handler returns {"isAuthorized": bool}
  identity_sources                  = ["$request.header.Authorization"]
  authorizer_result_ttl_in_seconds  = 300 # cache per token; keeps Lambda invocations (and cost) low
}

# Lets THIS API's authorizer (and nothing else) invoke the Lambda.
resource "aws_lambda_permission" "apigw_invoke_authorizer" {
  statement_id  = "AllowApiGatewayAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.gateway.execution_arn}/authorizers/${aws_apigatewayv2_authorizer.lambda.id}"
}
