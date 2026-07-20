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

variable "gateway_service" {
  description = "Internal service the tunnel's wildcard route forwards *.meirong.dev to — the oracle-k3s Cilium gateway, which host-routes by HTTPRoute. (Replaced the per-subdomain ingress_rules map on 2026-07-20 when the wildcard route was introduced.)"
  type        = string
  default     = "http://cilium-gateway-oracle-gateway.kube-system.svc:80"
}

variable "terraform_managed_dns" {
  description = "Subdomain CNAMEs that Terraform manages directly (each points at the tunnel, proxied). Empty by default: external-dns (gateway-httproute source, oracle-k3s) owns the DNS for every HTTPRoute-fronted subdomain. Only add a hostname here if its DNS must NOT be owned by external-dns."
  type        = set(string)
  default     = []
}
