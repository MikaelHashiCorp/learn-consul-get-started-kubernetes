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

variable "server_count" {
  description = "The number of Nomad servers to run."
  type        = number
  default     = 3
}

resource "random_string" "suffix" {
  length  = 2
  special = false
  upper   = false
}

locals {
  name = "${var.name}-${random_string.suffix.result}"
}