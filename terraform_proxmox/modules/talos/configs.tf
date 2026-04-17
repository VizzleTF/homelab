data "talos_image_factory_urls" "installer" {
  count = var.install_image == "" ? 1 : 0

  talos_version = var.talos_release
  schematic_id  = var.install_schematic_id
  platform      = var.install_platform
}

locals {
  # Explicit install_image overrides; otherwise derive from schematic + talos_version.
  # Lets us bump Talos by touching one variable instead of hand-syncing installer digest.
  effective_install_image = var.install_image != "" ? var.install_image : data.talos_image_factory_urls.installer[0].urls.installer

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
  cluster_endpoint   = var.cluster_endpoint
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
  cluster_endpoint   = var.cluster_endpoint
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
