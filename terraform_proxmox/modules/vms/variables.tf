variable "vms_config" {
  description = "Configuration object containing VMs and global settings from YAML file"
  type = object({
    global = object({
      node_name         = string
      datastore_id      = string
      gateway           = string
      dns_servers       = list(string)
      cores             = number
      ram               = number
      disk_size         = number
      pool_id           = optional(string)
      boot_order        = list(string)
      startup_order     = number
      startup_up_delay  = number
      cpu_type          = string
      network_bridge    = string
      os_type           = string
      machine           = optional(string)
      image_file        = optional(string)
      vlan_id           = optional(string)
      description       = optional(string)
    })
    tags = list(string)
    vms = map(object({
      enabled           = bool
      vm_id             = number
      address           = string
      tags              = optional(list(string))
      description       = optional(string)
      # Allow overriding global settings per VM
      node_name         = optional(string)
      datastore_id      = optional(string)
      gateway           = optional(string)
      dns_servers       = optional(list(string))
      cores             = optional(number)
      ram               = optional(number)
      disk_size         = optional(number)
      pool_id           = optional(string)
      boot_order        = optional(list(string))
      startup_order     = optional(number)
      startup_up_delay  = optional(number)
      cpu_type          = optional(string)
      network_bridge    = optional(string)
      vlan_id           = optional(string)
      os_type           = optional(string)
      # VM-specific settings
      pc_public_key     = optional(string)
      vm_password       = optional(string)
      image_file        = optional(string)
      user_data_file_id = optional(string)
      talos_config      = optional(string)
      machine           = optional(string)
      hostpci           = optional(list(object({
        device  = string
        id      = string
        pcie    = optional(bool, true)
        rombar  = optional(bool, false)
        xvga    = optional(bool, false)
      })))
      usb               = optional(object({
        host    = string
        mapping = string
        usb3    = bool
      }))
    }))
  })
}

variable "image_file_ids" {
  description = "Map of image names to their file IDs from cloud_images module"
  type        = map(string)
  default     = {}
}

variable "talos_file_ids" {
  description = "Map of talos config names to their file IDs from talos_configs module"
  type        = map(string)
  default     = {}
}