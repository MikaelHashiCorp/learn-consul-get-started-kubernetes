variable "name" {
  description = "Cluster name"
  type        = string
  default     = "learn-consul-gs"
}

variable "vpc_region" {
  type        = string
  description = "The AWS region to create resources in"
  default     = "us-west-2"
}

variable "consul_version" {
  type        = string
  description = "The Consul version"
  default     = "v1.16.6"
}

variable "node_min_size" {
  description = "EKS node group minimum size."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "EKS node group maximum size."
  type        = number
  default     = 5
}

variable "node_desired_size" {
  description = "EKS node group desired size."
  type        = number
  default     = 3
}

# HC-COMPUTE-011: EDR (Uptycs) tag variables
variable "uptycs_update_tag" {
  description = "Uptycs UPDATE tag value. Must reflect deployment environment per IBM Tag Guide (e.g. UPDATE/PROD, UPDATE/DEV, UPDATE/NONE)."
  type        = string
  default     = "UPDATE/NONE"
}

variable "uptycs_owner" {
  description = "Uptycs OWNER tag value. Set to the team or owner email address (e.g. team@hashicorp.com)."
  type        = string
  default     = "team@hashicorp.com"
}

resource "random_string" "suffix" {
  length  = 2
  special = false
  upper   = false
}

locals {
  name = "${var.name}-${random_string.suffix.result}"
}