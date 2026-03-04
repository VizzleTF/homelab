locals {
  vms_config    = yamldecode(file("./configs/vms.yaml"))
  images_config = yamldecode(file("./configs/images.yaml"))
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
      "controlplane" = {
        enabled      = true
        content_type = "snippets"
        config_data  = file("${path.root}/_out/controlplane.yaml")
        file_name    = "talos-controlplane.yaml"
      }
      "worker" = {
        enabled      = true
        content_type = "snippets"
        config_data  = file("${path.root}/_out/worker.yaml")
        file_name    = "talos-worker.yaml"
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
