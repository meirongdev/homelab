terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }

  # R2 backend (commented out due to local TLS handshake issues with LibreSSL 3.3.6)
  # To enable: uncomment below and run `just init`
  # backend "s3" {
  #   bucket                      = "terraform-backend"
  #   key                         = "cloudflare.tfstate"
  #   region                      = "auto"
  #   skip_credentials_validation = true
  #   skip_metadata_api_check     = true
  #   skip_region_validation      = true
  #   skip_requesting_account_id  = true
  #   skip_s3_checksum            = true
  #   force_path_style            = true
  # }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
