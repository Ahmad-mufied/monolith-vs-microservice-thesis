terraform {
  required_version = ">= 1.6"

  required_providers {
    vultr = {
      source  = "vultr/vultr"
      version = "~> 2.31"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

