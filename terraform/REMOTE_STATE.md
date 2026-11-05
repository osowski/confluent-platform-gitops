# Remote State Bootstrap

Run these commands once, before the first `terraform init` in any root. The S3 bucket is shared across all Terraform roots in this repository — create it once and reuse the same name in each root's `backend "s3"` block.

State locking uses S3 native lock files (`use_lockfile = true`, Terraform >= 1.11): Terraform writes `<state key>.tflock` next to the state object while it holds the lock, so no DynamoDB table is needed. Operators need `s3:GetObject`, `s3:PutObject` and `s3:DeleteObject` on both the state key and its `.tflock` key.

```bash
# Create the S3 bucket with versioning and SSE-S3 encryption
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

```

After creating the bucket, update the `backend "s3"` block in each root's `main.tf` with your actual bucket name.

## State Key Layout

Each root writes to a distinct key prefix within the shared bucket:

| Root | State key |
|------|-----------|
| `dns-bootstrap/` | `dns-bootstrap/terraform.tfstate` |
| `clusters/eks-demo/` | `eks-demo/terraform.tfstate` |
