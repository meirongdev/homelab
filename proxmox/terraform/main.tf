# pve 上的 homelab 控制面 VM（VMID 100，节点名 `k8s-node`）。
#
# ☠️ 这是 prod 控制面：k3s server + Prometheus/Grafana/Alertmanager + Vault + cloudflared（公网入口）
#    全在上面，盘上有 homelab 全部 local-path PVC。任何触发 replace 的改动（`terraform plan`
#    出现 `-/+`）= 删 prod 数据，先停。`protection = true` 让 PVE API 直接拒绝删 VM/删盘，
#    `terraform destroy` 也会被它挡住（真要拆先 `qm set 100 --protection 0`）。
#
# ⚠️ 改动分两类，生效方式不同（这是 PVE 的语义，不是 provider 的）：
#   · 立即生效：description / tags / protection / ostype / tablet。
#   · **pending 到下次 VM 重启**：cores、memory（无热插拔）、scsi0 的 discard/ssd/iothread、
#     scsihw、vga。`qm pending 100` 能看到哪些还没落地。
#   provider 的 `reboot_after_update` 默认 **true**，会为 pending 改动**当场重启 VM**。这里显式
#   关掉：重启控制面 = homelab 全断约 3 分钟，必须由人挑窗口，顺带把 pending 一起落地
#   （窗口表与重启后的验证见 docs/runbooks/proxmox-host-upgrade.md）。
#
# 2026-09-09 补的四项（此前全是 PVE 默认值）：
#   · discard=on + ssd=1：之前 `discard=ignore`，客户机每周 fstrim 自报成功但 QEMU 全部丢弃，
#     thin LV 实占 98%（118G）而客户机只用 40G；周备因此每次全读 120G、归档 48GB 且几乎不含零块。
#     重启后在客户机跑一次 `sudo fstrim -av`，`lvs` 的 Data% 应掉到 35% 左右。
#   · iothread=1 + virtio-scsi-single：PVE 给新 VM 的默认组合，磁盘 I/O 不再挤主线程。
#   · vga=serial0 + tablet=0：无头 VM，noVNC 直接显示串口控制台，省掉 USB tablet 的轮询。
#   · protection=1 / ostype=l26 / tags：元数据，见上。
#
# ☠️ provider 0.85.1 的坑（2026-09-09 实测）：**既有盘的 discard / ssd / iothread 改动不会被送到 PVE**。
#    apply 报 "1 changed"、state 写成新值，但 `qm pending` 里没有 scsi0，下一次 plan 又出现同样的 diff
#    （provider 从 API 读回的是 PVE 的 pending 视图，所以它能察觉、只是送不出去）。scsihw / vga / ostype /
#    tablet / protection / tags 都正常送达。修法是在宿主上手动把整串 scsi0 写进 pending，再 plan 应为 No changes：
#      qm set 100 --scsi0 "local-lvm:vm-100-disk-0,aio=io_uring,backup=1,cache=none,discard=on,iothread=1,replicate=1,size=120G,ssd=1"
#    升 provider（ROADMAP 开放项 #16 ⑤）后拿这一项做回归验证。
resource "proxmox_virtual_environment_vm" "k8s" {
  name        = var.vm_name
  vm_id       = 100
  node_name   = var.proxmox_node
  description = "homelab 集群控制面 k8s-node（prod：k3s server + Prometheus/Grafana/Vault/cloudflared + 全部 local-path PVC）。安装流程: k8s/ansible"
  tags        = ["control-plane", "homelab", "k3s"] # PVE 会排序，这里必须按字母序写，否则永远有 diff
  on_boot     = true

  protection          = true
  reboot_after_update = false

  cpu {
    cores = var.vm_cores
    type  = "host"
  }

  memory {
    dedicated = var.vm_memory
  }

  operating_system {
    type = "l26"
  }

  agent {
    enabled = true
  }

  serial_device {}

  vga {
    type = "serial0"
  }

  tablet_device = false

  scsi_hardware = "virtio-scsi-single"

  disk {
    datastore_id = "local-lvm"
    file_id      = var.cloud_image_id
    interface    = "scsi0"
    size         = var.vm_disk_size
    discard      = "on"
    ssd          = true
    iothread     = true
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
      username = "ubuntu"
      keys     = [var.ssh_public_key]
    }
  }
}
