resource "terraform_data" "this" {
  input = substr(timestamp(), 0, 10)
}

output "random" {
  value = terraform_data.this.output
}

output "known" {
  value = "this is a known value"
}

output "complex" {
  value = {
    a = "b"
    c = [1, 2, 3]
  }
}
