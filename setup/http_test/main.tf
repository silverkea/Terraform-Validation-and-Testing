terraform {
  required_providers {
    http = {
        source = "hashicorp/http"
        version = "3.5.0"
    }
  }
}

variable "url" {
  description = "URL to check"
  type = string
}

data "http" "site_check" {
  url = var.url

  retry {
    attempts = 5
    min_delay_ms = 1000
  }
}