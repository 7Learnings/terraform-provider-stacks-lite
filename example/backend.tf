terraform {
  backend "local" {
    # can use var.stack_root, var.stack_path, and var.env
    path = "terraform.tfstate"
  }
}
