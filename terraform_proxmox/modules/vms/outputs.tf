output "vm_ids" {
  description = "Map of VM names to their IDs"
  value = {
    for key, vm in proxmox_virtual_environment_vm.vms : key => vm.id
  }
}
