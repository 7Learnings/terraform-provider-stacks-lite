locals {
  # to be used throughout the network stacks
  netplan = {for i, az in var.availability_zones: az => cidrsubnet(var.cidr_block, 8, i)}
}

output "netplan" {
  # output netplan from all network stacks
  value = local.netplan
}
