# platform: Gateway API, Envoy Gateway, internal NLB

Installs what runs **inside** the cluster in front of the apps, plus the internal NLB that the edge stack's VPC Link targets.

```
API Gateway ──VPC Link──► internal NLB :80 (Terraform)
                             │ target group (IP targets) ◄── TargetGroupBinding keeps pod IPs registered
                             ▼
                          Envoy proxy pod :10080 (Envoy Gateway, Service ClusterIP "public-gateway-envoy")
                             │ Gateway "public-gateway" (gateway-system) + HTTPRoutes from render_httproutes.py
                             ▼
                          orders Service :8080 ──► orders pods :8000
```

State: same bucket/table as `cluster/`, key `platform/terraform.tfstate`. Reads VPC, subnets, node SG and cluster name from `cluster/`'s state.

## Versions (checked against the published charts and release notes)

| Component | Version | Notes |
|---|---|---|
| Envoy Gateway (`oci://docker.io/envoyproxy/gateway-helm`) | **v1.9.3** | Supports Kubernetes **1.33–1.36** (cluster is 1.36); end of life 2027-02-14 |
| Gateway API CRDs | **v1.6.1** | Bundled in the Envoy Gateway chart's `crds` subchart, so they always match the controller |
| AWS Load Balancer Controller (eks-charts) | **3.5.0** | Released 2026-08-03 with no patches since. IAM policy vendored from the same tag in `iam/` |
| Terraform providers | aws **6.72.0**, helm **3.3.0** | |

## How the NLB gets created

**Terraform creates it directly** (`nlb.tf`): an internal NLB in the private subnets, an IP target group, and a TCP listener on port 80. It does **not** come from a Kubernetes `Service type: LoadBalancer`.

1. **`nlb.tf`** creates the NLB, the target group (port 10080, IP targets, TCP health check), the listener, and security group rules: the VPC can reach the NLB on :80, and the NLB can reach the nodes on :10080.
2. **Envoy Gateway** creates the Envoy proxy Deployment and a Service for the Gateway. The `EnvoyProxy` resource makes that Service **`ClusterIP`** with a **fixed name** (`public-gateway-envoy`), so Kubernetes never asks AWS for a load balancer of its own.
3. **The AWS Load Balancer Controller** watches the **`TargetGroupBinding`** (in the local chart). It looks up the pods behind `public-gateway-envoy` and registers their IPs in Terraform's target group. When an Envoy pod is rescheduled, it deregisters the old IP and registers the new one.
4. **Envoy port:** Gateway API listener port 80 is privileged, so Envoy Gateway runs Envoy on **80 + 10000 = 10080** (`wellKnownPortShift`, `internal/gatewayapi/listener.go` in v1.9.3). The target group and security group rules use 10080.

**Why not let a controller create the NLB from a `LoadBalancer` Service?** That's the common approach, but then:
- the NLB is invisible to Terraform, so the listener ARN has to be scraped after the fact for `edge`;
- `terraform destroy` doesn't know about it, and a leftover NLB **blocks VPC deletion** and keeps billing.

With Terraform owning it, the ARN is an output and destroy removes it in the right order.

## Pod Identity, not IRSA

IRSA needs an IAM OIDC provider, which this free-plan account denies. `pod-identity.tf` instead creates:
- an IAM role trusted by `pods.eks.amazonaws.com` (`sts:AssumeRole` + `sts:TagSession`), carrying the official controller policy;
- an `aws_eks_pod_identity_association` for `kube-system/aws-load-balancer-controller`.

The `eks-pod-identity-agent` add-on, installed by `cluster/`, hands those credentials to the pod. The ServiceAccount needs no annotation.

## Outputs (for `edge/`)

`internal_listener_arn`, `vpc_id`, `vpc_link_subnet_ids`, plus `edge_tfvars`, a ready-to-paste block, and `nlb_dns_name`.

## Session runbook (order matters)

```bash
# 0. cluster/ applied, kubectl pointed at it (see cluster/README.md)
cd gateway-infra/platform
terraform init -backend-config=../cluster/backend.hcl
terraform plan -out=tfplan && terraform apply tfplan        # ~5 min

kubectl get gatewayclass,gateway -A                         # public-gateway: PROGRAMMED=True
kubectl -n envoy-gateway-system get svc,pods,targetgroupbinding
aws elbv2 describe-target-health --target-group-arn $(aws elbv2 describe-target-groups --names gateway-envoy --query 'TargetGroups[0].TargetGroupArn' --output text)   # healthy

# 1. app + routes
(cd ../../orders-app && scripts/deploy.sh)
python ../../platform-templates/render_httproutes.py ../../routes-repo/routes.yaml | kubectl apply -f -

# 2. edge
terraform output -raw edge_tfvars    # paste into ../edge/terraform.tfvars
```

**Destroy, in reverse order:**
1. `edge/`
2. this stack: `terraform destroy`. It removes the TargetGroupBinding first while the controller is still running, then the NLB.
3. `cluster/`

## Cost

The NLB is about **$0.0225/hr** plus a negligible LCU charge at test traffic. Everything else here runs as pods on the existing nodes:
- Envoy Gateway controller ×1
- Envoy proxy ×1
- Load Balancer Controller ×1

That keeps each t3.small node under its 11-pod limit.
