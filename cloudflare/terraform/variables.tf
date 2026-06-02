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
  description = "Existing Cloudflare Tunnel ID (homelab)"
  type        = string
}

variable "tunnel_name" {
  description = "Name of the Cloudflare Tunnel"
  type        = string
  default     = "homelab-tunnel"
}

variable "ingress_rules" {
  description = "Map of subdomains to their internal services (homelab tunnel)"
  type = map(object({
    service = string
  }))
  default = {
    "home" = {
      service = "http://cilium-gateway-homelab-gateway.kube-system.svc:80"
    }
    "book" = {
      service = "http://cilium-gateway-homelab-gateway.kube-system.svc:80"
    }
    "grafana" = {
      service = "http://cilium-gateway-homelab-gateway.kube-system.svc:80"
    }
    "vault" = {
      service = "http://cilium-gateway-homelab-gateway.kube-system.svc:80"
    }
  }
}

variable "ai_gateway_id" {
  description = "Shared Cloudflare AI Gateway ID"
  type        = string
  default     = "shared-llm"
}

variable "ai_gateway_authentication" {
  description = "Require a Cloudflare token when calling the AI Gateway"
  type        = bool
  default     = true
}

variable "ai_gateway_cache_invalidate_on_update" {
  description = "Invalidate cached responses when the AI Gateway configuration changes"
  type        = bool
  default     = true
}

variable "ai_gateway_cache_ttl" {
  description = "AI Gateway cache TTL in seconds; 0 disables caching"
  type        = number
  default     = 0
}

variable "ai_gateway_collect_logs" {
  description = "Enable AI Gateway request logging"
  type        = bool
  default     = true
}

variable "ai_gateway_rate_limiting_interval" {
  description = "AI Gateway rate limiting interval in seconds; 0 disables rate limiting"
  type        = number
  default     = 0
}

variable "ai_gateway_rate_limiting_limit" {
  description = "AI Gateway rate limit for each interval; 0 disables rate limiting"
  type        = number
  default     = 0
}
