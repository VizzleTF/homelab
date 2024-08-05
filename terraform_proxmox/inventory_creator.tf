locals {
  all_hosts = {
    for vm in local.vms_config.vms :
    vm.vm_name => {
      ansible_host = split("/", vm.address)[0]
      ip           = split("/", vm.address)[0]
      access_ip    = split("/", vm.address)[0]
      ansible_user = "root"
    }
  }

  # Autodiscover all unique tags
  all_tags = distinct(flatten([for vm in local.vms_config.vms : vm.tags]))

  # Create a map of group to list of hosts in that group
  group_hosts = {
    for tag in local.all_tags :
    tag => [
      for vm in local.vms_config.vms :
      vm.vm_name
      if contains(vm.tags, tag)
    ]
  }

  # Special handling for k8s_cluster group
  k8s_cluster_children = [
    for tag in local.all_tags :
    tag
    if startswith(tag, "kube_")
  ]

  inventory = {
    all = {
      hosts = local.all_hosts
      children = merge(
        {
          for tag in local.all_tags :
          tag => {
            hosts = {
              for host in local.group_hosts[tag] :
              host => {}
            }
          }
        },
        {
          k8s_cluster = {
            children = {
              for child in local.k8s_cluster_children :
              child => {}
            }
          }
        }
      )
    }
  }
}

resource "local_file" "ansible_inventory" {
  content  = yamlencode(local.inventory)
  filename = "../ansible/inventory/inventory.yaml"

  depends_on = [module.vms]
}
