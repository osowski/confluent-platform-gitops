# Remote State Bootstrap

Run these commands once, before the first `terraform init` in any root. The S3 bucket and DynamoDB table are shared across all Terraform roots in this repository — create them once and reuse the same names in each root's `backend "s3"` block.

```bash
# 1. Create the S3 bucket with versioning and SSE-S3 encryption
aws s3api create-bucket \
  --bucket <your-terraform-state-bucket> \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket <your-terraform-state-bucket> \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket <your-terraform-state-bucket> \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"},
      "BucketKeyEnabled": true
    }]
  }'

# Block all public access
aws s3api put-public-access-block \
  --bucket <your-terraform-state-bucket> \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# 2. Create the DynamoDB table for state locking (skip if already created)
aws dynamodb create-table \
  --table-name <your-terraform-lock-table> \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

After creating the resources, update the `backend "s3"` block in each root's `main.tf` with your actual bucket and table names.

## State Key Layout

Each root writes to a distinct key prefix within the shared bucket:

| Root | State key |
|------|-----------|
| `dns-bootstrap/` | `dns-bootstrap/terraform.tfstate` |
| `clusters/eks-demo/` | `eks-demo/terraform.tfstate` |
