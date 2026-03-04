terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

locals {
  enabled_images = {
    for key, image in var.images_config.images : key => image
    if image.enabled
  }
}

resource "proxmox_virtual_environment_download_file" "cloud_images" {
  for_each = local.enabled_images

  # Use image-specific settings with fallback to global settings
  node_name    = coalesce(each.value.node_name, var.images_config.global.node_name)
  datastore_id = coalesce(each.value.datastore_id, var.images_config.global.datastore_id)

  content_type = each.value.content_type
  url          = each.value.url
  file_name    = each.value.file_name

  checksum           = each.value.checksum
  checksum_algorithm = each.value.checksum_algorithm

  upload_timeout = coalesce(each.value.upload_timeout, var.images_config.global.upload_timeout)
  overwrite             = coalesce(each.value.overwrite, var.images_config.global.overwrite)
}
