variable "proxmox_endpoint" {
  description = "storage-106 的 PVE API。默认走 justfile `_tunnel` 建的 SSH 隧道（本机直连 :8006 不通）。"
  type        = string
  default     = "https://127.0.0.1:18006"
}

variable "proxmox_api_token" {
  description = "格式 root@pam!terraform=<uuid>，见 provider.tf 注释。"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "PVE 节点名（= 106 的 hostname）。"
  type        = string
  default     = "storage"
}

variable "proxmox_node_ssh_address" {
  description = "provider 跑磁盘导入时 SSH 登陆用的地址。走 Tailscale：LAN 地址在本机有两条竞争路由，Go dialer 会 EHOSTUNREACH（见 provider.tf 注释）。"
  type        = string
  default     = "100.110.27.111" # storage-106 tailscale
}

variable "ssh_private_key_path" {
  description = "全舰队 key。provider 不读 ~/.ssh/config，必须显式给。"
  type        = string
  default     = "~/.ssh/vgio"
}

variable "cloud_image_url" {
  description = "Ubuntu 24.04 cloud image。"
  type        = string
  default     = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

# --- worker VM（VMID 200，集群里叫 k8s-worker-106）---
# 尺寸依据：
# · 2026-08-13：8G 的机器，ARC 4G→2G 让出 2G 后 available≈3.5G，VM 3G + 宿主余量 ~0.5G。
# · 2026-08-16：ARC 2G→1G（storage-playbook.yaml tags:arc）再让出 1G → **VM 4G**，
#   为的是接住 jellyfin（实测峰值 800Mi/380m，稳态 332Mi）。
#   ⚠️ 这台 8G 的机器**到此为止**：`free -m` available 长期只有 ~550MB 且已在用 188MB swap，
#   ARC 也砍无可砍（1G 是 restic 元数据的下限）。再要内存只能加物理条，别再从 ARC 里挤。
# · 2c 不动 = J4105 四核的一半：另一半留给宿主的夜间 restic（哈希是 CPU 密集）。
#
# ☠️ 改 memory 是 in-place update，但**要 VM 关机重启才生效**（balloon: 0，无内存热插拔）。
#    而这台机现在是 prod worker：改之前先 `kubectl drain`，且它上面 local-path 的
#    PVC（navidrome/jellyfin）**跟不走** —— 那几个服务会中断到 VM 起来为止。
variable "vm_cores" {
  type    = number
  default = 2
}

variable "vm_memory" {
  description = "MiB"
  type        = number
  default     = 4096
}

variable "vm_disk_size" {
  description = "GiB，落 local-lvm（boot SSD 的 thinpool），刻意不碰 mrstorage 备份池。"
  type        = number
  default     = 30
}

variable "vm_ip" {
  description = "静态地址（2026-08-13 实测 .107 无 ping 响应、ARP INCOMPLETE）。⚠️ 若路由器 DHCP 池覆盖此段，记得加保留/排除。"
  type        = string
  default     = "192.168.50.107/24"
}

variable "vm_gateway" {
  type    = string
  default = "192.168.50.1"
}

variable "ssh_public_key" {
  description = "注入 ubuntu 用户的公钥（全舰队 vgio）。"
  type        = string
}
