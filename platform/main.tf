# Inputs from ../cluster (VPC, subnets, node SG, cluster name).
data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "cluster/terraform.tfstate"
    region = var.region
  }
}

locals {
  cluster_name       = data.terraform_remote_state.cluster.outputs.cluster_name
  vpc_id             = data.terraform_remote_state.cluster.outputs.vpc_id
  vpc_cidr           = data.terraform_remote_state.cluster.outputs.vpc_cidr_block
  private_subnet_ids = data.terraform_remote_state.cluster.outputs.private_subnet_ids
  node_sg_id         = data.terraform_remote_state.cluster.outputs.node_security_group_id

  envoy_namespace    = "envoy-gateway-system" # where Envoy Gateway runs its proxies
  envoy_service_name = "${var.gateway_name}-envoy"
  lbc_sa_name        = "aws-load-balancer-controller"
}

data "aws_eks_cluster" "this" {
  name = local.cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = local.cluster_name
}
