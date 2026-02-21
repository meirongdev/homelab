resource "tailscale_acl" "main" {
  acl = jsonencode({
    tagOwners = {
      "tag:homelab" = []
      "tag:oracle"  = []
    }
    acls = [
      { action = "accept", src = ["tag:homelab", "tag:oracle"], dst = ["*:*"] }
    ]
    autoApprovers = {
      routes = {
        "10.42.0.0/16" = ["tag:homelab"]
        "10.43.0.0/16" = ["tag:homelab"]
        "10.52.0.0/16" = ["tag:oracle"]
        "10.53.0.0/16" = ["tag:oracle"]
      }
    }
  })
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
