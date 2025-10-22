variable "vms" {
  description = "A map of virtual machines to create."
  type = map(object({
    cores    = number
    memory   = number
    user     = string
    password = string
    ip       = string
    gateway  = string
  }))
  default   = {}
}

variable "proxmox_node" {
  description = "The Proxmox node where the VMs will be created."
  type        = string
}