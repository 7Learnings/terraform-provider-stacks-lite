terraform {
  required_providers {
    random = {
      source = "hashicorp/random"
      version = "~>3.5"
    }
    stacks = {
      source = "7learnings/stacks-lite"
    }
  }
}
