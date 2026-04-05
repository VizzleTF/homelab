terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

locals {
  enabled_configs = {
    for key, config in var.talos_configs.configs : key => config
    if config.enabled
  }
}

resource "proxmox_virtual_environment_file" "talos_configs" {
  for_each = local.enabled_configs

  # Use config-specific settings with fallback to global settings
  node_name    = coalesce(each.value.node_name, var.talos_configs.global.node_name)
  datastore_id = coalesce(each.value.datastore_id, var.talos_configs.global.datastore_id)

  content_type = each.value.content_type

  source_raw {
    data      = each.value.config_data
    file_name = each.value.file_name
  }

  lifecycle {
    ignore_changes = [source_raw]
  }
}
