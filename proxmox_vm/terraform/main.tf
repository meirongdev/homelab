data "proxmox_virtual_environment_file" "ubuntu_cloud_image" {
  datastore_id = "iso-templates"
  content_type = "iso"
  node_name    = var.proxmox_node
  file_name    = "ubuntu-24.04-noble-cloudimg.img"
}

#  Create Ubuntu VM
resource "proxmox_virtual_environment_vm" "ubuntu_vm" {
for_each = var.vms

  name      = each.key
  node_name = var.proxmox_node
  machine   = "q35"
  bios      = "ovmf"

  # should be true if qemu agent is not installed / enabled on the VM
  stop_on_destroy = true

  initialization {
    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = each.value.gateway
      }
    }
    user_account {
      username = each.value.user
      password = each.value.password
    }
  }
  network_device {
    bridge = "vmbr0"
  }
  cpu {
    cores = each.value.cores
  }

  memory {
    dedicated = each.value.memory
  }

  serial_device {}

  efi_disk {
    datastore_id = "local-lvm"
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = data.proxmox_virtual_environment_file.ubuntu_cloud_image.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 100
  }
}