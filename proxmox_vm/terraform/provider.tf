# Provider configuration
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.85.1"
    }
  }
}

provider "proxmox" {
  insecure = true // necessary because of self-signed certificates
}