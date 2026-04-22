locals {
  # Filter to AZs that support Interface VPC endpoint services.
  # In us-east-1, us-east-1e is "available" but lacks endpoint service and NAT Gateway support.
  azs = slice(
    [for az in data.aws_availability_zones.available.names :
    az if contains(data.aws_vpc_endpoint_service.ssm.availability_zones, az)],
    0, 3
  )
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_vpc_endpoint_service" "ssm" {
  service      = "ssm"
  service_type = "Interface"
}
