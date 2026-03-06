resource "terraform_data" "subnets" {
  for_each = local.netplan

  input = {
    name       = "subnet-${each.key}"
    cidr_block = each.value
    az         = each.key
  }
}

output "subnets" {
  # This is an "apply" output because it depends on random_id.vpc_suffix
  value = {for az, s in terraform_data.subnets : az => s.output}
}
