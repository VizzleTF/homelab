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

  cluster_name = "talos-proxmox-cluster"
  vip          = "10.11.11.100" # модуль строит cluster_endpoint = https://${vip}:6443 и анонсирует VIP с CP-нод

  # Installer URL рендерится модулем: factory.talos.dev/<platform>-installer/<schematic>:<talos_release>.
  # talos_version — schema (vX.Y), talos_release — конкретный тег релиза.
  # schematic — modules/talos/schematic.yaml (содержание extensions), ID считает factory через talos_image_factory_schematic resource.
  # Текущий ID посмотреть: `terraform output -raw talos_schematic_id`.
  kubernetes_version = "v1.36.0"
  talos_version      = "v1.13"
  talos_release      = "v1.13.2"

  # VIP автоматически попадает в apiserver certSANs — дублировать не нужно
  apiserver_cert_sans = ["k8s.internal.example"]

  # vm_ids — replace-trigger source. См. modules/talos/apply.tf →
  # terraform_data.vm_identity. При -replace VM этот map становится partially
  # unknown, что каскадирует на time_sleep + talos_machine_configuration_apply.
  vm_ids = module.vms.vm_ids

  nodes = {
    for name, vm in local.vms_config.vms : name => {
      address       = split("/", vm.address)[0]
      role          = startswith(name, "talos-cp") ? "controlplane" : "worker"
      talos_managed = try(vm.talos_managed, false)
    } if vm.enabled && contains(coalesce(vm.tags, []), "talos")
  }
}

module "ansible_inventory" {
  source = "./modules/ansible_inventory"

  pve_hosts_config = local.pve_hosts_config
}

module "pve_rbac" {
  source = "./modules/pve_rbac"
}
