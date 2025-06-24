locals {
  lxc_config = yamldecode(file("./configs/lxc.yaml"))
}

module "lxc" {
  for_each = { for container in(local.lxc_config.lxc != null ? local.lxc_config.lxc : []) : container.hostname => container }
  source   = "./modules/lxc"

  vm_id              = each.value.vm_id
  hostname           = each.value.hostname
  node_name          = try(each.value.node_name, "pve5")
  cores              = try(each.value.cores, 1)
  ram                = try(each.value.ram, 1024)
  disk_size          = try(each.value.disk_size, 8)
  address            = each.value.address
  tags               = concat(local.lxc_config.tags, each.value.tags)
  container_password = var.vm_password
  home_pc_public_key = file("~/.ssh/id_rsa.pub")
  template_file_id   = each.value.template_file_id
  pool_id            = try(each.value.pool_id, null)
  description        = try(each.value.description, null)
  gateway            = try(each.value.gateway, null)
  dns_servers        = try(each.value.dns_servers, null)
  datastore_id       = try(each.value.datastore_id, null)
  nesting            = try(each.value.nesting, false)
  mount_options      = try(each.value.mount_options, [])
  os_type            = try(each.value.os_type, "ubuntu")
  unprivileged       = try(each.value.unprivileged, true)
}
