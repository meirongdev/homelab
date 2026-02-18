data "cloudflare_zone" "meirong" {
  name = "meirong.dev"
}

# Cloudflare Tunnel Configuration
resource "cloudflare_tunnel_config" "homelab" {
  account_id = var.cloudflare_account_id
  tunnel_id  = var.tunnel_id

  config {
    dynamic "ingress_rule" {
      for_each = var.ingress_rules
      content {
        hostname = "${ingress_rule.key}.meirong.dev"
        service  = ingress_rule.value.service
      }
    }
    # Default rule (catch-all)
    ingress_rule {
      service = "http_status:404"
    }
  }
}

# DNS Records for subdomains
resource "cloudflare_record" "subdomains" {
  for_each = var.ingress_rules

  zone_id = data.cloudflare_zone.meirong.id
  name    = each.key
  value   = "${var.tunnel_id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
}
