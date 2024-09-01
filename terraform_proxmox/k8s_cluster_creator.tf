variable "kubernetes_nodes" {
  type = list(object({
    name = string
    ip   = string
  }))
  default = [
    { name = "kube-node-01", ip = "10.11.12.241" },
    { name = "kube-node-02", ip = "10.11.12.242" },
    { name = "kube-node-03", ip = "10.11.12.243" }
  ]
}

locals {
  required_nodes = [for node in var.kubernetes_nodes : node.name]
  vms_created    = join(",", [for name in local.required_nodes : module.vms[name].vm_id])
}

resource "null_resource" "prepare_environment" {
  count = length(setintersection(keys(module.vms), local.required_nodes)) == length(local.required_nodes) ? 1 : 0

  depends_on = [module.vms, local_file.ansible_inventory]

  provisioner "local-exec" {
    command = "./scripts/prepare_environment.sh"
    environment = {
      ANSIBLE_FORCE_COLOR = "1"
      KUBE_NODES          = jsonencode(var.kubernetes_nodes)
    }
  }

  triggers = {
    vms_created    = local.vms_created
    script_changes = filemd5("./scripts/prepare_environment.sh")
  }
}

resource "null_resource" "setup_kubernetes" {
  count = length(setintersection(keys(module.vms), local.required_nodes)) == length(local.required_nodes) ? 1 : 0

  depends_on = [null_resource.prepare_environment]

  provisioner "local-exec" {
    command = "./scripts/setup_kubernetes.sh"
    environment = {
      ANSIBLE_FORCE_COLOR = "1"
      KUBE_NODES          = jsonencode(var.kubernetes_nodes)
    }
  }

  triggers = {
    prepare_environment_id = null_resource.prepare_environment[0].id
    script_changes         = filemd5("./scripts/setup_kubernetes.sh")
  }
}

resource "null_resource" "deploy_services" {
  count = length(setintersection(keys(module.vms), local.required_nodes)) == length(local.required_nodes) ? 1 : 0

  depends_on = [null_resource.setup_kubernetes]

  provisioner "local-exec" {
    command = "./scripts/deploy_services.sh"
    environment = {
      ANSIBLE_FORCE_COLOR = "1"
      KUBE_NODES          = jsonencode(var.kubernetes_nodes)
    }
  }

  triggers = {
    setup_kubernetes_id = null_resource.setup_kubernetes[0].id
    script_changes      = filemd5("./scripts/deploy_services.sh")
  }
}

