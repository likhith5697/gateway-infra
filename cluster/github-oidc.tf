# Keyless deploys from GitHub Actions: the workflow swaps its OIDC token for short-lived AWS credentials.
# OFF by default: this account's AWS Organizations policy (free plan) denies iam:CreateOpenIDConnectProvider.
# Set enable_github_oidc = true after upgrading to a paid plan.

variable "enable_github_oidc" {
  description = "Create the GitHub OIDC provider, deploy role and EKS access entry."
  type        = bool
  default     = false
}

variable "github_org" {
  description = "GitHub org or user that owns the orders-app repo (the <GITHUB_ORG> part)."
  type        = string
  default     = ""

  validation {
    condition     = !var.enable_github_oidc || var.github_org != ""
    error_message = "Set github_org when enable_github_oidc = true."
  }
}

variable "github_repo" {
  description = "Repository allowed to deploy."
  type        = string
  default     = "orders-app"
}

variable "github_branch" {
  description = "Only workflows running on this branch can assume the role."
  type        = string
  default     = "main"
}

# Registers GitHub's OIDC issuer with IAM, so AWS trusts tokens signed by GitHub.
# There can be only one per account per URL: if it already exists, import it instead of creating it.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.enable_github_oidc ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # No thumbprint_list: AWS validates GitHub's certificate itself (supported in provider v5.81 and later).
}

# Trust policy: who can assume the role.
data "aws_iam_policy_document" "github_trust" {
  count = var.enable_github_oidc ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github[0].arn]
    }

    # The token must be issued for AWS STS...
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # ...and come from exactly this repo and branch (StringEquals, no wildcards).
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:ref:refs/heads/${var.github_branch}"]
    }
  }
}

# The role GitHub Actions assumes.
# Credentials last at most 1 hour and are never stored anywhere.
resource "aws_iam_role" "github_actions" {
  count = var.enable_github_oidc ? 1 : 0

  name               = "${var.name}-github-actions-orders"
  assume_role_policy = data.aws_iam_policy_document.github_trust[0].json
}

# Permissions: push images to the "orders" repo and look up the cluster (all kubectl needs to build a kubeconfig).
data "aws_iam_policy_document" "github_permissions" {
  count = var.enable_github_oidc ? 1 : 0

  # docker login to ECR. This action doesn't support a resource restriction, so it has to be "*".
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPushOrders"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [aws_ecr_repository.orders.arn]
  }

  statement {
    sid       = "EksDescribe"
    actions   = ["eks:DescribeCluster"]
    resources = [module.eks.cluster_arn]
  }
}

resource "aws_iam_role_policy" "github_actions" {
  count = var.enable_github_oidc ? 1 : 0

  name   = "ecr-push-eks-describe"
  role   = aws_iam_role.github_actions[0].id
  policy = data.aws_iam_policy_document.github_permissions[0].json
}

# Lets the role authenticate to the Kubernetes API.
# By itself this grants no permissions inside the cluster.
resource "aws_eks_access_entry" "github_actions" {
  count = var.enable_github_oidc ? 1 : 0

  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.github_actions[0].arn
  type          = "STANDARD"
}

# Grants "edit" (like the built-in Kubernetes edit role) in the orders namespace only.
# It can manage Deployments, Services, ConfigMaps and so on there, but can't touch other namespaces, nodes or RBAC.
resource "aws_eks_access_policy_association" "github_actions_orders_edit" {
  count = var.enable_github_oidc ? 1 : 0

  cluster_name  = module.eks.cluster_name
  principal_arn = aws_eks_access_entry.github_actions[0].principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["orders"]
  }
}

output "github_actions_role_arn" {
  description = "Put this in the workflow: aws-actions/configure-aws-credentials -> role-to-assume."
  value       = var.enable_github_oidc ? aws_iam_role.github_actions[0].arn : null
}
