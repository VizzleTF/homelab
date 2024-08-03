locals {
  vms_config = yamldecode(file("./configs/vms.yaml"))
  # os = {
  #   oracle_cloud_image = proxmox_virtual_environment_download_file.oracle_cloud_image[0]
  # }
}

resource "proxmox_virtual_environment_vm" "vm" {
  for_each = { for vm in local.vms_config.vms : vm.vm_name => vm }
  
  name       = each.value.vm_name
  tags       = concat(local.vms_config.tags,each.value.tags)
  node_name  = try(each.value.node_name, "pve5")
  vm_id      = each.value.vm_id
  boot_order = ["sata0"]

  agent { enabled = true }
  cpu {
    cores        = try(each.value.cores, "2")
    type         = "host"
  }
  memory { dedicated = try(each.value.ram, "2048") }
  startup {
    order    = "2"
    up_delay = "5"
  }
  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_download_file.oracle_cloud_image[each.value.node_name].id
    # file_id      = try(local.os[each.value.os], proxmox_virtual_environment_download_file.oracle_cloud_image[each.value.node_name])
    interface    = "sata0"
    size         = try(each.value.disk_size, 50)
  }
  initialization {
    ip_config {
      ipv4 {
        address = each.value.address
        gateway = "10.11.12.1"
      }
    }
    user_account {
      keys     = [trimspace(var.home_pc_public_key)]
      password = var.vm_password
      username = "root"
    }
  }
  network_device { bridge = "vmbr0" }
  operating_system { type = "l26" }
}
