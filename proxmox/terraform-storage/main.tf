# k3s-exp：storage-106 上的实验田 VM。
#
# 定位（决策全文 docs/decisions/storage106-experiment-vm.md）：
#   独立单节点 k3s（VM 内由 proxmox/ansible `just exp-k3s` 安装），**不加入** homelab
#   集群、不接 ArgoCD / prod ingress / 备份白名单。实验负载全在这儿折腾，homelab 的
#   6.4G available 留给 prod。挂了、玩坏了 → terraform destroy/apply 重建即可。
#   106 "备份机不承担 prod 运行时依赖"（2026-07-11）的不变量不受影响：本 VM 非 prod。

resource "proxmox_virtual_environment_download_file" "ubuntu_noble" {
  node_name    = var.proxmox_node
  datastore_id = "local" # 106 的 local 只收 iso/vztmpl/backup；cloud image 按 iso 内容存放
  content_type = "iso"
  url          = var.cloud_image_url
  file_name    = "noble-server-cloudimg-amd64.img"
  overwrite    = false # 有同名文件就复用，别每次 apply 重拉 600MB
}

resource "proxmox_virtual_environment_vm" "k3s_exp" {
  name        = "k3s-exp" # cloud-init 会拿它当 hostname
  vm_id       = 200
  node_name   = var.proxmox_node
  description = "实验田：独立单节点 k3s（不入 homelab 集群）。ansible: proxmox/ansible just exp-k3s"
  tags        = ["exp", "k3s"]
  on_boot     = true

  # agent 设备必须启用（否则 guest agent 无 virtio 通道可用）；agent 本体由 ansible
  # 装（cloud image 不带）。timeout 压到 3m：首次 apply 时 agent 尚未安装，别按默认
  # 15m 干等——静态 IP 下 bpg 不依赖 agent 拿地址，等待只是礼貌性的。
  agent {
    enabled = true
    timeout = "3m"
  }

  # 无 agent 时优雅关机等不到响应；destroy 直接停机（实验田，无状态可虑）
  stop_on_destroy = true

  cpu {
    cores = var.vm_cores
    type  = "host"
  }

  memory {
    dedicated = var.vm_memory
  }

  serial_device {} # cloud image 的内核控制台走 ttyS0，qm terminal 排障用

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_download_file.ubuntu_noble.id
    interface    = "scsi0"
    size         = var.vm_disk_size
  }

  network_device {
    bridge = "vmbr0" # 直挂 LAN 192.168.50.0/24
  }

  initialization {
    ip_config {
      ipv4 {
        address = var.vm_ip
        gateway = var.vm_gateway
      }
    }

    dns {
      servers = ["192.168.50.1", "1.1.1.1"]
    }

    user_account {
      username = "ubuntu"
      keys     = [var.ssh_public_key]
    }
  }
}

output "vm_ip" {
  value = var.vm_ip
}
