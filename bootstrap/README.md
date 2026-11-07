# bootstrap: Terraform remote state

Creates the S3 bucket and DynamoDB table that every other Terraform stack in `gateway-infra/` uses as its backend.
Run this once per account and region. Its own state stays local in `terraform.tfstate`, since the backend doesn't exist yet.

## Resources

| Resource | What it does |
|---|---|
| `aws_s3_bucket.state` | Bucket that holds the state files, named `<prefix>-tfstate-<account-id>-<region>`.<br>The account ID makes the name globally unique. |
| `aws_s3_bucket_versioning.state` | Keeps every past version of each state file.<br>You can roll back if a state file gets corrupted or deleted. |
| `aws_s3_bucket_server_side_encryption_configuration.state` | Encrypts objects at rest with S3-managed keys (AES256).<br>State can contain secrets, so it's never stored in plain text. |
| `aws_s3_bucket_public_access_block.state` | Turns on all four public-access blocks.<br>The bucket can't be made public, even by mistake. |
| `aws_dynamodb_table.lock` | Lock table with key `LockID`, billed per request.<br>Stops two `terraform apply` runs from changing the same state at once. |

## Apply

Requires credentials for the target account (`aws sts get-caller-identity` should succeed).

```bash
cd gateway-infra/bootstrap
terraform init
terraform plan -var="region=us-east-2"
terraform apply -var="region=us-east-2"
terraform output backend_config   # paste into other stacks
```

**Cost:** close to $0. You pay a few cents per GB for S3 storage, and DynamoDB on-demand billing is free when idle.

## Against LocalStack instead (free, no AWS account)

```bash
pip install terraform-local
docker run -d -p 4566:4566 localstack/localstack
tflocal init && tflocal apply
```

## Teardown

`terraform destroy` fails while the bucket still contains state files; this is a deliberate safety net.
Delete the other stacks first, then empty the bucket, including all object versions.
