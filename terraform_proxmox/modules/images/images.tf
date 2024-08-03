terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

data "proxmox_virtual_environment_nodes" "available_nodes" {}
resource "proxmox_virtual_environment_download_file" "image" {
  for_each = toset(data.proxmox_virtual_environment_nodes.available_nodes.names)

  content_type = "iso"
  datastore_id = "local"
  node_name    = each.value
  url          = var.url
  file_name    = var.file_name
}

output "images" {
  value = proxmox_virtual_environment_download_file.image
}
