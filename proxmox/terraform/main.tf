# Create a single VM for K3s cluster
resource "proxmox_virtual_environment_vm" "k8s" {
  name        = var.vm_name
  node_name   = var.proxmox_node
  description = "Single-node K3s cluster"
  on_boot     = true

  cpu {
    cores = var.vm_cores
    type  = "host"
  }

  memory {
    dedicated = var.vm_memory
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = var.cloud_image_id
    interface    = "scsi0"
    size         = var.vm_disk_size
  }

  network_device {
    bridge = "vmbr0"
  }

  initialization {
    ip_config {
      ipv4 {
        address = var.vm_ip
        gateway = var.vm_gateway
      }
    }

    user_account {
      username = "root"
      keys     = [var.ssh_public_key]
    }
  }
}