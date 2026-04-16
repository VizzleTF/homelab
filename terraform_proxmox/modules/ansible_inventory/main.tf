locals {
  hosts = var.pve_hosts_config.hosts
  admin = var.pve_hosts_config.admin
}

resource "local_file" "inventory" {
  filename = "${path.root}/${var.inventory_dir}/inventory.yaml"
  content = templatefile("${path.module}/templates/inventory.yaml.tftpl", {
    hosts = local.hosts
  })
  file_permission = "0644"
}

resource "local_file" "group_vars_pve" {
  filename = "${path.root}/${var.inventory_dir}/group_vars/pve.yaml"
  content = templatefile("${path.module}/templates/group_vars_pve.yaml.tftpl", {
    admin_user            = local.admin.user
    admin_groups          = local.admin.groups
    admin_ssh_pubkey      = var.admin_ssh_pubkey
    trusted_cidrs         = var.pve_hosts_config.trusted_cidrs
    firewall_manager_host = var.pve_hosts_config.firewall_manager_host
  })
  file_permission = "0644"
}

resource "local_file" "pve_exporter_values" {
  filename = "${path.root}/${var.pve_exporter_values_path}"
  content = templatefile("${path.module}/templates/pve_exporter_values.yaml.tftpl", {
    hosts = local.hosts
  })
  file_permission = "0644"
}
