module "subnets" {
  for_each = local.netplan

  source = "${var.stacks_root}/modules/subnet/"
  name       = "subnet-${each.key}"
  cidr_block = each.value
  az         = each.key
}

output "subnets" {
  # This is an "apply" output because it depends on random_id.vpc_suffix
  value = {for az, sn in module.subnets : az => sn.subnet}
}
