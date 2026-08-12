# storage-106 (Proxmox VE) 的独立 terraform root。
#
# 为什么不并进 ../terraform（pve 那个 root）：terraform plan 要刷新 state 里
# 全部资源，两台 PVE 的 API 混在一个 root 里意味着**任一台**打不通就整个 root
# 不可操作——而本机到两台 PVE 的 :8006 都存在"SSH 22 通、8006 不通"的路径怪象
# （与 ../terraform README 记录的 terraform "no route to host" 是同一件事）。
# 独立 root + justfile 里的 SSH 隧道（见 justfile `_tunnel`），从任何机器都能跑。
#
# 认证用专属 API token（root@pam!terraform，privsep=0），值在 gitignored 的
# terraform.tfvars。重建 token：ssh root@192.168.50.106 \
#   'pveum user token remove root@pam terraform; pveum user token add root@pam terraform --privsep 0'
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.85.1" # 与 ../terraform 同版
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = true # PVE 自签证书

  # ☠️ 这个 ssh 块不是可选项：给 VM 挂 cloud image（disk.file_id 指向 .img）时，
  # provider 必须**登上 PVE 节点**跑磁盘导入——API token 到这一步不够用。
  # 2026-08-13 首次 apply 就是死在这里：
  #   Error: creating custom disk: unable to authenticate user "" over SSH to
  #   "192.168.50.106:22" ... no route to host
  # 两个独立的坑叠在一起：
  #   ① 默认 username 为空、且**不读 ~/.ssh/config**（provider 明说），ssh-agent
  #      当时也没加载任何身份 → 必须显式给 username + private_key；
  #   ② 默认拿 PVE API 报的节点地址（LAN 192.168.50.106）去 dial，而本机到该段有
  #      **两条竞争路由**（en0 直连 + utun5 上 pve 通告的子网路由），Go dialer 撞
  #      EHOSTUNREACH——同一时刻 `nc -vz 192.168.50.106 22` 却是通的。这与
  #      ../terraform README 里那个"terraform no route to host"是同一现象，至今未定性。
  # 故 node.address 走 **Tailscale**（100.64/10 单一路由，无歧义），绕开该竞争。
  ssh {
    agent       = false
    username    = "root"
    private_key = file(pathexpand(var.ssh_private_key_path))

    node {
      name    = var.proxmox_node
      address = var.proxmox_node_ssh_address
    }
  }
}
