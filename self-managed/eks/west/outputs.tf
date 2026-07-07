output "kubernetes_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "kubernetes_cluster_id" {
  value = local.name
}

output "region" {
  value = var.vpc_region
}

output "vpc" {
  value = {
    vpc_id         = module.vpc.vpc_id
    vpc_cidr_block = module.vpc.vpc_cidr_block
  }
}

output "node_group_name" {
  value = module.eks.eks_managed_node_groups["consul"].node_group_id
}

output "nat_gateway_vpc_id" {
  value = module.vpc.natgw_ids[0]
}

output "nat_gateway_recreate_id" {
  value = aws_nat_gateway.main.id
}

output "lb_consul_ui_arn" {
  value = aws_lb.consul_ui.arn
}

output "lb_api_gateway_arn" {
  value = aws_lb.api_gateway.arn
}

output "eip_nat_id" {
  value = aws_eip.nat.id
}

output "eip_dp_id" {
  value = aws_eip.dp.id
}

output "node_group_min_size" {
  value       = var.node_min_size
  description = "EKS node group minimum size (source: var.node_min_size)."
}

output "node_group_max_size" {
  value       = var.node_max_size
  description = "EKS node group maximum size (source: var.node_max_size)."
}

output "node_group_desired_size" {
  value       = var.node_desired_size
  description = "EKS node group desired size (source: var.node_desired_size)."
}
