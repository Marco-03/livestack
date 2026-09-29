terraform {
  required_version = ">= 1.5.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 8.23"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}
