resource "random_string" "testing" {
  length  = 16
  special = true

  lifecycle {
    postcondition {
      # Make sure there are no special characters
      condition     = can(regex("^[a-zA-Z0-9]*$", self.result))
      error_message = "The generated string contains special characters."
    }
  }
}

output "string_val" {
  value = random_string.testing.result
}