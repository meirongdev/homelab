# storage-106 上的 VM（VMID 200）。VM 名仍是 `k3s-exp`，**但它早已不是实验田**。
#
# ☠️ 2026-08-13 起它是 homelab 集群的 worker 节点 `k8s-worker-106`，跑 prod 负载
#    （navidrome / opencost / jellyfin / podcast / sloth / external-dns / trivy 扫描 Job），
#    并且**盘上有 prod 的 local-path PVC**（navidrome 的库、jellyfin 的 metadata）。
#    → `terraform destroy` / 任何触发 recreate 的改动 = **删 prod 数据**。改这个文件前，
#      先确认变更是 in-place update 而不是 replace（`terraform plan` 看有没有 `-/+`）。
#    → 名字改不了：rename 会触发 recreate，不值得（inventory 与文档里都注明了这层错位）。
#
# 定位与历史：
#   · 原始决策（独立实验田，已被取代）docs/decisions/storage106-experiment-vm.md
#   · 现行决策 docs/decisions/storage106-as-homelab-worker.md
#   · 入编流程在 k8s/ansible/：`just setup-tailscale-worker <key>` + `just join-worker`
#   · 备份：worker 侧 restic 夜备（backup/overlays/homelab/worker-cronjob.yaml）
#     + 106 上的整机周备 vzdump（proxmox/ansible `just vzdump-worker`）

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
  description = "homelab 集群的 worker 节点 k8s-worker-106（prod，盘上有 local-path PVC）。加入流程: k8s/ansible just join-worker"
  tags        = ["homelab", "k3s", "worker"]
  on_boot     = true

  # agent 设备必须启用（否则 guest agent 无 virtio 通道可用）；agent 本体由 ansible
  # 装（cloud image 不带）。timeout 压到 3m：首次 apply 时 agent 尚未安装，别按默认
  # 15m 干等——静态 IP 下 bpg 不依赖 agent 拿地址，等待只是礼貌性的。
  agent {
    enabled = true
    timeout = "3m"
  }

  # 无 agent 时优雅关机等不到响应，故 destroy 直接停机。
  # ⚠️ 这一行在实验田时代无所谓（无状态），现在**不是** —— 它上面有 prod PVC。
  # 保留是因为 destroy 本身就该先被上面那段 ☠️ 拦住，而不是靠这里做安全网。
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
