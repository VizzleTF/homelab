# Schematic = file ("schematic.yaml") is the SINGLE source of truth for image extensions.
# The provider POSTs it to factory.talos.dev, gets back the content-addressed ID, and
# the installer URL is built from it. Editing schematic.yaml triggers a diff in
# install.image on every node's machineconfig — Talos hot-reloads this field (it's
# only consumed at next `talosctl upgrade`, not at config apply time), so apply does
# not reboot anything. Roll out the new image via scripts/talos-upgrade.sh upgrade-os.
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
  # Explicit install_image overrides; otherwise derive from schematic + talos_version.
  # Lets us bump Talos by touching one variable instead of hand-syncing installer digest.
  effective_install_image = var.install_image != "" ? var.install_image : data.talos_image_factory_urls.installer[0].urls.installer

  # cluster_endpoint derived from vip — single source of truth, no drift.
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

  common_patch = templatefile("${path.module}/patches/common.yaml.tftpl", {
    install_image = local.effective_install_image
    install_disk  = var.install_disk
    host_entries  = local.host_entries
  })

  controlplane_patch = templatefile("${path.module}/patches/controlplane.yaml.tftpl", {
    vip                 = var.vip
    cp_node_ips         = local.cp_node_ips
    apiserver_cert_sans = var.apiserver_cert_sans
  })

  node_patch = {
    for name, _ in var.nodes :
    name => templatefile("${path.module}/patches/node.yaml.tftpl", { hostname = name })
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
