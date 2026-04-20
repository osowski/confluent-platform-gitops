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

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.cluster_name}-bastion"
  role = aws_iam_role.bastion.name
  tags = var.common_tags
}

resource "aws_security_group" "bastion" {
  name        = "${var.cluster_name}-bastion"
  description = "Bastion host — no inbound, SSM outbound only"
  vpc_id      = module.vpc.vpc_id

  # No inbound rules — all access via SSM Session Manager, no SSH

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSM agent, ECR, EKS API via VPC endpoints"
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

  # 3proxy built from source — avoids any repo availability uncertainty on AL2023.
  # Listens on 127.0.0.1:1080 — exposed to the laptop via SSM port forwarding.
  user_data_base64 = base64encode(<<-EOF
    #!/bin/bash
    set -euo pipefail

    yum install -y git gcc make

    git clone --depth 1 https://github.com/3proxy/3proxy.git /opt/3proxy
    cd /opt/3proxy && make -f Makefile.Linux
    install -m 755 bin/3proxy /usr/local/bin/3proxy

    mkdir -p /etc/3proxy /var/log/3proxy

    cat > /etc/3proxy/3proxy.cfg << 'CONF'
nscache 65536
log /var/log/3proxy/3proxy.log D
logformat "- +_L%t.%.  %N.%p %E %U %C:%c %R:%r %O %I %h %T"
socks -p1080 -i127.0.0.1
CONF

    cat > /etc/systemd/system/3proxy.service << 'UNIT'
[Unit]
Description=3proxy SOCKS5 proxy
After=network.target

[Service]
ExecStart=/usr/local/bin/3proxy /etc/3proxy/3proxy.cfg
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable 3proxy
    systemctl start 3proxy
  EOF
  )

  tags = merge(var.common_tags, { Name = "${var.cluster_name}-bastion" })
}
