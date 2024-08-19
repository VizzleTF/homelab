variable "vm_name" {
  description = "Name of the VM"
  type        = string
  default     = null
}

variable "node_name" {
  description = "Name of the node where the VM will be created"
  type        = string
  default     = null
}

variable "tags" {
  description = "List of tags to be associated with the VM"
  type        = list(string)
  default     = null
}

variable "vm_id" {
  description = "ID of the VM"
  type        = number
  default     = null
}

variable "cores" {
  description = "Number of CPU cores for the VM"
  type        = number
  default     = null
}

variable "ram" {
  description = "Amount of RAM for the VM"
  type        = number
  default     = null
}

variable "disk_size" {
  description = "Size of the disk for the VM"
  type        = number
  default     = null
}

variable "address" {
  description = "IP address for the VM"
  type        = string
  default     = null
}

variable "home_pc_public_key" {
  description = "Public key for SSH access"
  type        = string
  default     = null
}

variable "vm_password" {
  description = "Password for the VM"
  type        = string
  default     = null
}

variable "image_file" {
  description = "Path to the image file"
  type        = string
  default     = null
}

variable "pool_id" {
  description = "ID of the pool where the VM will be created"
  type        = string
  default     = null
}

variable "usb" {
  description = "Map a host USB device to a VM"
  type = object({
    host    = string
    mapping = string
    usb3    = bool
  })
  default = null
}

variable "description" {
  description = "Description of the VM"
  type        = string
  default     = null
}
