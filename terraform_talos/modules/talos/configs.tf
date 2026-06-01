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

  host_entries = [
    for name, n in var.nodes : {
      ip       = n.address
      hostname = name
    }
  ]

  cp_node_ips = sort([
    for _, n in var.nodes : n.address if n.role == "controlplane"
  ])

  # Use the install_disk from the first node as the common patch default.
  # Per-node install_disk override is layered via the node patch (see apply.tf).
  default_install_disk = try(values(var.nodes)[0].install_disk, "/dev/sda")

  common_patch = templatefile("${path.module}/patches/common.yaml.tftpl", {
    install_image = local.effective_install_image
    install_disk  = local.default_install_disk
    host_entries  = local.host_entries
    gateway       = var.gateway
  })

  controlplane_patch = templatefile("${path.module}/patches/controlplane.yaml.tftpl", {
    cp_node_ips         = local.cp_node_ips
    apiserver_cert_sans = var.apiserver_cert_sans
  })

  node_patch = {
    for name, n in var.nodes :
    name => templatefile("${path.module}/patches/node.yaml.tftpl", {
      hostname        = name
      address_cidr    = n.address_cidr
      gateway         = var.gateway
      vip             = var.vip
      install_disk    = n.install_disk
      is_controlplane = n.role == "controlplane"
      mac             = n.mac
    })
  }
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
    local.common_patch,
    local.controlplane_patch,
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
    local.common_patch,
  ]
}
