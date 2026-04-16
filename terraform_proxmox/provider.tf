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
  }
}

# Auth:
#  1. Токен (по умолчанию): TF_VAR_proxmox_api_token=$(vault kv get -field=api_token home/homelab/terraform/proxmox-api-token).
#  2. Bootstrap (пока токена нет в Vault): TF_VAR_main_password + TF_VAR_proxmox_username.
# Если api_token не null — bpg игнорирует username/password.
provider "proxmox" {
  endpoint  = var.endpoint
  insecure  = true
  api_token = var.proxmox_api_token
  username  = var.proxmox_api_token == null ? var.proxmox_username : null
  password  = var.proxmox_api_token == null ? var.main_password : null
}

# Аутентификация — через переменные окружения VAULT_ADDR + VAULT_TOKEN.
provider "vault" {}
