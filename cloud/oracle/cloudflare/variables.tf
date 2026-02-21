variable "cloudflare_api_token" {
  description = "Cloudflare API Token"
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare Account ID"
  type        = string
}

variable "tunnel_id" {
  description = "Cloudflare Tunnel ID for oracle-k3s"
  type        = string
}

variable "ingress_rules" {
  description = "Map of subdomains to their internal services (oracle-k3s tunnel)"
  type = map(object({
    service = string
  }))
  default = {
    "rss" = {
      service = "http://traefik.kube-system.svc:80"
    }
  }
}
