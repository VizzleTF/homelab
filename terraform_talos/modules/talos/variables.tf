variable "cluster_name" {
  description = "Talos cluster name"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version (matches kubelet image tag in Talos factory)"
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
  description = "Talos image factory platform. `metal` for bare-metal (ISO/PXE boot media); the installer URL itself is platform-agnostic for the running OS."
  type        = string
  default     = "metal"
}

variable "vip" {
  description = "VIP address advertised by control-plane nodes"
  type        = string
}

variable "gateway" {
  description = "Default IPv4 gateway for static node interfaces"
  type        = string
}

variable "apiserver_cert_sans" {
  description = "Additional SANs for kube-apiserver cert (external DNS, etc.)"
  type        = list(string)
  default     = []
}

variable "skip_health_check" {
  description = "Escape hatch: skip talos_cluster_health data source while debugging."
  type        = bool
  default     = false
}

variable "nodes" {
  description = "Map of enabled Talos nodes."
  type = map(object({
    address      = string # IP without CIDR (used for talosctl endpoint)
    address_cidr = string # IP/prefix (written into machine.network.interfaces[].addresses)
    role         = string # "controlplane" or "worker"
    install_disk = string
    mac          = optional(string, "") # Optional NIC MAC for hardwareAddr deviceSelector (bare-metal multi-NIC). Empty → physical:true.
  }))
}
