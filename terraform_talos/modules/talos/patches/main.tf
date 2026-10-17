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
    mac          = string
    labels       = optional(map(string), {})
  }))

  # LinkAliasConfig must match exactly one link; physical:true put the address
  # on every NIC of a multi-NIC box.
  validation {
    condition     = alltrue([for n in var.nodes : can(regex("^([0-9a-f]{2}:){5}[0-9a-f]{2}$", n.mac))])
    error_message = "Every node needs mac (lowercase, of the cabled NIC) in configs/nodes.yaml."
  }
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
}

output "common" {
  value = templatefile("${path.module}/common.yaml.tftpl", {
    install_image = var.install_image
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
