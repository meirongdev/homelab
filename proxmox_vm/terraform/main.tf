#  Create Ubuntu VM
resource "proxmox_virtual_environment_vm" "ubuntu_vm" {
  name      = "ubuntu"
  node_name = "pve"
  machine     = "q35"
  bios      = "ovmf"

  # should be true if qemu agent is not installed / enabled on the VM
  stop_on_destroy = true

  initialization {
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
    user_account {
      username = var.vm_user
      password = var.vm_password
    }
  }
  network_device {
    bridge       = "vmbr0"
  }
  cpu {
    cores = var.vm_cores
  }

  memory {
    dedicated = var.vm_memory
  }

  serial_device {}

  efi_disk {
    datastore_id = "local-lvm"
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_download_file.ubuntu_cloud_image.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 100
  }
}