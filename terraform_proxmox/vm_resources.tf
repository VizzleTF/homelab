locals {
  vms_config = yamldecode(file("./configs/vms.yaml"))
}
module "vms" {
  for_each = { for vm in(local.vms_config.vms != null ? local.vms_config.vms : []) : vm.vm_name => vm }
  source   = "./modules/vms"

  vm_name            = each.value.vm_name
  node_name          = try(each.value.node_name, "pve5")
  vm_id              = each.value.vm_id
  cores              = try(each.value.cores, "2")
  ram                = try(each.value.ram, "2048")
  disk_size          = try(each.value.disk_size, 50)
  address            = each.value.address
  tags               = concat(local.vms_config.tags, each.value.tags)
  vm_password        = var.vm_password
  home_pc_public_key = file("~/.ssh/id_rsa.pub")
  image_file         = try(module.images[each.value.image_name].images[each.value.node_name].id, module.images["ol94"].images[each.value.node_name].id, module.images["ol94"].images["pve5"].id)
  pool_id            = try(each.value.pool_id, null)
  usb                = try(each.value.usb, null)
  description        = try(each.value.description, null)
}
