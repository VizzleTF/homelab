terraform {
  required_version = ">= 1.11"

  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "0.11.0-beta.2"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }
}
