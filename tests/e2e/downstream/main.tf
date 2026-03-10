terraform {
  required_providers {
    stacks = {
      source  = "7learnings/stacks-lite"
    }
  }
}

resource "stacks" "upstream" {
  stack = "upstream"
}

output "random" {
  value = stacks.upstream.outputs.random
}

output "known" {
  value = stacks.upstream.outputs.known
}

output "complex" {
  value = stacks.upstream.outputs.complex
}

output "complex_decoded" {
  value = jsondecode(stacks.upstream.outputs.complex)
}
