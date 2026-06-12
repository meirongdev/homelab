resource "tailscale_acl" "main" {
  acl = jsonencode({
    tagOwners = {
      "tag:homelab" = []
      "tag:oracle"  = []
    }
    acls = [
      { action = "accept", src = ["autogroup:member", "tag:homelab", "tag:oracle"], dst = ["*:*"] }
    ]
    autoApprovers = {
      routes = {
        "10.42.0.0/16" = ["tag:homelab"]
        "10.52.0.0/16" = ["tag:oracle"]
      }
    }
  })
}

# Global DNS nameservers for the tailnet. AliDNS (223.5.x) is reachable from both
# mainland China and abroad and resolves global domains, so MagicDNS (100.100.100.100)
# has a working upstream on every node. Fixes the GB10 DGX Spark nodes (in CN) where
# MagicDNS had no upstream and dockerd could not resolve the daocloud/quay registry
# mirrors. 1.1.1.1 / 8.8.8.8 are intentionally NOT used — they are blocked in CN.
#
# ⚠️ ACTIVATION CAVEAT: setting the nameserver list is necessary but NOT sufficient.
# Tailscale only pushes these to clients as their resolver when "Override local DNS"
# is enabled (Admin console → DNS → Global nameservers → toggle "Override local DNS").
# That flag is NOT exposed by this provider or the public v2 API, so it must be toggled
# once by hand in the admin console. Until then `tailscale dns status` on a client shows
# "(no resolvers configured)" and external names won't resolve via 100.100.100.100.
resource "tailscale_dns_nameservers" "global" {
  nameservers = [
    "223.5.5.5",
    "223.6.6.6",
  ]
}

resource "tailscale_tailnet_key" "homelab" {
  reusable      = false
  ephemeral     = false
  preauthorized = true
  expiry        = 7776000 # 90 days
  tags          = ["tag:homelab"]
  description   = "homelab k3s node"
}

resource "tailscale_tailnet_key" "oracle" {
  reusable      = false
  ephemeral     = false
  preauthorized = true
  expiry        = 7776000 # 90 days
  tags          = ["tag:oracle"]
  description   = "oracle k3s node"
}
