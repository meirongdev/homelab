terraform {
  required_providers {
    aiven = {
      source  = "aiven/aiven"
      version = "~> 4.62"
    }
  }

  # state 在 R2 桶 homelab-tfstate，key = 本 root 的仓库相对路径（2026-11-09 迁入）。
  # 凭据与端点经环境变量给，由 scripts/tf-r2.sh 从 Vault 现取：走 just，别敲裸 terraform。
  # → docs/reference/terraform-state.md
  backend "s3" {
    bucket       = "homelab-tfstate"
    key          = "aiven/terraform/terraform.tfstate"
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

# Auth is an Aiven API key. Scope it as narrowly as the console allows (Project,
# otherwise Organization) -- a broader key is more power than this root needs.
#
# ☠️ Plan eligibility is NOT something a billing field can predict, so do not
#    "verify" it by looking for a card on file: the account in use here reports
#    payment_method=card with card_info=null and costs nothing. The free plan is
#    confirmed by the Console's plan picker, not by billing metadata. README.
provider "aiven" {
  api_token = var.aiven_api_token
}
