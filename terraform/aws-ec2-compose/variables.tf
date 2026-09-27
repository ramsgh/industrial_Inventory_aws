variable "aws_region" {
  description = "AWS region for the EC2 deployment."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Resource name prefix."
  type        = string
  default     = "industrial-inventory-compose"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.project_name))
    error_message = "project_name must be 3-31 lowercase letters, digits, or hyphens and start with a letter."
  }
}

variable "instance_type" {
  description = "EC2 instance type. t3.medium is recommended to fit MongoDB, three Java services, and the React dev server."
  type        = string
  default     = "t3.medium"
}

variable "allowed_client_cidr" {
  description = "Your public IPv4 address in CIDR notation, allowed to access the UI/API (for example 203.0.113.10/32)."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.allowed_client_cidr))
    error_message = "allowed_client_cidr must be a valid IPv4 CIDR range."
  }
}

variable "repository_url" {
  description = "HTTPS URL for a publicly readable Git repository containing the application."
  type        = string
  default     = "https://github.com/ramsgh/industrial_Inventory_aws.git"

  validation {
    condition     = can(regex("^https://", var.repository_url))
    error_message = "repository_url must use HTTPS."
  }
}

variable "repository_branch" {
  description = "Git branch the EC2 bootstrap clones."
  type        = string
  default     = "main"
}

variable "root_volume_size_gib" {
  description = "Encrypted EC2 root disk size in GiB."
  type        = number
  default     = 20

  validation {
    condition     = var.root_volume_size_gib >= 8 && floor(var.root_volume_size_gib) == var.root_volume_size_gib
    error_message = "root_volume_size_gib must be a whole number of at least 8."
  }
}

variable "mongo_volume_size_gib" {
  description = "Encrypted, separately attached persistent MongoDB data volume size in GiB."
  type        = number
  default     = 20

  validation {
    condition     = var.mongo_volume_size_gib >= 1 && floor(var.mongo_volume_size_gib) == var.mongo_volume_size_gib
    error_message = "mongo_volume_size_gib must be a positive whole number."
  }
}
