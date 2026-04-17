# https://registry.terraform.io/providers/bpg/proxmox/latest/docs
terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
    vault = {
      source = "hashicorp/vault"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.10.1"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

# Auth: TF_VAR_proxmox_username + TF_VAR_main_password.
provider "proxmox" {
  endpoint = var.endpoint
  insecure = true
  username = var.proxmox_username
  password = var.main_password

  ssh {
    agent    = true
    username = "root"
  }
}

# Аутентификация — через переменные окружения VAULT_ADDR + VAULT_TOKEN.
provider "vault" {}
