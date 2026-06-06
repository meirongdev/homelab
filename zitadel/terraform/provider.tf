terraform {
  required_providers {
    zitadel = {
      source  = "zitadel/zitadel"
      version = "~> 2.12"
    }
  }
}

# Connects to the running instance over the public Cloudflare Tunnel endpoint
# (gRPC/connect on 443, same path the Console uses). Auth is a Personal Access
# Token of a service user holding IAM_OWNER — see README for the one-time bootstrap.
provider "zitadel" {
  domain       = var.zitadel_domain
  port         = "443"
  insecure     = false
  access_token = var.zitadel_token
}
