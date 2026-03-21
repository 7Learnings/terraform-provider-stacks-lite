variable "name" {}
variable "cidr_block" {}
variable "az" {}

resource "terraform_data" "subnet" {
  input = {
    name       = var.name
    cidr_block = var.cidr_block
    az         = var.az
  }
}

output "subnet" {
  value = terraform_data.subnet.output
}
