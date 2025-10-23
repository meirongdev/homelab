#  Create Ubuntu VM
resource "proxmox_virtual_environment_vm" "ubuntu_vm" {
  for_each = var.vms

  name      = each.key
  node_name = var.proxmox_node

  # Clone from the specified template
  clone {
    vm_id = var.template_vmid
    full          = true
  }

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
      keys     = [var.ssh_public_key]
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

  disk {
    # The disk interface must match the template's disk (scsi0 in this case)
    interface    = "scsi0"
    datastore_id = "local-lvm"
    size         = each.value.disk_size
    discard      = "on"
  }
}