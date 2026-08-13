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

# CNAMEs for sites hosted OUTSIDE the clusters (GitHub Pages / Cloudflare Pages / ...).
#
# These are the one exception to the README's "don't touch this module to add a subdomain":
# a cluster-external site has no HTTPRoute, so NEITHER automation covers it — external-dns
# only reads `gateway-httproute` sources, and the wildcard tunnel route only applies to
# hostnames whose CNAME points at the tunnel. So the record has to live here, in code.
#
# ⚠️ Do NOT put these in var.terraform_managed_dns — its content is hardcoded to the tunnel.
# ⚠️ GitHub Pages needs proxied = false (DNS-only): GitHub provisions the custom domain's
# Let's Encrypt cert over HTTP-01, and orange-cloud + "Always Use HTTPS" turns that into a
# chicken-and-egg (the challenge gets redirected to an HTTPS origin that has no cert yet).
# Flip a record to proxied = true only after the repo's Settings -> Pages shows the
# certificate as issued.
locals {
  external_origin_dns = {
    # meirongdev/playgrounds — 各语言官方在线 Playground 导航（Jekyll, deployed by Actions).
    # Project page under the meirongdev org => CNAME target is the ORG's pages host
    # (meirongdev.github.io), not <org>.github.io/<repo>; the repo's committed CNAME file
    # is what tells Pages which host to serve.
    "playgrounds.meirong.dev" = { target = "meirongdev.github.io", proxied = false }
  }
}

resource "cloudflare_dns_record" "external_origins" {
  for_each = local.external_origin_dns

  zone_id = data.cloudflare_zone.meirong.id
  name    = each.key
  content = each.value.target
  type    = "CNAME"
  proxied = each.value.proxied
  ttl     = each.value.proxied ? 1 : 300
  comment = "external origin — managed by cloudflare/terraform (not external-dns)"
}
