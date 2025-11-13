# Variables for Globomantics web application infrastructure

variable "company_name" {
  type        = string
  description = "Company name for resource naming"
  
  # Module 1: Alphanumeric, 3-20 characters
}

variable "environment" {
  type        = string
  description = "Environment name (dev, staging, prod)"
  
  # Module 1: Add validation to allow only dev, staging, or prod
}

variable "aws_region" {
  type        = string
  description = "AWS region for resource deployment"
  default     = "us-east-1"
  
  # Module 1: Add validation to ensure US regions only
}

variable "availability_zones" {
  type        = number
  description = "Number of availability zones to use"
  
  # Module 1: Add validation to ensure at least 2 AZs are provided
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC"
  default     = "10.0.0.0/16"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type for the web server"
  default     = "t3.micro"
  
  # Module 1: Add validation for approved instance types (t3.micro, t3.small, t3.medium)
}
