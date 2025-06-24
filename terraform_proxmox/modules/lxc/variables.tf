variable "vm_id" {
  description = "ID of the container"
  type        = number
  default     = null
}

variable "node_name" {
  description = "Name of the node where the container will be created"
  type        = string
  default     = null
}

variable "tags" {
  description = "List of tags to be associated with the container"
  type        = list(string)
  default     = null
}

variable "cores" {
  description = "Number of CPU cores for the container"
  type        = number
  default     = null
}

variable "ram" {
  description = "Amount of RAM for the container"
  type        = number
  default     = null
}

variable "disk_size" {
  description = "Size of the disk for the container"
  type        = number
  default     = null
}

variable "address" {
  description = "IP address for the container"
  type        = string
  default     = null
}

variable "home_pc_public_key" {
  description = "Public key for SSH access"
  type        = string
  default     = null
}

variable "container_password" {
  description = "Password for the container"
  type        = string
  default     = null
}

variable "template_file_id" {
  description = "Template file ID for the container"
  type        = string
  default     = null
}

variable "pool_id" {
  description = "ID of the pool where the container will be created"
  type        = string
  default     = null
}

variable "description" {
  description = "Description of the container"
  type        = string
  default     = null
}

variable "hostname" {
  description = "Hostname for the container"
  type        = string
  default     = null
}

variable "gateway" {
  description = "Gateway IP address for the container network"
  type        = string
  default     = "10.11.12.52"
}

variable "dns_servers" {
  description = "List of DNS servers for the container"
  type        = list(string)
  default     = ["10.11.12.170", "10.11.12.52"]
}

variable "datastore_id" {
  description = "Datastore ID for container storage"
  type        = string
  default     = "local-lvm"
}

variable "nesting" {
  description = "Enable nesting for the container"
  type        = bool
  default     = false
}

variable "mount_options" {
  description = "Mount options for the container"
  type        = list(string)
  default     = []
}

variable "os_type" {
  description = "Operating system type for the container"
  type        = string
  default     = "ubuntu"
}

variable "unprivileged" {
  description = "Whether the container should be unprivileged"
  type        = bool
  default     = true
}
