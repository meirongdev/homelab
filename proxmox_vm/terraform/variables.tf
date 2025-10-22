variable "vm_user" {
  description = "The username for the new VM."
  type        = string
  default     = "user"
}

variable "vm_password" {
  description = "The password for the new VM user."
  type        = string
  sensitive   = true
}

variable "vm_cores" {
  description = "The number of CPU cores for the VM."
  type        = number
  default     = 2
}

variable "vm_memory" {
  description = "The amount of memory in MB for the VM."
  type        = number
  default     = 4096
}