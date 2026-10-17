resource "talos_image_factory_schematic" "this" {
  schematic = file("${path.module}/schematic.yaml")
}

data "talos_image_factory_urls" "installer" {
  count = var.install_image == "" ? 1 : 0

  talos_version = var.talos_release
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = var.install_platform
}

locals {
  effective_install_image = var.install_image != "" ? var.install_image : data.talos_image_factory_urls.installer[0].urls.installer

  cluster_endpoint = "https://${var.vip}:6443"
}

module "patches" {
  source = "./patches"

  install_image       = local.effective_install_image
  gateway             = var.gateway
  vip                 = var.vip
  apiserver_cert_sans = var.apiserver_cert_sans
  nodes               = var.nodes
}

data "talos_machine_configuration" "controlplane" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  kubernetes_version = var.kubernetes_version
  talos_version      = var.talos_version
  docs               = false
  examples           = false

  config_patches = [
    module.patches.common,
    module.patches.controlplane,
  ]
}

data "talos_machine_configuration" "worker" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  kubernetes_version = var.kubernetes_version
  talos_version      = var.talos_version
  docs               = false
  examples           = false

  config_patches = [
    module.patches.common,
  ]
}
