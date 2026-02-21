variable "tailscale_oauth_client_id" {
  description = "Tailscale OAuth Client ID (from Tailscale Admin Console)"
  type        = string
  sensitive   = true
}

variable "tailscale_oauth_client_secret" {
  description = "Tailscale OAuth Client Secret (from Tailscale Admin Console)"
  type        = string
  sensitive   = true
}
