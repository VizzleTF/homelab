# https://registry.terraform.io/providers/bpg/proxmox/latest/docs
terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

provider "proxmox" {
  endpoint = var.endpoint
  insecure = true
  username = var.proxmox_username
  password = var.main_password
}