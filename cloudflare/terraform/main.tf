data "cloudflare_zone" "meirong" {
  name = "meirong.dev"
}

# Cloudflare Tunnel Configuration
resource "cloudflare_tunnel_config" "homelab" {
  account_id = var.cloudflare_account_id
  tunnel_id  = var.tunnel_id

  config {
    origin_request {
      no_tls_verify = true
    }

    dynamic "ingress_rule" {
      for_each = var.ingress_rules
      content {
        hostname = "${ingress_rule.key}.meirong.dev"
        service  = ingress_rule.value.service
      }
    }
    # Kopia backup server — needs HTTP/2 (h2c) for gRPC, handled separately
    ingress_rule {
      hostname = "backup.meirong.dev"
      service  = "https://kopia.kopia.svc.cluster.local:51515"
      origin_request {
        http2_origin  = true
        no_tls_verify = true
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

# Separate DNS record for backup (kopia has its own ingress_rule above)
resource "cloudflare_record" "backup" {
  zone_id = data.cloudflare_zone.meirong.id
  name    = "backup"
  value   = "${var.tunnel_id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
}
