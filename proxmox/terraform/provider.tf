# pve（Ryzen 5600H 笔记本）上的 terraform root。与 ../terraform-storage（106）刻意分离：
# 两台 PVE 的 API 混在一个 root 里，任一台打不通就整个 root 不可操作（理由全文见那边的
# provider.tf 注释）。两个 root 的写法尽量同构，改一边记得看另一边。
#
# 认证：目前仍是 root@pam **密码**（gitignored 的 terraform.tfvars）。106 root 用的是专属 API token，
# 这边也该换：token 可单独吊销、不随改密码失效。迁移是三步手工动作（涉及新建凭据，刻意不交给自动化）：
#   1. ssh -i ~/.ssh/vgio root@192.168.50.4 'pveum user token add root@pam terraform --privsep 0'
#   2. tfvars 里加 proxmox_api_token = "root@pam!terraform=<上一步的 value>"，删掉 proxmox_username/password
#   3. 本文件把 username/password 两行换成 api_token = var.proxmox_api_token，variables.tf 同步换变量
# （pve 上另有更早建的 terraformToken / packerToken 两个 token，值已不可查，本 root 不用它们。）
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.85.1" # 与 ../terraform-storage 同版
    }
  }

  # state 在 R2 桶 homelab-tfstate，key = 本 root 的仓库相对路径（2026-11-09 迁入）。
  # 凭据与端点经环境变量给，由 scripts/tf-r2.sh 从 Vault 现取：走 just，别敲裸 terraform。
  # → docs/reference/terraform-state.md
  backend "s3" {
    bucket       = "homelab-tfstate"
    key          = "proxmox/terraform/terraform.tfstate"
    region       = "auto"
    use_lockfile = true

    # R2 不是真 S3：这几个 AWS 专属的校验步骤必须关。
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}

provider "proxmox" {
  endpoint = var.proxmox_endpoint
  username = var.proxmox_username
  password = var.proxmox_password
  insecure = true # PVE 自签证书

  # 给 VM 挂 cloud image（disk.file_id 指向 .img）时，provider 必须登上 PVE 节点跑磁盘导入，
  # API 凭据到这一步不够用。现网 VM 早已建好，日常 plan/apply 不会走到这里，但重建时会；
  # 没有这个块，重建会死在 "unable to authenticate user \"\" over SSH"（106 root 2026-08-13 踩过）。
  # 两个坑（provider 不读 ~/.ssh/config、LAN 地址在本机撞竞争路由）的取证见 ../terraform-storage/provider.tf。
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
