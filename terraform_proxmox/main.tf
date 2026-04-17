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

module "talos" {
  source = "./modules/talos"

  cluster_name       = "talos-proxmox-cluster"
  cluster_endpoint   = "https://10.11.11.101:6443"
  vip                = "10.11.11.100"
  kubernetes_version = "v1.36.0-beta.0"
  talos_version      = "v1.11"
  # Matches the schematic + version of the qcow2 in configs/images.yaml (v1.13.0-beta.1).
  # Old _out/*.yaml still reference stale v1.11.1 / different schematic — historical drift,
  # not reflected in running nodes.
  install_image = "factory.talos.dev/nocloud-installer/eed1860a28ccc6fdb77f1f41ab0ae2a20c19bc6101618d416d5d72ec919bf679:v1.13.0-beta.1"

  apiserver_cert_sans = ["k8s.internal.example"]

  nodes = {
    for name, vm in local.vms_config.vms : name => {
      address       = split("/", vm.address)[0]
      role          = startswith(name, "talos-cp") ? "controlplane" : "worker"
      talos_managed = coalesce(try(vm.talos_managed, false), false)
    } if vm.enabled && contains(coalesce(vm.tags, []), "talos")
  }
}

module "ansible_inventory" {
  source = "./modules/ansible_inventory"

  pve_hosts_config = local.pve_hosts_config
  admin_ssh_pubkey = var.pc_public_key
}

module "pve_rbac" {
  source = "./modules/pve_rbac"
}
