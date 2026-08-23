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

# ⚠️ 第三类主机名：**Workers 自定义域名** —— 不在上面那个 map 里，也不该加进去。
#
# `stack.meirong.dev`（home-stack，https://github.com/meirongdev/home-stack，
# Cloudflare Workers 上的 wasm SSR 站）2026-08-23 上线。它的 DNS 记录
# （`AAAA 100::`，橙云）是 `cloudflare_workers_custom_domain` 让 Cloudflare **自己建**的，
# 声明在 **home-stack 仓库**的 `cloudflare/terraform`，不在本仓库的 state 里。
#
# ☠️ **两件事都别做**：
#   1. 不要在这里再声明一份 —— Workers 自定义域名不能建在已存在 CNAME 的主机名上，
#      两边各写一份必然打架（谁先 apply 谁赢，另一边永久报错）。
#   2. 不要因为「它不在代码里」就删掉那条记录 —— 那等于把站点的域名解析摘掉，
#      而本仓库里没有任何线索指向原因。自动化不会动它（两个 external-dns 都是
#      upsert-only，terraform 也不 prune 不在自己 state 里的记录），唯一的风险是人。
#
# 归属与机制：docs/reference/networking-ingress.md 的「不走这条链的 meirong.dev 主机名」。
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
