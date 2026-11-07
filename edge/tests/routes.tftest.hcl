# Route behaviour tests.  terraform init && terraform test   (mocked AWS provider: no credentials, nothing created)
# Requires the authorizer zip: make -C ../authorizer zip

mock_provider "aws" {
  mock_data "aws_vpc" {
    defaults = { cidr_block = "10.0.0.0/16" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  # A mocked *apply* invents random strings; give fields the provider validates as ARNs realistic values.
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock-authorizer" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-2:123456789012:log-group:/aws/lambda/mock" }
  }
  mock_resource "aws_lambda_function" {
    defaults = {
      arn        = "arn:aws:lambda:us-east-2:123456789012:function:mock"
      invoke_arn = "arn:aws:apigateway:us-east-2:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-2:123456789012:function:mock/invocations"
    }
  }
  mock_resource "aws_apigatewayv2_api" {
    defaults = { execution_arn = "arn:aws:execute-api:us-east-2:123456789012:mockapi" }
  }
}

variables {
  routes_file           = "tests/fixtures/three-routes.yaml"
  vpc_id                = "vpc-123"
  vpc_link_subnet_ids   = ["subnet-a", "subnet-b"]
  internal_listener_arn = "arn:aws:elasticloadbalancing:us-east-2:123456789012:listener/app/internal/abc/def"
  jwt_issuer            = "https://auth.example.test"
  jwt_secret            = "0123456789abcdef0123456789abcdef"
}

# ---------------------------------------------------------------------------
# 1. A "custom" route gets the authorizer attached.
#    Runs the exact module code edge pinned (platform-templates v0.1.0, downloaded by `terraform init`),
#    so the route resources themselves can be inspected.
run "custom_route_gets_authorizer" {
  command = plan

  module {
    source = "./.terraform/modules/routes/modules/api-gateway-routes"
  }

  variables {
    api_id        = "api-123"
    authorizer_id = "authz-123"
    vpc_link_id   = "vlink-123"
    listener_arn  = "arn:aws:elasticloadbalancing:us-east-2:123456789012:listener/app/internal/abc/def"
    routes        = yamldecode(file("tests/fixtures/three-routes.yaml")).routes
  }

  assert {
    condition     = length(aws_apigatewayv2_route.this) == 3
    error_message = "expected one route per routes.yaml entry"
  }
  assert {
    condition     = alltrue([for r in aws_apigatewayv2_route.this : r.authorization_type == "CUSTOM"])
    error_message = "every auth: custom route must have authorization_type CUSTOM"
  }
  assert {
    condition     = alltrue([for r in aws_apigatewayv2_route.this : r.authorizer_id == "authz-123"])
    error_message = "every auth: custom route must use the Lambda authorizer passed in"
  }
}

# ---------------------------------------------------------------------------
# 2. No route is created without a method.
run "no_route_without_method" {
  command = plan

  variables {
    routes_file = "tests/fixtures/missing-method.yaml"
  }

  # The plan fails on the edge precondition, and the module is handed zero routes,
  # so neither the bad route nor the valid one next to it is created.
  expect_failures = [aws_apigatewayv2_stage.default]
}

# ---------------------------------------------------------------------------
# 3. Removing a route from routes.yaml plans a destroy of only that route.
#    Step A: "apply" 3 routes (mocked), recording their IDs in this test's state.
run "apply_three_routes" {
  command = apply

  assert {
    condition     = toset(keys(output.route_ids)) == toset(["orders-create", "orders-list", "orders-get"])
    error_message = "expected 3 routes after the first apply"
  }
}

#    Step B: plan with orders-get removed.
run "remove_one_route_destroys_only_it" {
  command = plan

  variables {
    routes_file = "tests/fixtures/two-routes.yaml"
  }

  # The removed route (and its integration) are gone from the planned result...
  assert {
    condition     = toset(keys(output.route_ids)) == toset(["orders-create", "orders-list"])
    error_message = "orders-get should be planned for destroy; the other two should remain"
  }
  assert {
    condition     = !contains(keys(output.integration_ids), "orders-get")
    error_message = "orders-get's integration should be planned for destroy"
  }

  # ...and the surviving routes keep their IDs. A replace would give them new, unknown IDs and
  # these comparisons would fail, so this proves they're untouched.
  assert {
    condition = alltrue([
      for k in ["orders-create", "orders-list"] :
      output.route_ids[k] == run.apply_three_routes.route_ids[k]
    ])
    error_message = "remaining routes must not be replaced"
  }
  assert {
    condition = alltrue([
      for k in ["orders-create", "orders-list"] :
      output.integration_ids[k] == run.apply_three_routes.integration_ids[k]
    ])
    error_message = "remaining integrations must not be replaced"
  }
}
