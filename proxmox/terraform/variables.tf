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
variable "vm_name" {
  description = "The name of the VM."
  type        = string
  default     = "k8s-node"
}

variable "vm_cores" {
  description = "Number of CPU cores for the VM."
  type        = number
  default     = 6
}

variable "vm_memory" {
  description = "Dedicated memory (MB) for the VM."
  type        = number
  default     = 8192
}

variable "vm_disk_size" {
  description = "Disk size (GB) for the VM."
  type        = number
  default     = 120
}

variable "vm_ip" {
  description = "Static IP address for the VM (CIDR notation, e.g. 10.10.10.10/24)."
  type        = string
}

variable "vm_gateway" {
  description = "Gateway IP for the VM."
  type        = string
}

variable "proxmox_node" {
  description = "The Proxmox node where the VM will be created."
  type        = string
}

variable "cloud_image_id" {
  description = "The cloud image file ID (e.g. local:iso/ubuntu-24.04-cloudimg-amd64.img)."
  type        = string
}

variable "ssh_public_key" {
  description = "The SSH public key to add to the root user."
  type        = string
  sensitive   = true
}