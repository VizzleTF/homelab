variable "cluster_name" {
  description = "Talos cluster name (must match existing cluster for import)"
  type        = string
}

variable "cluster_endpoint" {
  description = "Kubernetes API endpoint URL"
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
  description = "Explicit installer image override. If empty, derived from talos_release + install_schematic_id."
  type        = string
  default     = ""
}

variable "install_schematic_id" {
  description = "Talos image factory schematic ID for installer URL generation when install_image is empty."
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

variable "nodes" {
  description = "Map of all Talos nodes; talos_managed gates post-boot apply flow"
  type = map(object({
    address       = string # IP without CIDR
    role          = string # "controlplane" or "worker"
    talos_managed = bool
  }))
}
