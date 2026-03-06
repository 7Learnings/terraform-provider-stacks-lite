resource "terraform_data" "organization" {
  input = {
    name       = var.project_name
    managed_by = var.managed_by
    owner      = var.owner
  }
}

output "org_name" {
  value = terraform_data.organization.output.name
}

output "owner" {
  value = terraform_data.organization.output.owner
}
