# Renders the machine config patches. No providers, so scripts/talos-validate.sh
# can render exactly what module.talos applies, offline and without state.

variable "install_image" {
  type = string
}

variable "gateway" {
  type = string
}

variable "vip" {
  type = string
}

variable "apiserver_cert_sans" {
  type = list(string)
}

variable "nodes" {
  type = map(object({
    address      = string
    address_cidr = string
    role         = string
    install_disk = string
    mac          = optional(string, "")
    labels       = optional(map(string), {})
  }))
}

locals {
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
}

output "common" {
  value = templatefile("${path.module}/common.yaml.tftpl", {
    install_image = var.install_image
    install_disk  = local.default_install_disk
    host_entries  = local.host_entries
    gateway       = var.gateway
  })
}

output "controlplane" {
  value = templatefile("${path.module}/controlplane.yaml.tftpl", {
    cp_node_ips         = local.cp_node_ips
    apiserver_cert_sans = var.apiserver_cert_sans
  })
}

output "node" {
  value = {
    for name, n in var.nodes :
    name => templatefile("${path.module}/node.yaml.tftpl", {
      hostname        = name
      address_cidr    = n.address_cidr
      gateway         = var.gateway
      vip             = var.vip
      install_disk    = n.install_disk
      is_controlplane = n.role == "controlplane"
      mac             = n.mac
      labels          = n.labels
    })
  }
}
