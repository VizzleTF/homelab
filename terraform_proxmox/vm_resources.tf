locals {
  vms_config = yamldecode(file("./configs/vms.yaml"))
  images = module.images
}

module "vms" {
  for_each = { for vm in local.vms_config.vms : vm.vm_name => vm }
  source = "git@github.com:VizzleTF/home_proxmox.git//terraform_proxmox/modules/vms?ref=v1.0.0"

  vm_name       = each.value.vm_name
  node_name  = try(each.value.node_name, "pve5")
  vm_id      = each.value.vm_id
  cores      = try(each.value.cores, "2")
  ram        = try(each.value.ram, "2048")
  disk_size  = try(each.value.disk_size, 50)
  address    = each.value.address
  tags       = concat(local.vms_config.tags,each.value.tags)
  vm_password = var.vm_password
  home_pc_public_key = var.home_pc_public_key
  image_file  = try(local.images[each.value.image_name].images[each.value.node_name].id, local.images["ol94"].images[each.value.node_name].id, "pve5")
  depends_on = [ module.images ]
}