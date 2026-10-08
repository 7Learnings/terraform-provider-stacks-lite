resource "stacks" "vpc" {
  stack = "network/vpc"
}

locals {
  netplan = jsondecode(stacks.vpc.outputs["netplan"])
  zones   = keys(local.netplan)
}

locals {
  # stack specific and shared JSON files, tracked via EXTRA_DEPS_instances (see ../Makefile)
  config = jsondecode(file("${var.stacks_root}/${var.stack}/config.json"))
  tags   = jsondecode(file("${var.stacks_root}/common/tags.json"))
}

resource "terraform_data" "instances" {
  count = var.num_instances
  # for_each = {for i in range(var.num_instances): i => local.zones[i % length(local.zones)]}

  input = {
    name   = "server-${count.index}"
    vpc_id = stacks.vpc.outputs["vpc_id"]
    zone   = local.zones[count.index % length(local.zones)]
    subnet = local.netplan[local.zones[count.index % length(local.zones)]]
    size   = local.config.size
    tags   = local.tags
  }
}

module "subnet" {
  source     = "./modules/subnet/"
  name       = "subnet-instances"
  cidr_block = "10.0.0.0/8"
  az         = "eu"
}

output "instances" {
  value = [for i in terraform_data.instances : i.output]
}
