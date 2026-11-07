# terraform test   (mocked AWS provider: no credentials, nothing is created)
# Requires the authorizer zip: make -C ../authorizer zip

mock_provider "aws" {
  mock_data "aws_vpc" {
    defaults = { cidr_block = "10.0.0.0/16" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  routes_file           = "../../routes-repo/routes.yaml"
  vpc_id                = "vpc-123"
  vpc_link_subnet_ids   = ["subnet-a", "subnet-b"]
  internal_listener_arn = "arn:aws:elasticloadbalancing:us-east-2:123456789012:listener/app/internal/abc/def"
  jwt_issuer            = "https://auth.example.test"
  jwt_secret            = "0123456789abcdef0123456789abcdef"
}

run "wires_routes_authorizer_and_vpc_link" {
  command = plan

  assert {
    condition     = length(local.routes) == 3
    error_message = "expected the 3 orders routes from routes-repo/routes.yaml"
  }
  assert {
    condition     = aws_lambda_function.authorizer.runtime == "python3.12" && aws_lambda_function.authorizer.handler == "handler.lambda_handler"
    error_message = "authorizer runtime/handler wrong"
  }
  assert {
    condition     = aws_apigatewayv2_authorizer.lambda.enable_simple_responses && aws_apigatewayv2_authorizer.lambda.authorizer_payload_format_version == "2.0"
    error_message = "authorizer must use payload 2.0 simple responses"
  }
  assert {
    condition     = aws_apigatewayv2_vpc_link.this.subnet_ids == toset(["subnet-a", "subnet-b"])
    error_message = "VPC link must use the given subnets"
  }
  assert {
    condition     = one(aws_security_group.vpc_link.egress).cidr_blocks == tolist(["10.0.0.0/16"])
    error_message = "VPC link SG egress must be limited to the VPC CIDR"
  }
}

run "custom_domain_off_by_default" {
  command = plan

  override_resource {
    target          = aws_apigatewayv2_stage.default
    override_during = plan
    values          = { invoke_url = "https://abc123.execute-api.us-east-2.amazonaws.com/" }
  }

  assert {
    condition     = length(aws_acm_certificate.api) == 0 && length(aws_apigatewayv2_domain_name.api) == 0 && length(aws_route53_record.api) == 0 && length(data.aws_route53_zone.existing) == 0
    error_message = "no domain resources should exist when enable_custom_domain = false"
  }
  assert {
    condition     = output.invoke_url == "https://abc123.execute-api.us-east-2.amazonaws.com/"
    error_message = "invoke_url should be the execute-api URL when the custom domain is off"
  }
}

run "custom_domain_on" {
  command = plan
  variables {
    enable_custom_domain = true
    domain_name          = "example.com"
  }

  assert {
    condition     = aws_acm_certificate.api[0].domain_name == "api.example.com" && aws_acm_certificate.api[0].validation_method == "DNS"
    error_message = "certificate should be for api.example.com with DNS validation"
  }
  assert {
    condition     = aws_apigatewayv2_domain_name.api[0].domain_name_configuration[0].endpoint_type == "REGIONAL"
    error_message = "custom domain should be REGIONAL"
  }
  assert {
    condition     = output.invoke_url == "https://api.example.com"
    error_message = "invoke_url should switch to the custom domain"
  }
  assert {
    condition     = length(aws_route53_zone.this) == 0 && length(data.aws_route53_zone.existing) == 1
    error_message = "should look up the existing zone by default"
  }
}

run "custom_domain_requires_domain_name" {
  command = plan
  variables {
    enable_custom_domain = true
  }
  expect_failures = [var.domain_name]
}

run "rejects_auth_none_routes" {
  command = plan
  variables {
    routes_file = "tests/fixtures/auth-none.yaml"
  }
  expect_failures = [aws_apigatewayv2_stage.default]
}

run "rejects_short_secret" {
  command = plan
  variables {
    jwt_secret = "short"
  }
  expect_failures = [var.jwt_secret]
}
