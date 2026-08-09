locals {
  # Filter to AZs that support Interface VPC endpoint services.
  # In us-east-1, us-east-1e is "available" but lacks endpoint service and NAT Gateway support.
  candidate_azs = slice(
    [for az in data.aws_availability_zones.available.names :
    az if contains(data.aws_vpc_endpoint_service.ssm.availability_zones, az)],
    0, 3
  )

  # The VPC module places the single NAT gateway in public_subnets[0], so whichever
  # AZ sorts first here decides where the NAT lands. NAT gateways are quota-limited
  # per AZ (L-FE5A380F, 20 by default); if that AZ is at quota, CreateNatGateway
  # returns Client.NatGatewayLimitExceeded and the private route table is left with
  # no default route — nodes then boot but never register. Set nat_gateway_az to
  # steer the NAT to an AZ with headroom.
  azs = var.nat_gateway_az == null ? local.candidate_azs : concat(
    [var.nat_gateway_az],
    [for az in local.candidate_azs : az if az != var.nat_gateway_az]
  )
}

# Guard against nat_gateway_az naming an AZ outside candidate_azs, which would
# otherwise silently widen the VPC to four AZs instead of erroring.
resource "terraform_data" "nat_gateway_az_validation" {
  lifecycle {
    precondition {
      condition     = var.nat_gateway_az == null ? true : contains(local.candidate_azs, var.nat_gateway_az)
      error_message = "nat_gateway_az must be one of the endpoint-capable AZs selected for this VPC: ${join(", ", local.candidate_azs)}."
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_vpc_endpoint_service" "ssm" {
  service      = "ssm"
  service_type = "Interface"
}
