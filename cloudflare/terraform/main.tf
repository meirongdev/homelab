data "cloudflare_zone" "meirong" {
  filter = {
    name = "meirong.dev"
  }
}

# Cloudflare Tunnel Configuration (homelab)
#
# Single WILDCARD route: everything CNAME'd to this tunnel is forwarded to the cluster's
# Cilium gateway, which host-routes by HTTPRoute (and returns 404 for a host with no
# matching route). external-dns creates each subdomain's CNAME from its HTTPRoute, so adding
# a subdomain is now JUST writing an HTTPRoute — no per-host tunnel entry here (this is what
# removed the last manual step; before 2026-07-20 there were 5 explicit host rules).
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "homelab" {
  account_id = var.cloudflare_account_id
  tunnel_id  = var.tunnel_id

  config = {
    origin_request = {
      no_tls_verify = true
    }

    ingress = [
      {
        hostname = "*.meirong.dev"
        service  = var.gateway_service
      },
      # Catch-all (e.g. apex or a host with no CNAME to this tunnel — shouldn't normally arrive).
      {
        service = "http_status:404"
      },
    ]
  }
}

# DNS records for subdomains that TERRAFORM manages directly.
#
# external-dns (homelab cluster, gateway-httproute source) now owns the DNS for every
# subdomain fronted by an HTTPRoute: argocd/book/grafana/llm/vault were migrated to it on
# 2026-07-20 (ownership TXT pre-seeded to hand over control with zero downtime, then
# `state rm`'d out of here). So this set is empty.
#
# With the wildcard tunnel route above, adding a subdomain is entirely: write an HTTPRoute ->
# external-dns creates its CNAME -> the wildcard forwards it to the gateway. Only put a
# hostname in var.terraform_managed_dns if its DNS must NOT be owned by external-dns.
resource "cloudflare_dns_record" "subdomains" {
  for_each = var.terraform_managed_dns

  zone_id = data.cloudflare_zone.meirong.id
  name    = each.value
  content = "${var.tunnel_id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
  ttl     = 1
}
