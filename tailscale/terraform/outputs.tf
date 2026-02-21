output "homelab_authkey" {
  description = "Pre-auth key for homelab K3s node — pass to: just setup-tailscale <key>"
  value       = tailscale_tailnet_key.homelab.key
  sensitive   = true
}

output "oracle_authkey" {
  description = "Pre-auth key for Oracle K3s node — pass to: just setup-tailscale <key>"
  value       = tailscale_tailnet_key.oracle.key
  sensitive   = true
}
