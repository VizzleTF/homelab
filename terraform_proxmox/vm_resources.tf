locals {
  vms_config     = yamldecode(file("./configs/vms.yaml"))
  required_nodes = ["kube-node-01", "kube-node-02", "kube-node-03"]
}

module "vms" {
  for_each = { for vm in local.vms_config.vms : vm.vm_name => vm }
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
}

resource "null_resource" "run_k8s_script" {
  count = length(setintersection(keys(module.vms), local.required_nodes)) == 3 ? 1 : 0

  depends_on = [module.vms]

  provisioner "local-exec" {
    command = "./cluster_create.sh"
  }

  triggers = {
    vms_created = join(",", [for name in local.required_nodes : module.vms[name].vm_id])
  }
}
