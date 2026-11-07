# cluster: VPC + EKS + ECR

Creates a VPC (2 AZs, public and private subnets, 1 NAT gateway), an EKS cluster with 2 × t3.small nodes in the private subnets, and an ECR repo `orders`.
State is stored in the S3 bucket and DynamoDB table created by `../bootstrap`.

> ## Estimated cost: about $4.80/day (~$145/month). This is NOT free tier.
>
> | Item | Per day |
> |---|---|
> | EKS control plane ($0.10/hr) | $2.40 |
> | NAT gateway ($0.045/hr, plus $0.045 per GB of traffic) | $1.08 + traffic |
> | Public IPv4 address for the NAT gateway ($0.005/hr) | $0.12 |
> | 2 × t3.small nodes ($0.0208/hr each) | $1.00 (covered by free-plan credits on newer accounts) |
> | 2 × ~20 GB gp3 node disks | $0.11 |
> | ECR (under 500 MB) | ~$0 |
>
> You're billed by the hour, including idle time. **Destroy the stack when you stop working.**
> Set a budget alert first: Billing → Budgets → Create budget → $10/month.

## Prerequisites

- `../bootstrap` applied, so the state bucket and lock table exist.
- AWS credentials for the right account: `aws sts get-caller-identity` shows your account ID.
- `terraform` >= 1.10, `aws` CLI v2 and `kubectl` installed.

## 1. Apply

```bash
cd gateway-infra/cluster

# Backend settings, taken from the bootstrap outputs
cp backend.hcl.example backend.hcl
# edit backend.hcl: bucket, region, dynamodb_table  (see: cd ../bootstrap && terraform output)

terraform init -backend-config=backend.hcl

# Your public IP, so only you can reach the cluster API.
# terraform.tfvars is loaded automatically (and gitignored).
echo "api_allowed_cidrs = [\"$(curl -s https://checkip.amazonaws.com)/32\"]" > terraform.tfvars

terraform plan -out=tfplan
terraform apply tfplan          # takes about 15 minutes
```

Check the plan before applying: it should only **add** resources (about 50–60), never change or destroy any.

## 2. Configure kubectl

```bash
aws eks update-kubeconfig --region us-east-2 --name gateway
```

This adds the cluster to `~/.kube/config` and **makes it your current context**. Check:

```bash
kubectl config current-context    # arn:aws:eks:us-east-2:<account-id>:cluster/gateway
```

`terraform output -raw kubeconfig_command` prints this command with the right region and name.
To switch back to another cluster later: `kubectl config use-context <name>`; `kubectl config get-contexts` lists them all.

## 3. Verify nodes are Ready

```bash
kubectl get nodes -o wide
```

Expected: 2 nodes, `STATUS` = `Ready`, internal IPs in `10.0.10.x` / `10.0.11.x` (the private subnets), no external IP.

```bash
# Wait until both are Ready (gives up after 5 minutes)
kubectl wait --for=condition=Ready nodes --all --timeout=300s

# System pods should all be Running
kubectl get pods -n kube-system
```

If nodes stay `NotReady`, check that the vpc-cni pods (`aws-node-*`) are Running in kube-system, and look at the node group in the EKS console under Compute.

## 4. Destroy everything safely

Run these in order.

```bash
# a. Confirm kubectl points at THIS cluster, not another one
kubectl config current-context

# b. Delete anything Kubernetes created in AWS outside Terraform.
#    LoadBalancer Services and Ingresses create load balancers that block VPC deletion.
kubectl get svc -A | grep LoadBalancer
kubectl delete svc <name> -n <namespace>          # for each one listed
kubectl get ingress -A                            # delete these too, if any

# c. Destroy the stack (takes about 10–15 minutes)
terraform destroy

# d. Remove the dead cluster from kubeconfig
kubectl config delete-context arn:aws:eks:us-east-2:<account-id>:cluster/gateway
```

Then confirm nothing billable is left in the region:

```bash
aws eks list-clusters --region us-east-2                                   # []
aws ec2 describe-nat-gateways --region us-east-2 \
  --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId'  # []
aws ec2 describe-addresses --region us-east-2 --query 'Addresses[].PublicIp' # []
aws elbv2 describe-load-balancers --region us-east-2 \
  --query 'LoadBalancers[].LoadBalancerName'                                  # []
```

**If `terraform destroy` hangs or fails on the VPC or subnets,** a leftover load balancer or network interface is usually still attached. Delete it in the EC2 console (Load Balancers / Network Interfaces), then run `terraform destroy` again.

Leave `../bootstrap` in place. It costs almost nothing, and the next `apply` of this stack reuses it.

## GitHub Actions deploy role (github-oidc.tf)

> **Off by default** (`enable_github_oidc = false`). On the AWS free plan, the organization policy denies `iam:CreateOpenIDConnectProvider`, so you deploy from your laptop for now.
> After upgrading to a paid plan, add `enable_github_oidc = true` and `github_org = "<you>"` to `terraform.tfvars` and apply.

The `orders-app` workflow on `main` gets temporary AWS credentials through OIDC, so no AWS keys are stored in GitHub.
It can push to ECR `orders`, run `eks:DescribeCluster`, and has Kubernetes **edit** rights in the `orders` namespace only.

```yaml
permissions:
  id-token: write   # required for OIDC
  contents: read
steps:
  - uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: <terraform output -raw github_actions_role_arn>
      aws-region: us-east-2
```

- **Create the `orders` namespace once as admin** (`kubectl apply -f ../../orders-app/k8s/namespace.yaml`). The CI role has no cluster-wide rights, so it can't create namespaces; CI should apply only `deployment.yaml` and `service.yaml`.
- **Don't add `environment:` to the deploy job.** It changes the token's `sub` claim to `repo:<org>/orders-app:environment:<name>`, which the trust policy rejects.

## Windows PowerShell equivalents

```powershell
# Write terraform.tfvars with your IP (ASCII: Terraform rejects a UTF-8 BOM)
$ip = (Invoke-RestMethod https://checkip.amazonaws.com).Trim()
"api_allowed_cidrs = [`"$ip/32`"]" | Set-Content -Encoding ascii terraform.tfvars

# Run the kubeconfig command from the Terraform output
Invoke-Expression (terraform output -raw kubeconfig_command)
```
