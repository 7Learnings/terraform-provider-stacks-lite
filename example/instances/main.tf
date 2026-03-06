resource "stacks" "vpc" {
  stack = "network/vpc"
}

locals {
  netplan = jsondecode(stacks.vpc.outputs["netplan"])
  zones = keys(local.netplan)
}

resource "terraform_data" "instances" {
  count = var.num_instances
  # for_each = {for i in range(var.num_instances): i => local.zones[i % length(local.zones)]}

  input = {
    name      = "server-${count.index}"
    vpc_id    = stacks.vpc.outputs["vpc_id"]
    zone = local.zones[count.index % length(local.zones)]
    subnet = local.netplan[local.zones[count.index % length(local.zones)]]
  }
}

output "instances" {
  value = [for i in terraform_data.instances : i.output]
}
