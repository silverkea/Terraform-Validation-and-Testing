resource "random_string" "testing" {
  length  = 26
  special = true

}

output "string_val" {
  value = random_string.testing.result

  precondition {
    # Make sure there are no special characters
    condition     = can(regex("^[a-zA-Z0-9]*$", random_string.testing.result))
    error_message = "The generated string contains special characters."
  }
}