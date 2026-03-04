output "talos_file_ids" {
  description = "Map of talos config names to their file IDs for use in VMs"
  value = {
    for key, config in proxmox_virtual_environment_file.talos_configs : key => config.id
  }
}
