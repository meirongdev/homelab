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
  - **Account** → `AI Gateway` → **Read**
  - **Account** → `AI Gateway` → **Edit**

## Setup

```bash
# 1. Copy and fill in your credentials
cp .env.example .env
# Edit .env: set CLOUDFLARE_API_TOKEN

# 2. Copy and fill in your IDs
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set cloudflare_account_id, tunnel_id, and ingress_rules

# 3. Initialize Terraform
just init
```

## Usage

```bash
just plan   # Preview changes
just apply  # Apply changes
```

## AI Gateway

This Terraform project also manages a shared Cloudflare AI Gateway named `shared-llm`.

- The gateway is an **account-level Cloudflare resource**, not a Kubernetes workload.
- `homelab` and `oracle-k3s` applications can both call this same gateway.
- This repository only creates the gateway itself for now; it does **not** yet create custom providers for self-hosted models.

### Lifecycle Caveat: Manual Delete Required

⚠️ The current pinned Cloudflare provider (v5.19.1) supports AI Gateway **create/update**, but has broken delete semantics. Removing `cloudflare_ai_gateway.shared` from configuration may leave stale state instead of cleanly destroying the resource.

**If you need to remove the gateway:**
1. Delete it manually via the Cloudflare dashboard (Account Home → AI → AI Gateway → Delete `shared-llm`)
2. Remove it from Terraform state: `terraform state rm cloudflare_ai_gateway.shared`
3. Then remove the resource block from `ai-gateway.tf`

This is a known upstream provider issue. Do not rely on normal `terraform destroy` for this resource.

### Why no self-hosted model providers yet?

Cloudflare AI Gateway custom providers require a **Cloudflare-reachable HTTPS upstream**.

- A Tailscale `100.x` address is reachable from your tailnet, but not from Cloudflare's edge.
- Before wiring `nv-dgx-spark` or `100.89.15.120` into AI Gateway, expose each model endpoint behind a Cloudflare-reachable HTTPS hostname.
- For DGX Spark, prefer exposing the Bifrost gateway rather than individual `vLLM` ports so AI Gateway only targets one stable upstream.

## Adding a New Subdomain

Edit `terraform.tfvars` and add an entry to `ingress_rules`:

```hcl
ingress_rules = {
  "home"     = { service = "http://cilium-gateway-homelab-gateway.kube-system.svc:80" }
  "book"     = { service = "http://cilium-gateway-homelab-gateway.kube-system.svc:80" }
  "grafana"  = { service = "http://cilium-gateway-homelab-gateway.kube-system.svc:80" }
  "vault"    = { service = "http://cilium-gateway-homelab-gateway.kube-system.svc:80" }
  "mynewapp" = { service = "http://cilium-gateway-homelab-gateway.kube-system.svc:80" }  # <- add here
}
```

Then run `just apply`. Terraform will automatically:
1. Create a CNAME DNS record pointing to the Cloudflare Tunnel.
2. Update the Tunnel ingress rules to route the hostname to the Cilium Gateway service.

> **Note**: After adding a subdomain here, you also need to add a corresponding `HTTPRoute` in `k8s/helm/manifests/gateway.yaml` so Cilium Gateway API knows where to forward the traffic inside the cluster.

## Managed Resources

| Subdomain | Service |
|-----------|---------|
| `home.meirong.dev` | Homepage dashboard |
| `book.meirong.dev` | Calibre-Web |
| `grafana.meirong.dev` | Grafana |
| `vault.meirong.dev` | HashiCorp Vault UI |

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

### Rate Limiting (1 rule)

| Endpoint Pattern | Threshold | Block Duration |
|-----------------|-----------|---------------|
| `/login`, `/oauth2`, `/signin`, `/v1/auth` | 10 req / 10s per IP | 10s |

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
- **Account** → `AI Gateway` → **Read**
- **Account** → `AI Gateway` → **Edit**

## State Management

Terraform state is stored **locally** (`terraform.tfstate`). This file is gitignored.

> **Future**: The `provider.tf` contains a commented-out S3 backend configuration for Cloudflare R2 (`terraform-backend` bucket, already created). Enable it once the local TLS handshake issue with `*.r2.cloudflarestorage.com` is resolved.

## File Structure

```
cloudflare/terraform/
├── .env                     # API token (gitignored)
├── .env.example             # Template for .env
├── ai-gateway.tf            # Shared Cloudflare AI Gateway
├── main.tf                  # Tunnel config + DNS records
├── waf.tf                   # WAF rules + zone security settings
├── provider.tf              # Cloudflare provider + backend config
├── variables.tf             # Variable definitions
├── terraform.tfvars         # Actual values (gitignored)
├── terraform.tfvars.example # Template for terraform.tfvars
├── justfile                 # just init/plan/apply
└── README.md                # This file
```
