terraform {
  backend "local" {
    # can use var.stack_root, var.stack_path, and var.stacks_env
    # if you need a different backend type you can use an env-specific override file, e.g. backend_override.dev.tf
    path = "terraform.tfstate"
  }
}
