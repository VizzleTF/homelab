### Proxmox backup server ###

resource "proxmox_virtual_environment_vm" "pbs" {
  name      = "proxmox-backup-server"
  tags      = ["terraform", "pbs"]
  node_name = "home"
  vm_id     = 101

  cpu {
    cores = "2"
  }
  memory {
    dedicated = "2048"
  }
  startup {
    order    = "2"
    up_delay = "5"
  }
  disk {
    datastore_id = "data"
    file_id      = proxmox_virtual_environment_file.pbs_image.id
    interface    = "scsi0"
  }
  disk {
    datastore_id = "data"
    file_format  = "raw"
    interface    = "scsi1"
    size         = 15
  }
  disk {
    datastore_id = "data"
    file_format  = "raw"
    interface    = "scsi2"
    size         = 150
  }
  initialization {
    ip_config {
      ipv4 {
        address = "10.11.12.211/24"
        gateway = "10.11.12.1"
      }
    }
    user_account {
      keys     = [trimspace(var.home_pc_public_key)]
      password = var.vm_password
      username = "root"
    }
  }
  network_device {
    bridge = "vmbr0"
  }
  operating_system {
    type = "l26"
  }
}

### OKD NODES ###

resource "proxmox_virtual_environment_vm" "fedora_coreos_image" {
  for_each   = { for vm in local.okd_nodes : vm.name => vm }
  name       = each.value.name
  tags       = ["terraform", "coreos", "okd"]
  node_name  = each.value.node_name
  vm_id      = each.value.vm_id
  boot_order = ["scsi0"] # after ignite
  # boot_order = ["scsi1"] # before ignite
  # started    = false

  cpu {
    cores = each.value.cores
    type  = "host"
  }
  memory {
    dedicated = each.value.memory
  }
  startup {
    order    = "3"
    up_delay = "10"
  }
  disk {
    datastore_id = each.value.datastore_id
    file_format  = "raw"
    interface    = "scsi0"
    size         = 50
  }
  disk {
    datastore_id = each.value.datastore_id
    file_id      = "local:iso/fedora_core_os39.img"
    interface    = "scsi1"
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
  network_device {
    bridge      = "vmbr0"
    mac_address = each.value.mac_address
  }
  operating_system {
    type = "l26"
  }
}

resource "proxmox_virtual_environment_vm" "oracle_cloud_linux" {
  for_each   = { for vm in local.oracle_linux : vm.name => vm }
  name       = each.value.name
  tags       = each.value.tags
  node_name  = "pve2"
  vm_id      = each.value.vm_id
  boot_order = ["sata0"]

  cpu {
    cores        = "2"
    type         = "Haswell"
    architecture = "x86_64"
  }
  memory {
    dedicated = "2048"
  }
  startup {
    order    = "2"
    up_delay = "5"
  }
  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_download_file.oracle_cloud_image.id
    interface    = "sata0"
    size         = 50
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
  network_device {
    bridge = "vmbr0"
  }
  operating_system {
    type = "l26"
  }
}
