# EKS Pod Identity (not IRSA): IRSA needs an IAM OIDC provider, which this account's free plan denies.
# Pod Identity uses the eks-pod-identity-agent add-on (installed by ../cluster) and the pods.eks.amazonaws.com principal.

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "aws_lbc" {
  name               = "${var.name}-aws-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

# Official policy for this controller version, vendored from
# https://github.com/kubernetes-sigs/aws-load-balancer-controller/blob/v3.5.0/docs/install/iam_policy.json
resource "aws_iam_role_policy" "aws_lbc" {
  name   = "aws-load-balancer-controller"
  role   = aws_iam_role.aws_lbc.id
  policy = file("${path.module}/iam/aws-load-balancer-controller-v${var.aws_lbc_version}.json")
}

# Binds the role to the controller's ServiceAccount: pods using kube-system/aws-load-balancer-controller get its credentials.
resource "aws_eks_pod_identity_association" "aws_lbc" {
  cluster_name    = local.cluster_name
  namespace       = "kube-system"
  service_account = local.lbc_sa_name
  role_arn        = aws_iam_role.aws_lbc.arn
}
