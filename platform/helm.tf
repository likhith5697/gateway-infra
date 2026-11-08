# 1. Envoy Gateway + Gateway API CRDs (the chart's "crds" subchart installs Gateway API v1.6.1 and Envoy Gateway CRDs).
resource "helm_release" "envoy_gateway" {
  name             = "eg"
  repository       = "oci://docker.io/envoyproxy"
  chart            = "gateway-helm"
  version          = var.envoy_gateway_version
  namespace        = local.envoy_namespace
  create_namespace = true
  wait             = true
  timeout          = 600
}

# 2. AWS Load Balancer Controller: used ONLY for TargetGroupBinding (registering Envoy pod IPs in the
#    Terraform-made target group). It does not create load balancers here.
resource "helm_release" "aws_lbc" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.aws_lbc_version
  namespace  = "kube-system"
  wait       = true
  timeout    = 600

  values = [yamlencode({
    clusterName  = local.cluster_name
    region       = var.region # explicit, so the controller doesn't need IMDS
    vpcId        = local.vpc_id
    replicaCount = 1 # small nodes; one replica is enough for a lab
    serviceAccount = {
      create = true
      name   = local.lbc_sa_name # matches the Pod Identity association
    }
    # Don't let it rewrite other LoadBalancer Services; nothing else in this cluster should create LBs.
    enableServiceMutatorWebhook = false
  })]

  # Credentials must be in place before the controller starts.
  depends_on = [aws_eks_pod_identity_association.aws_lbc, aws_iam_role_policy.aws_lbc]
}

# 3. GatewayClass, EnvoyProxy, Gateway "public-gateway", and the TargetGroupBinding (local chart: no CRD-at-plan-time issues).
resource "helm_release" "public_gateway" {
  name             = "public-gateway"
  chart            = "${path.module}/charts/public-gateway"
  namespace        = var.gateway_namespace
  create_namespace = true
  wait             = true
  timeout          = 300

  values = [yamlencode({
    gatewayName      = var.gateway_name
    gatewayNamespace = var.gateway_namespace
    listenerPort     = var.listener_port
    envoyNamespace   = local.envoy_namespace
    envoyServiceName = local.envoy_service_name
    targetGroupArn   = aws_lb_target_group.envoy.arn
    ciRoutesGroup    = var.ci_routes_group
  })]

  # Destroy order matters too: this release (and its TargetGroupBinding) is removed BEFORE the controller,
  # so the controller is still running to deregister the targets.
  depends_on = [helm_release.envoy_gateway, helm_release.aws_lbc]
}
