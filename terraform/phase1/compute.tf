# Find the latest Amazon Linux 2023 AMI dynamically
# (Better than hardcoding an AMI ID that goes stale)
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# IAM role that the EC2 will assume
# This is what lets the EC2 talk to SSM, CloudWatch, etc.
resource "aws_iam_role" "ec2_role" {
  name = "${var.project_name}-ec2-role"

  # Trust policy: who is allowed to assume this role?
  # Answer: the EC2 service itself.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

# Attach the AWS-managed policy that allows SSM agent communication
resource "aws_iam_role_policy_attachment" "ssm_managed" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Attach CloudWatch agent policy (we'll use this in Session 2)
resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Instance profile — the "wrapper" that lets EC2 use the IAM role
# (EC2 can't attach roles directly; it needs an instance profile)
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# The EC2 instance itself
resource "aws_instance" "lab" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  # SSM agent is preinstalled on AL2023, but we ensure it's running
  # and also install 'stress' for our future load testing
  user_data = <<-EOF
    #!/bin/bash
    set -e
    dnf update -y
    systemctl enable --now amazon-ssm-agent
    dnf install -y stress procps-ng
  EOF

  # If only user_data changes, don't replace the instance
  user_data_replace_on_change = false

  tags = {
    Name = "${var.project_name}-lab-ec2"
    Role = "self-healing-target"
  }
}
