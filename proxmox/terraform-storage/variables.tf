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

# --- k3s-exp VM ---
# 尺寸依据（2026-08-13 实测，详见 docs/decisions/storage106-experiment-vm.md）：
# 8G 的机器，ARC 4G→2G（storage-playbook.yaml tags:arc）让出 2G 后 available≈3.5G，
# VM 3G + 宿主余量 ~0.5G + 7.7G 零使用的 swap 兜底。2c = J4105 四核的一半。
variable "vm_cores" {
  type    = number
  default = 2
}

variable "vm_memory" {
  description = "MiB"
  type        = number
  default     = 3072
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
