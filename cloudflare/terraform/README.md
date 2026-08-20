# Cloudflare Zero Trust Terraform

This module manages Cloudflare Tunnel configurations and DNS records for the homelab using Infrastructure-as-Code. All subdomain routing is defined in code — no manual dashboard changes needed.

## Architecture

```
Internet → Cloudflare DNS (CNAME) → Cloudflare Tunnel → Cilium Gateway API (K8s) → Services
```

All subdomains point to the same Cloudflare Tunnel, which forwards traffic to the in-cluster Cilium-managed Gateway service. The Gateway then routes to the correct service based on the `Host` header (via Gateway API `HTTPRoute`).

## Prerequisites

- Cloudflare account with `meirong.dev` zone
- An existing Cloudflare Tunnel (created via Zero Trust dashboard)
- A Cloudflare API Token with:
  - **Zone** → `DNS` → **Edit**
  - **Zone** → `Zone WAF` → **Edit**
  - **Zone** → `Zone Settings` → **Edit**
  - **Account** → `Cloudflare Tunnel` → **Edit**

## Setup

```bash
# 1. Copy and fill in your credentials
cp .env.example .env
# Edit .env: set CLOUDFLARE_API_TOKEN

# 2. Copy and fill in your IDs
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set cloudflare_account_id and tunnel_id
# (terraform_managed_dns stays empty — external-dns owns subdomain DNS, see below)

# 3. Initialize Terraform
just init
```

## Usage

```bash
just plan   # Preview changes
just apply  # Apply changes
```

> **LLM gateway**: served by **LiteLLM** (`llm.meirong.dev`, homelab) with its own
> authenticated admin UI at `/ui`. Migration: `docs/plans/apps/2026-08-01-litellm-gateway-migration.md`
> (implemented 2026-08-16); current state: `docs/reference/services.md`. The consumers
> (jobs-sg enrichment, Open Notebook, calibre metadata) go through the gateway or talk to the
> DGX vLLM endpoints directly over the tailnet. A Cloudflare AI Gateway is still not an option
> either way: its custom providers need a CF-edge-reachable HTTPS upstream, and the
> models live on Tailscale `100.x` addresses the edge can't see.

## Adding a New Subdomain

**Don't touch this module** — *if the site runs in one of the clusters*. Write an `HTTPRoute`;
that's the whole procedure. (Cluster-**external** sites are the one exception → next section.)

Since 2026-07-20 the tunnel has a single wildcard route (`*.meirong.dev` → Cilium gateway,
see `main.tf`) and **external-dns owns subdomain DNS** (`gateway-httproute` source, one
instance per cluster with distinct `txtOwnerId`). So:

1. Add the `HTTPRoute` (homelab: `k8s/helm/manifests/gateway/`; oracle: `cloud/oracle/manifests/base/`)
2. Push → ArgoCD syncs it → external-dns creates the CNAME → the wildcard route forwards it

The old per-subdomain `ingress_rules` map was removed on 2026-07-20 (5 explicit host rules
plus 5 Terraform-managed CNAMEs handed over to external-dns via pre-seeded ownership TXT).
Editing this module for a new subdomain now means **fighting external-dns over ownership**.

> Escape hatch: `terraform_managed_dns` (default `[]`) exists for a hostname whose DNS must
> *not* be owned by external-dns. Nothing uses it today.
>
> Full mechanism: [docs/reference/networking-ingress.md](../../docs/reference/networking-ingress.md) ·
> decision: [docs/decisions/external-dns-adoption.md](../../docs/decisions/external-dns-adoption.md)

## Adding a Cluster-External Site (GitHub Pages / Cloudflare Pages)

A site hosted outside the clusters has **no `HTTPRoute`**, so neither automation reaches it:
external-dns only reads `gateway-httproute` sources, and the wildcard tunnel route only applies
to hostnames CNAME'd at the tunnel. Its record must be declared here, in
`local.external_origin_dns` (`main.tf`) — one line, then `just apply`.

⚠️ **GitHub Pages needs `proxied = false`** (DNS-only). GitHub signs the custom domain's
Let's Encrypt cert over HTTP-01; orange-cloud + zone-wide *Always Use HTTPS* redirects that
challenge to an HTTPS origin that doesn't have the cert yet — chicken-and-egg. Flip to
`proxied = true` only after the repo's **Settings → Pages** reports the certificate as issued.

⚠️ **DNS is only half of it.** When Pages publishes from a *custom Actions workflow*
(`actions/deploy-pages`), a committed `CNAME` file is **ignored** — the custom domain has to be
set in the repo's Pages settings, or the host 404s with "There isn't a GitHub Pages site here"
even though DNS resolves correctly:

```bash
gh api -X PUT repos/<owner>/<repo>/pages -f cname=<host>.meirong.dev
gh workflow run pages.yml          # REQUIRED — see below
gh api -X PUT repos/<owner>/<repo>/pages -F https_enforced=true   # once cert state == approved
```

⚠️ **The `gh workflow run` is not optional.** Right after the domain is set, the new host keeps
404-ing (and `<org>.github.io/<repo>` starts 301-ing to it) until the site is deployed again —
and the previously built artifact had `baseurl=/<repo>`, so serving it at the new root would
404 every asset. One re-run rebuilds with an empty base path and starts serving. Verify the
*assets*, not just the page: `curl -s https://<host>.meirong.dev/ | grep -o 'href="/[^"]*"'`
should show `/assets/...`, never `/<repo>/assets/...`.

## Managed Resources

| Resource | Notes |
|----------|-------|
| Tunnel config (homelab) | one wildcard ingress `*.meirong.dev` → `var.gateway_service`, plus a `http_status:404` catch-all |
| Zone security settings + WAF | see below — zone-wide, covers **both** tunnels (⚠️ *not* DNS-only hostnames — those bypass the edge entirely) |
| Subdomain CNAMEs (tunnel) | **none** (`terraform_managed_dns = []`) — owned by external-dns. Current service list: [docs/reference/services.md](../../docs/reference/services.md) |
| Cluster-external CNAMEs | `local.external_origin_dns`: `playgrounds` → `meirongdev.github.io` (GitHub Pages, DNS-only, 2026-08-13). ⚠️ The apex `meirong.dev` → `meirongdevblog.pages.dev` (blog, Cloudflare Pages) is **not** in this state — Cloudflare Pages created it. |

## WAF & Security Configuration

Zone-level security settings and WAF rules are defined in `waf.tf`. These are zone-wide — they protect **all** subdomains across both tunnels (homelab + oracle-k3s).

### Zone Security Settings

| Setting | Value | Purpose |
|---------|-------|---------|
| SSL Mode | `full` | Encrypt origin ↔ Cloudflare (tunnels already do this) |
| Min TLS Version | `1.2` | Block TLS 1.0/1.1 (BEAST, POODLE vulnerabilities) |
| Always Use HTTPS | `on` | Auto-redirect HTTP → HTTPS |
| Security Level | `medium` | Challenge suspicious IPs (Cloudflare reputation DB) |
| Browser Integrity Check | `on` | Block requests with abnormal HTTP headers |
| Email Obfuscation | `on` | Hide emails from scrapers |
| Hotlink Protection | `on` | Prevent resource hotlinking |
| Opportunistic Encryption | `on` | TLS for HTTP content when supported |

### Custom WAF Rules (5/5 used)

| # | Action | Description |
|---|--------|-------------|
| 1 | Block | WordPress/PHP/admin scanner paths (`/wp-*`, `/phpmyadmin`, `/cgi-bin`, etc.) |
| 2 | Block | Sensitive files (`.env`, `.git`, `.htaccess`, `/server-status`, etc.) |
| 3 | Block | Known scanner user agents (sqlmap, nikto, nmap, acunetix, etc.) |
| 4 | Managed Challenge | High threat score visitors (score > 14) |
| 5 | Block | Non-standard HTTP methods (TRACE, CONNECT, etc.) |

### Rate Limiting (1/1 used — Free plan allows exactly one rule)

Both patterns share **one** rule (and therefore one counter) because the Free plan caps
rate limiting at a single rule. Adding a second one fails at apply time on quota.

| Endpoint Pattern | Threshold | Block Duration |
|-----------------|-----------|---------------|
| `/login`, `/oauth2`, `/api/login`, `/signin`, `/v1/auth` (any host) | 30 req / 10s per IP+colo | 10s |
| `draw.meirong.dev` **`/socket.io/` only** — Excalidraw 的公开协作中继 | 同上（共用计数器） | 10s |

> ⚠️ 不要把 `draw.meirong.dev` 整站纳入这条规则：Excalidraw 冷加载要拉几十个 JS/字体
> 分片，30 req/10s 会被正常访问打穿（边缘命中缓存也计数，"只统计回源请求"是 Business+）。
> 正常协作大约 4 个请求建立会话，之后是一条长连的 websocket。
> 实测（2026-08-04）：60 并发打 `/socket.io/` → 9 个 429；单次握手正常 200。

> **Pro Plan Upgrade Path**: With Cloudflare Pro ($20/mo), you can enable:
> - **Cloudflare Managed Ruleset** — SQLi, XSS, RCE, LFI protection
> - **OWASP Core Ruleset** — anomaly-based detection
> - **Leaked Credentials Detection** — checks against breached databases
> - Longer rate limit periods (60s) and mitigation timeouts (600s)
> - See commented section in `waf.tf` for implementation.

### API Token Permissions

The API token needs these permissions:
- **Zone** → `DNS` → **Edit**
- **Zone** → `Zone WAF` → **Edit**
- **Zone** → `Zone Settings` → **Edit**
- **Account** → `Cloudflare Tunnel` → **Edit**

## State Management

Terraform state is stored **locally** (`terraform.tfstate`). This file is gitignored.

> **Future**: The `provider.tf` contains a commented-out S3 backend configuration for Cloudflare R2 (`terraform-backend` bucket, already created). Enable it once the local TLS handshake issue with `*.r2.cloudflarestorage.com` is resolved.

## File Structure

```
cloudflare/terraform/
├── .env                     # API token (gitignored)
├── .env.example             # Template for .env
├── main.tf                  # Tunnel config + DNS records
├── waf.tf                   # WAF rules + zone security settings
├── provider.tf              # Cloudflare provider + backend config
├── variables.tf             # Variable definitions
├── terraform.tfvars         # Actual values (gitignored)
├── terraform.tfvars.example # Template for terraform.tfvars
├── justfile                 # just init/plan/apply
└── README.md                # This file
```
