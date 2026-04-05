locals {
  vms_config    = yamldecode(file("./configs/vms.yaml"))
  images_config = yamldecode(file("./configs/images.yaml"))

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
