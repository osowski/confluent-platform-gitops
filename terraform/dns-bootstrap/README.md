# dns-bootstrap

Provisions two Route53 hosted zones and NS delegation for the eks-demo cluster deployment.

## What this creates

| Resource | Description |
|----------|-------------|
| `aws_route53_zone.root` | Hosted zone for `dspdemos.com` (root domain) |
| `aws_route53_zone.platform` | Hosted zone for `platform.dspdemos.com` (scoped for per-cluster IAM policies) |
| `aws_route53_record.platform_ns` | NS delegation record in root zone pointing to platform zone name servers |

## Remote State Bootstrap

See [terraform/REMOTE_STATE.md](../REMOTE_STATE.md) for the one-time S3 bucket and DynamoDB table setup. The bucket and table are shared across all Terraform roots — create them once, then use the same names in the `backend "s3"` block in `main.tf`.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
terraform init
terraform apply
```

## Post-apply: Registrar NS Update (required, one-time manual step)

After `terraform apply`, Route53 assigns four name servers to the root zone. You must
configure these at your domain registrar so that DNS queries for `dspdemos.com` are
answered by Route53 rather than your registrar's default name servers.

### Step 1: Get the name servers

```bash
terraform output root_zone_name_servers
```

This produces four NS records, for example:

```
ns-123.awsdns-45.com
ns-678.awsdns-90.net
ns-111.awsdns-22.org
ns-333.awsdns-44.co.uk
```

### Step 2: Update your registrar

Log in to your domain registrar (e.g. Namecheap, GoDaddy, Google Domains, Route53
Registrar) and replace the current authoritative name servers for `dspdemos.com` with
the four values from Step 1.

**Registrar-specific paths:**

| Registrar | Where to find NS settings |
|-----------|--------------------------|
| Namecheap | Domain List → Manage → Nameservers → Custom DNS |
| GoDaddy | My Products → DNS → Nameservers → Change |
| Google Domains | DNS → Name servers → Use custom name servers |
| AWS Route53 Registrar | Registered domains → `dspdemos.com` → Name servers → Edit |

Remove all existing name servers and add the four Route53 values. No trailing dot is needed
— registrars accept them without it.

### Step 3: Verify propagation

DNS propagation can take up to 48 hours but typically completes within 15–30 minutes.
Verify with:

```bash
# Query the root zone SOA from one of the Route53 name servers directly
# Replace <ns-value> with one of the values from Step 1
dig SOA dspdemos.com @<ns-value-from-step-1>

# Verify global propagation (uses your default resolver)
dig NS dspdemos.com
# Expected: the four Route53 name servers in the ANSWER section
```

Once the NS records resolve correctly, proceed to apply the `eks-demo` Terraform root
(Task 3–6) and then the GitOps cluster configuration.

## Outputs

| Output | Description |
|--------|-------------|
| `root_zone_id` | Route53 zone ID for `dspdemos.com` |
| `root_zone_name_servers` | Four NS values to set at your registrar |
| `platform_zone_id` | Route53 zone ID for `platform.dspdemos.com` — pass to `eks-demo` Terraform as `platform_zone_id` |
| `platform_zone_name_servers` | Name servers for the platform zone — useful for debugging DNS propagation |
| `platform_domain` | Fully qualified platform domain (`platform.dspdemos.com`) |
