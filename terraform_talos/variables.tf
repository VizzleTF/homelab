variable "skip_health_check" {
  description = "Escape hatch: skip talos_cluster_health data source. Set true while bootstrapping a broken cluster so terraform plan/apply doesn't gate on health."
  type        = bool
  default     = false
}
