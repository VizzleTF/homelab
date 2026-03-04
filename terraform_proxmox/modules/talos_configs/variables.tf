variable "talos_configs" {
  description = "Configuration object containing Talos configs and global settings"
  type = object({
    global = object({
      node_name    = string
      datastore_id = string
    })
    configs = map(object({
      enabled      = bool
      content_type = string
      config_data  = string
      file_name    = string
      # Allow overriding global settings per config
      node_name    = optional(string)
      datastore_id = optional(string)
    }))
  })
}