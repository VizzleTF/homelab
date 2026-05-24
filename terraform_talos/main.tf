locals {
  nodes_config = yamldecode(file("./configs/nodes.yaml"))

  enabled_nodes = {
    for name, n in local.nodes_config.nodes : name => {
      address      = split("/", n.address)[0]
      address_cidr = n.address
      role         = n.role
      install_disk = n.install_disk
    } if try(n.enabled, false)
  }
}

module "talos" {
  source = "./modules/talos"

  cluster_name        = local.nodes_config.cluster.name
  kubernetes_version  = local.nodes_config.cluster.kubernetes_version
  talos_version       = local.nodes_config.cluster.talos_version
  talos_release       = local.nodes_config.cluster.talos_release
  vip                 = local.nodes_config.cluster.vip
  gateway             = local.nodes_config.cluster.gateway
  apiserver_cert_sans = local.nodes_config.cluster.apiserver_cert_sans

  nodes = local.enabled_nodes

  skip_health_check = var.skip_health_check
}
