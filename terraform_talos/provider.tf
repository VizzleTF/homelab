terraform {
  required_version = ">= 1.11"

  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "0.12.0"
    }
  }
}
