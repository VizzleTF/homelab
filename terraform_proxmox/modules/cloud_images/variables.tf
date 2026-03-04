variable "images_config" {
  description = "Configuration object containing images and global settings from YAML file"
  type = object({
    global = object({
      node_name      = string
      datastore_id   = string
      upload_timeout = optional(number, 3600)
      overwrite      = optional(bool, false)
    })
    images = map(object({
      enabled            = bool
      content_type       = string
      url                = string
      file_name          = optional(string)
      checksum           = optional(string)
      checksum_algorithm = optional(string)
      # Allow overriding global settings per image
      node_name          = optional(string)
      datastore_id       = optional(string)
      upload_timeout     = optional(number)
      overwrite          = optional(bool)
    }))
  })
}