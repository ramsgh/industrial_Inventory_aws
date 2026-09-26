variable "aws_region" {
  description = "AWS region for the application resources."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Lowercase project name used to name AWS resources."
  type        = string
  default     = "industrial-inventory"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,19}$", var.project_name))
    error_message = "project_name must be 3-20 lowercase letters, digits, or hyphens and start with a letter."
  }
}

variable "az_count" {
  description = "Number of availability zones to use."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be between 2 and 3."
  }
}

variable "desired_count" {
  description = "Number of tasks per service. Start at 0 until application images have been pushed to ECR."
  type        = number
  default     = 0

  validation {
    condition     = var.desired_count >= 0 && floor(var.desired_count) == var.desired_count
    error_message = "desired_count must be a non-negative whole number."
  }
}

variable "image_tag" {
  description = "Tag used for the Java service images in ECR."
  type        = string
  default     = "latest"
}

variable "vpc_cidr" {
  description = "CIDR range for the application VPC."
  type        = string
  default     = "10.40.0.0/16"

  validation {
    condition = can(cidrnetmask(var.vpc_cidr)) && (
      try(tonumber(split("/", var.vpc_cidr)[1]), 32) >= 16 &&
      try(tonumber(split("/", var.vpc_cidr)[1]), 0) <= 20
    )
    error_message = "vpc_cidr must be a valid IPv4 network between /16 and /20."
  }
}
