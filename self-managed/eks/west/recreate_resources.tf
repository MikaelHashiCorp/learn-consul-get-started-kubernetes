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
  subnet_id     = module.vpc.public_subnets[0]

  tags = {
    Name = "${local.name}-us-west-2a"
  }
}

# Load Balancers
resource "aws_lb" "consul_ui" {
  name               = "consul-ui"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [module.eks.node_security_group_id]
  subnets            = module.vpc.public_subnets

  tags = {
    "kubernetes.io/cluster/${local.name}" = "owned"
    "kubernetes.io/service-name"          = "consul/consul-ui"
  }
}

resource "aws_lb" "api_gateway" {
  name               = "api-gateway"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [module.eks.node_security_group_id]
  subnets            = module.vpc.public_subnets

  tags = {
    "kubernetes.io/cluster/${local.name}" = "owned"
    "kubernetes.io/service-name"          = "consul/api-gateway"
  }
}
