terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

resource "proxmox_virtual_environment_container" "container" {
  vm_id        = var.vm_id
  node_name    = var.node_name
  description  = var.description
  tags         = var.tags
  pool_id      = var.pool_id
  unprivileged = var.unprivileged

  startup {
    order    = "3"
    up_delay = "5"
  }

  cpu {
    cores = var.cores
  }

  disk {
    datastore_id = var.datastore_id
    size         = var.disk_size
  }

  memory {
    dedicated = var.ram
  }

  network_interface {
    name     = "eth0"
    bridge   = "vmbr0"
    firewall = false
  }

  operating_system {
    template_file_id = var.template_file_id
    type             = var.os_type
  }

  initialization {
    hostname = var.hostname

    ip_config {
      ipv4 {
        address = var.address
        gateway = var.gateway
      }
    }

    dns {
      servers = var.dns_servers
    }

    user_account {
      keys     = [trimspace(var.home_pc_public_key)]
      password = var.container_password
    }
  }

  features {
    nesting = var.nesting
    mount   = var.mount_options
  }

  lifecycle {
    ignore_changes = [
      initialization[0].user_account[0].keys,
    ]
  }
}

output "container_id" {
  value = proxmox_virtual_environment_container.container.id
}
