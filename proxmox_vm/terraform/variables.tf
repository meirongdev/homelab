# --- Proxmox Provider Configuration ---
variable "proxmox_endpoint" {
  description = "The endpoint URL of the Proxmox API (e.g., https://pve.example.com:8006)."
  type        = string
}

variable "proxmox_username" {
  description = "The username for the Proxmox API (e.g., root@pam)."
  type        = string
}

variable "proxmox_password" {
  description = "The password for the Proxmox API."
  type        = string
  sensitive   = true
}

# --- VM Configuration ---
variable "vms" {
  description = "A map of virtual machines to create."
  type = map(object({
    cores    = number
    memory   = number
    disk_size = number
    user     = string
    ip       = string
    gateway  = string
  }))
  default   = {}
}

variable "proxmox_node" {
  description = "The Proxmox node where the VMs will be created."
  type        = string
}

variable "template_vmid" {
  description = "The VM ID of the Proxmox template to clone from."
  type        = number
  default     = 9000 # 匹配 Ansible playbook 中创建的模板 ID
}

variable "ssh_public_key" {
  description = "The SSH public key to add to the 'ubuntu' user."
  type        = string
  sensitive   = true
}