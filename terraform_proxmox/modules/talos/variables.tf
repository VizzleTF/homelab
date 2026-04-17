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
  description = "Talos schema version (vX.Y), not install image version"
  type        = string
  default     = "v1.11"
}

variable "install_image" {
  description = "Full Talos installer image reference (factory.talos.dev/...)"
  type        = string
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

variable "pod_subnets" {
  type    = list(string)
  default = ["10.244.0.0/16"]
}

variable "service_subnets" {
  type    = list(string)
  default = ["10.96.0.0/12"]
}

variable "nodes" {
  description = "Map of all Talos nodes; talos_managed gates post-boot apply flow"
  type = map(object({
    address       = string # IP without CIDR
    role          = string # "controlplane" or "worker"
    talos_managed = bool
  }))
}
