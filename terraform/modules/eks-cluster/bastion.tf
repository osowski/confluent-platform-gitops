data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_iam_role" "bastion" {
  name = "${var.cluster_name}-bastion"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "bastion_s3" {
  name = "bastion-infra-binaries-s3"
  role = aws_iam_role.bastion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = ["arn:aws:s3:::${var.infra_binaries_bucket}/binaries/*"]
    }]
  })
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.cluster_name}-bastion"
  role = aws_iam_role.bastion.name
  tags = var.common_tags
}

resource "aws_security_group" "bastion" {
  name        = "${var.cluster_name}-bastion"
  description = "Bastion host - no inbound, SSM outbound only"
  vpc_id      = module.vpc.vpc_id

  # No inbound rules — all access via SSM Session Manager, no SSH

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS only - SSM, EKS API, ECR/S3 via VPC endpoints"
  }

  tags = merge(var.common_tags, { Name = "${var.cluster_name}-bastion" })
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.amazon_linux_2023.id
  instance_type               = "t3.small"
  subnet_id                   = module.vpc.private_subnets[0]
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  associate_public_ip_address = false

  # The bastion is a dumb SOCKS5 relay — operators tunnel through it via SSM
  # port-forwarding and authenticate to EKS using their local AWS credentials.
  # Do not run kubectl or AWS CLI on the bastion itself.
  user_data_base64            = base64encode(templatefile("${path.module}/scripts/bastion-init.sh", {
    infra_binaries_bucket = var.infra_binaries_bucket
    proxy_version         = var.proxy_version
  }))
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = merge(var.common_tags, { Name = "${var.cluster_name}-bastion" })
}
