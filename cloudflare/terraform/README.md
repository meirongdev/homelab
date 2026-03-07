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
# Edit terraform.tfvars: set cloudflare_account_id, tunnel_id, and ingress_rules

# 3. Initialize Terraform
just init
```

## Usage

```bash
just plan   # Preview changes
just apply  # Apply changes
```

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

## State Management

Terraform state is stored **locally** (`terraform.tfstate`). This file is gitignored.

> **Future**: The `provider.tf` contains a commented-out S3 backend configuration for Cloudflare R2 (`terraform-backend` bucket, already created). Enable it once the local TLS handshake issue with `*.r2.cloudflarestorage.com` is resolved.

## File Structure

```
cloudflare/terraform/
├── .env                    # API token (gitignored)
├── .env.example            # Template for .env
├── main.tf                 # Tunnel config + DNS records
├── waf.tf                  # WAF rules + zone security settings
├── provider.tf             # Cloudflare provider + backend config
├── variables.tf            # Variable definitions
├── terraform.tfvars        # Actual values (gitignored)
├── terraform.tfvars.example # Template for terraform.tfvars
├── justfile                # just init/plan/apply
└── README.md               # This file
```
