locals {
  nodes_sorted = {
    for name, n in var.nodes : name => n
  }

  host_entries = [
    for name, n in local.nodes_sorted : {
      ip      = n.address
      aliases = [name]
    }
  ]

  cp_node_ips = sort([
    for name, n in local.nodes_sorted : n.address if n.role == "controlplane"
  ])

  common_patch = templatefile("${path.module}/patches/common.yaml.tftpl", {
    install_image = var.install_image
    host_entries  = local.host_entries
  })

  controlplane_patch = templatefile("${path.module}/patches/controlplane.yaml.tftpl", {
    vip                 = var.vip
    cp_node_ips         = local.cp_node_ips
    apiserver_cert_sans = var.apiserver_cert_sans
  })
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

locals {
  node_patch = {
    for name, _ in var.nodes :
    name => templatefile("${path.module}/patches/node.yaml.tftpl", { hostname = name })
  }
}
