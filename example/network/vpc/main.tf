resource "random_id" "vpc_suffix" {
  byte_length = 4
}

resource "terraform_data" "vpc" {
  input = {
    name       = "${var.environment}-${var.region}"
    cidr_block = var.cidr_block
    vpc_id     = "vpc-${random_id.vpc_suffix.hex}"
  }
}

output "vpc_id" {
  value = terraform_data.vpc.output.vpc_id
}

output "cidr_block" {
  # This is a known output as it comes directly from a variable
  value = var.cidr_block
}

output "vpc_name" {
  # This is also mostly known, but we'll use the one from the resource
  value = terraform_data.vpc.input.name
}
