locals {
  vms_config       = yamldecode(file("./configs/vms.yaml"))
  images_config    = yamldecode(file("./configs/images.yaml"))
  pve_hosts_config = yamldecode(file("./configs/pve_hosts.yaml"))

  talos_config_keys = toset([
    for vm in values(local.vms_config.vms) : vm.talos_config
    if lookup(vm, "talos_config", null) != null
  ])
}

module "cloud_images" {
  source = "./modules/cloud_images"

  images_config = local.images_config
}

module "talos_configs" {
  source = "./modules/talos_configs"

  talos_configs = {
    global = {
      node_name    = "pve1"
      datastore_id = "synology"
    }
    configs = {
      for key in local.talos_config_keys : key => {
        enabled      = true
        content_type = "snippets"
        config_data  = file("${path.root}/_out/${key}.yaml")
        file_name    = "talos-${key}.yaml"
      }
    }
  }
}

module "vms" {
  source = "./modules/vms"

  vms_config     = local.vms_config
  image_file_ids = module.cloud_images.image_file_ids
  talos_file_ids = module.talos_configs.talos_file_ids
}

module "ansible_inventory" {
  source = "./modules/ansible_inventory"

  pve_hosts_config = local.pve_hosts_config
  admin_ssh_pubkey = var.pc_public_key
}

module "pve_rbac" {
  source = "./modules/pve_rbac"
}

module "pve_terraform_token" {
  source = "./modules/pve_terraform_token"
}
