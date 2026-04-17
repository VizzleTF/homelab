locals {
  vms_config       = yamldecode(file("./configs/vms.yaml"))
  images_config    = yamldecode(file("./configs/images.yaml"))
  pve_hosts_config = yamldecode(file("./configs/pve_hosts.yaml"))
}

module "cloud_images" {
  source = "./modules/cloud_images"

  images_config = local.images_config
}

module "vms" {
  source = "./modules/vms"

  vms_config     = local.vms_config
  image_file_ids = module.cloud_images.image_file_ids
}

module "talos" {
  source = "./modules/talos"

  cluster_name       = "talos-proxmox-cluster"
  cluster_endpoint   = "https://10.11.11.100:6443" # VIP, не IP одной CP
  vip                = "10.11.11.100"
  kubernetes_version = "v1.36.0-beta.0"
  talos_version      = "v1.13"
  install_image      = "factory.talos.dev/nocloud-installer/eed1860a28ccc6fdb77f1f41ab0ae2a20c19bc6101618d416d5d72ec919bf679:v1.13.0-beta.1"

  # cluster_endpoint host (VIP) автоматически попадает в apiserver certSANs — дублировать не нужно
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
