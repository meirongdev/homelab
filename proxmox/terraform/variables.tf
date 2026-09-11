# --- Proxmox provider ---
variable "proxmox_endpoint" {
  description = "pve 的 PVE API。默认走 justfile `_tunnel` 建的 SSH 隧道（本机直连 :8006 不通，见 README）；justfile 还会用 -var 强制这个值，免得旧 tfvars 里的 LAN 地址盖掉它。"
  type        = string
  default     = "https://127.0.0.1:18007"
}

variable "proxmox_username" {
  description = "root@pam。换 API token 的三步见 provider.tf 注释。"
  type        = string
  default     = "root@pam"
}

variable "proxmox_password" {
  description = "root@pam 的密码，只放 gitignored 的 terraform.tfvars。"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "PVE 节点名（= pve 的 hostname）。"
  type        = string
  default     = "pve"
}

variable "proxmox_node_ssh_address" {
  description = "provider 跑磁盘导入时 SSH 登陆用的地址。走 Tailscale：LAN 地址在本机有两条竞争路由，Go dialer 会 EHOSTUNREACH（见 ../terraform-storage/provider.tf）。"
  type        = string
  default     = "100.118.193.51" # pve tailscale
}

variable "ssh_private_key_path" {
  description = "全舰队 key。provider 不读 ~/.ssh/config，必须显式给。"
  type        = string
  default     = "~/.ssh/vgio"
}

# --- 控制面 VM（VMID 100，节点名 k8s-node）---
# 尺寸依据（唯一真相源是 docs/reference/homelab-host-power-thermal.md 的「内存分配链」）：
# · 宿主 16GB 物理、OS 可见 15.0GB（核显 UMA 已收到 512MB）；VM 13312MB 硬分配、balloon 0。
#   k8s 节点**不能**开 balloon：kubelet 按 MemTotal 算 allocatable，balloon 收走的内存它看不见，
#   等于静默超卖。宿主 `free -m` available 长期只剩几百 MB（2026-09-09 实测 608MB、swap 1.1G
#   但 PSI 为 0、无换入换出），**别再加**。
# · 10 vCPU / 宿主 12 线程：留 2 个线程给宿主自己（tailscaled、pvestatd、周日 vzdump）。
# ☠️ 2026-09-09 之前这些真值只存在于 gitignored 的 terraform.tfvars，而本文件默认值写 6c/8G、
#    tfvars.example 写 11c/15G —— 三处三个数，git 里没有一处是对的。现在默认值就是真值，
#    tfvars 只放密钥（密码 + 公钥）。
variable "vm_name" {
  type    = string
  default = "k8s-node"
}

variable "vm_cores" {
  type    = number
  default = 10
}

variable "vm_memory" {
  description = "MiB"
  type        = number
  default     = 13312
}

variable "vm_disk_size" {
  description = "GiB，落 local-lvm（pve 启动 NVMe 的 thinpool）。"
  type        = number
  default     = 120
}

variable "vm_ip" {
  description = "pve vmbr0 第二地址段 10.10.10.0/24 里的静态地址；网关是 pve 自己（NAT 出 LAN），见 docs/reference/tailscale-network.md。"
  type        = string
  default     = "10.10.10.10/24"
}

variable "vm_gateway" {
  type    = string
  default = "10.10.10.1"
}

variable "cloud_image_id" {
  description = "cloud image 的 volid；由 proxmox/ansible `just download-cloud-image` 事先下到 pve（106 root 改用 download_file 资源，这边建 VM 时还没有那写法）。"
  type        = string
  default     = "local:iso/ubuntu-24.04-cloudimg-amd64.img"
}

variable "ssh_public_key" {
  description = "注入 ubuntu 用户的公钥（全舰队 vgio）。"
  type        = string
}
