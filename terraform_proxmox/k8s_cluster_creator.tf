locals {
  required_nodes = ["kube-node-01", "kube-node-02", "kube-node-03"]
}

resource "null_resource" "run_k8s_script" {
  count = length(setintersection(keys(module.vms), local.required_nodes)) == 3 ? 1 : 0

  depends_on = [module.vms, local_file.ansible_inventory]

  provisioner "local-exec" {
    command = "./cluster_create.sh"
  }

  triggers = {
    vms_created = join(",", [for name in local.required_nodes : module.vms[name].vm_id])
  }
}
