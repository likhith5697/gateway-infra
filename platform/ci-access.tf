# Lets the apply-routes workflow apply HTTPRoutes, and nothing else.
#
# The CI IAM user is mapped to a Kubernetes *group* (no AWS access policy association), and the group is
# bound to a ClusterRole that only covers gateway.networking.k8s.io/httproutes (see the local chart:
# templates/ci-rbac.yaml). It can't read Secrets, touch Deployments, or change the Gateway itself.
resource "aws_eks_access_entry" "ci_apply" {
  cluster_name      = local.cluster_name
  principal_arn     = var.ci_apply_user_arn
  type              = "STANDARD"
  kubernetes_groups = [var.ci_routes_group]
}
