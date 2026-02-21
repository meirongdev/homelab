data "cloudflare_zone" "meirong" {
  filter = {
    name = "meirong.dev"
  }
}

# Cloudflare Tunnel Configuration (oracle-k3s)
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "oracle" {
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
          # Default rule (catch-all)
          service = "http_status:404"
        }
      ]
    )
  }
}

# DNS Records for subdomains (oracle-k3s tunnel)
resource "cloudflare_dns_record" "subdomains" {
  for_each = var.ingress_rules

  zone_id = data.cloudflare_zone.meirong.id
  name    = each.key
  content = "${var.tunnel_id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
  ttl     = 1
}
