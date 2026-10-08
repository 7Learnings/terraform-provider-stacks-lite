locals {
  # stack specific and shared JSON files, tracked via EXTRA_DEPS_org (see ../Makefile)
  config = jsondecode(file("${var.stacks_root}/${var.stack}/config.json"))
  tags   = jsondecode(file("${var.stacks_root}/common/tags.json"))
}

resource "terraform_data" "organization" {
  input = {
    name       = var.project_name
    managed_by = var.managed_by
    owner      = var.owner
    tier       = local.config.tier
    tags       = local.tags
  }
}

output "org_name" {
  value = terraform_data.organization.output.name
}

output "owner" {
  value = terraform_data.organization.output.owner
}
