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
  description = "Existing Cloudflare Tunnel ID"
  type        = string
}

variable "tunnel_name" {
  description = "Name of the Cloudflare Tunnel"
  type        = string
  default     = "homelab-tunnel"
}

variable "ingress_rules" {
  description = "Map of subdomains to their internal services"
  type = map(object({
    service = string
  }))
  default = {
    "home" = {
      service = "http://traefik.kube-system.svc:80"
    }
    "book" = {
      service = "http://traefik.kube-system.svc:80"
    }
    "grafana" = {
      service = "http://traefik.kube-system.svc:80"
    }
    "vault" = {
      service = "http://traefik.kube-system.svc:80"
    }
  }
}
