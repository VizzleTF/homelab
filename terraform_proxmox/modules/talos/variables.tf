variable "cluster_name" {
  description = "Talos cluster name (must match existing cluster for import)"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version (matches existing kubelet image tag)"
  type        = string
}

variable "talos_version" {
  description = "Talos schema version (vX.Y, no patch) — passed to talos_machine_configuration."
  type        = string
}

variable "talos_release" {
  description = "Full Talos release tag (vX.Y.Z[-rc.N]) — used to resolve installer URL via image factory."
  type        = string
}

variable "install_image" {
  description = "Explicit installer image override. If empty, derived from talos_release + schematic ID computed from modules/talos/schematic.yaml."
  type        = string
  default     = ""
}

variable "install_platform" {
  description = "Talos image factory platform (nocloud for Proxmox qcow2 import)."
  type        = string
  default     = "nocloud"
}

variable "install_disk" {
  description = "Block device Talos installer writes to."
  type        = string
  default     = "/dev/sda"
}

variable "vip" {
  description = "VIP address advertised by control-plane nodes"
  type        = string
}

variable "apiserver_cert_sans" {
  description = "Additional SANs for kube-apiserver cert (external DNS, etc.)"
  type        = list(string)
  default     = []
}

variable "skip_health_check" {
  description = "Escape hatch: skip talos_cluster_health data source. Set true when debugging a broken cluster so terraform plan/apply doesn't gate on health."
  type        = bool
  default     = false
}

variable "nodes" {
  description = "Map of all Talos nodes; talos_managed gates post-boot apply flow"
  type = map(object({
    address       = string # IP without CIDR
    role          = string # "controlplane" or "worker"
    talos_managed = bool
  }))
}

# Sourced from `module.vms.vm_ids` — see modules/vms/outputs.tf. Plumbed in so that
# replace_triggered_by inside this module can react to VM destroy/recreate across
# the module boundary (which `replace_triggered_by` cannot do directly, since it
# only accepts resource references local to the module).
variable "vm_ids" {
  description = "Map of node names → bpg/proxmox VM resource IDs. Replace-trigger source: when a VM is recreated, var.vm_ids[<name>] becomes plan-time unknown, which forces terraform_data.vm_identity + time_sleep.wait_maintenance + talos_machine_configuration_apply to also replace for that node."
  type        = map(string)
  default     = {}
}
