variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "ap-southeast-1"  
}

variable "project_name" {
  description = "Prefix for resource names"
  type        = string
  default     = "rj-infra-healer"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.20.1.0/24"
}

variable "instance_type" {
  description = "EC2 instance type (Free Tier = t2.micro or t3.micro)"
  type        = string
  default     = "t3.micro"
}
