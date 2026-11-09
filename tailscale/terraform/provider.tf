terraform {
  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.17"
    }
  }

  # state 在 R2 桶 homelab-tfstate，key = 本 root 的仓库相对路径（2026-11-09 迁入）。
  # 凭据与端点经环境变量给，由 scripts/tf-r2.sh 从 Vault 现取：走 just，别敲裸 terraform。
  # → docs/reference/terraform-state.md
  backend "s3" {
    bucket       = "homelab-tfstate"
    key          = "tailscale/terraform/terraform.tfstate"
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

provider "tailscale" {
  oauth_client_id     = var.tailscale_oauth_client_id
  oauth_client_secret = var.tailscale_oauth_client_secret
}
