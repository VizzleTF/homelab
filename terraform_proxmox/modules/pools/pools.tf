terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

resource "proxmox_virtual_environment_pool" "pool" {
  pool_id = var.pool_id
  comment = var.comment
}

output "pool_id" {
  value = proxmox_virtual_environment_pool.pool.pool_id
}
