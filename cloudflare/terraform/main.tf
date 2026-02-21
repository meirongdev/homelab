data "cloudflare_zone" "meirong" {
  filter = {
    name = "meirong.dev"
  }
}

# Cloudflare Tunnel Configuration
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "homelab" {
  account_id = var.cloudflare_account_id
  tunnel_id  = var.tunnel_id

  config = {
    origin_request = {
      no_tls_verify = true
    }

    ingress = concat(
      [for k, v in var.ingress_rules : {
        hostname = "${k}.meirong.dev"
        service  = v.service
      }],
      [
        {
          # Kopia backup server — needs HTTP/2 (h2c) for gRPC, handled separately
          hostname = "backup.meirong.dev"
          service  = "https://kopia.kopia.svc.cluster.local:51515"
          origin_request = {
            http2_origin  = true
            no_tls_verify = true
          }
        },
        {
          # Default rule (catch-all)
          service = "http_status:404"
        }
      ]
    )
  }
}

# DNS Records for subdomains
resource "cloudflare_dns_record" "subdomains" {
  for_each = var.ingress_rules

  zone_id = data.cloudflare_zone.meirong.id
  name    = each.key
  content = "${var.tunnel_id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
  ttl     = 1
}

# Separate DNS record for backup (kopia has its own ingress_rule above)
resource "cloudflare_dns_record" "backup" {
  zone_id = data.cloudflare_zone.meirong.id
  name    = "backup"
  content = "${var.tunnel_id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
  ttl     = 1
}
