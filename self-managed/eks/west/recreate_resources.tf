provider "aws" {
  region = "us-west-2"
}

# Elastic IPs
resource "aws_eip" "nat" {
  domain = "vpc"
  tags = {
    Name = "consul-eks-ti-us-west-2a"
  }
}

resource "aws_eip" "dp" {
  domain = "vpc"
  tags = {
    Name = "consul-eks-dp-us-west-2a"
  }
}

# NAT Gateway
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = data.aws_subnet.public_a.id

  tags = {
    Name = "consul-eks-ti-us-west-2a"
  }
}

# Load Balancers
resource "aws_lb" "consul_ui" {
  name               = "consul-ui"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [data.aws_security_group.lb.id]
  subnets            = [data.aws_subnet.public_a.id, data.aws_subnet.public_b.id, data.aws_subnet.public_c.id]

  tags = {
    "kubernetes.io/cluster/consul-eks-ti" = "owned"
    "kubernetes.io/service-name"          = "consul/consul-ui"
  }
}

resource "aws_lb" "api_gateway" {
  name               = "api-gateway"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [data.aws_security_group.lb.id]
  subnets            = [data.aws_subnet.public_a.id, data.aws_subnet.public_b.id, data.aws_subnet.public_c.id]

  tags = {
    "kubernetes.io/cluster/consul-eks-ti" = "owned"
    "kubernetes.io/service-name"          = "consul/api-gateway"
  }
}

# Data sources for existing resources
data "aws_vpc" "main" {
  filter {
    name   = "tag:Name"
    values = ["consul-eks-ti"]
  }
}

data "aws_subnet" "public_a" {
  vpc_id = data.aws_vpc.main.id
  filter {
    name   = "tag:Name"
    values = ["consul-eks-ti-public-us-west-2a"]
  }
}

data "aws_subnet" "public_b" {
  vpc_id = data.aws_vpc.main.id
  filter {
    name   = "tag:Name"
    values = ["consul-eks-ti-public-us-west-2b"]
  }
}

data "aws_subnet" "public_c" {
  vpc_id = data.aws_vpc.main.id
  filter {
    name   = "tag:Name"
    values = ["consul-eks-ti-public-us-west-2c"]
  }
}

data "aws_security_group" "lb" {
  vpc_id = data.aws_vpc.main.id
  filter {
    name   = "tag:kubernetes.io/cluster/consul-eks-ti"
    values = ["owned"]
  }
}
