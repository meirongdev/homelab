output "homelab_authkey" {
  description = "Pre-auth key for homelab K3s node — pass to: just setup-tailscale <key>"
  value       = tailscale_tailnet_key.homelab.key
  sensitive   = true
}

output "homelab_worker_authkey" {
  description = "Pre-auth key for the storage-106 k3s worker — pass to: just setup-tailscale-worker <key>"
  value       = tailscale_tailnet_key.homelab_worker.key
  sensitive   = true
}

output "oracle_authkey" {
  description = "Pre-auth key for Oracle K3s node — pass to: just setup-tailscale <key>"
  value       = tailscale_tailnet_key.oracle.key
  sensitive   = true
}
