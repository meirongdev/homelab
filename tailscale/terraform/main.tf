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
      # ClusterMesh VXLAN underlay routes (pod-CIDR subnet routes 10.42/10.52 were
      # removed 2026-07-07: cross-cluster pod traffic rides Cilium ClusterMesh VXLAN):
      #   - oracle→homelab outer packets ride pve's existing 10.10.10.0/24 route;
      #   - homelab→oracle outer packets ride node0's self-advertised 10.0.0.26/32.
      # ⚠️ NEVER approve/advertise 10.10.10.10/32 (k8s-node's own IP): pve — a transit
      # router for that segment — learns it into table 52, which outranks its main
      # table, and hijacks ALL return traffic to the node into the tailnet. This took
      # homelab's entire v4 internet egress down on 2026-07-07. Advertising node0's
      # own /32 is safe because nothing in the tailnet transits traffic to the OCI VCN.
      routes = {
        "10.0.0.26/32" = ["tag:oracle", "meirongdev@gmail.com"] # node0 (oracle VCN IP)
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
