# Cloudflare Zero Trust Terraform

This module manages Cloudflare Tunnel configurations and DNS records for the homelab using Infrastructure-as-Code. All subdomain routing is defined in code — no manual dashboard changes needed.

## Architecture

```
Internet → Cloudflare DNS (CNAME) → Cloudflare Tunnel → Traefik (K8s) → Services
```

All subdomains point to the same Cloudflare Tunnel, which forwards traffic to the in-cluster Traefik ingress controller. Traefik then routes to the correct service based on the `Host` header (via Gateway API `HTTPRoute`).

## Prerequisites

- Cloudflare account with `meirong.dev` zone
- An existing Cloudflare Tunnel (created via Zero Trust dashboard)
- A Cloudflare API Token with:
  - **Zone** → `DNS` → **Edit**
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
  "home"    = { service = "http://traefik.kube-system.svc:80" }
  "book"    = { service = "http://traefik.kube-system.svc:80" }
  "grafana" = { service = "http://traefik.kube-system.svc:80" }
  "vault"   = { service = "http://traefik.kube-system.svc:80" }
  "mynewapp" = { service = "http://traefik.kube-system.svc:80" }  # ← add here
}
```

Then run `just apply`. Terraform will automatically:
1. Create a CNAME DNS record pointing to the Cloudflare Tunnel.
2. Update the Tunnel ingress rules to route the hostname to Traefik.

> **Note**: After adding a subdomain here, you also need to add a corresponding `HTTPRoute` in `k8s/helm/manifests/gateway.yaml` so Traefik knows where to forward the traffic inside the cluster.

## Managed Resources

| Subdomain | Service |
|-----------|---------|
| `home.meirong.dev` | Homepage dashboard |
| `book.meirong.dev` | Calibre-Web |
| `grafana.meirong.dev` | Grafana |
| `vault.meirong.dev` | HashiCorp Vault UI |

## State Management

Terraform state is stored **locally** (`terraform.tfstate`). This file is gitignored.

> **Future**: The `provider.tf` contains a commented-out S3 backend configuration for Cloudflare R2 (`terraform-backend` bucket, already created). Enable it once the local TLS handshake issue with `*.r2.cloudflarestorage.com` is resolved.

## File Structure

```
cloudflare/terraform/
├── .env                    # API token (gitignored)
├── .env.example            # Template for .env
├── main.tf                 # Tunnel config + DNS records
├── provider.tf             # Cloudflare provider + backend config
├── variables.tf            # Variable definitions
├── terraform.tfvars        # Actual values (gitignored)
├── terraform.tfvars.example # Template for terraform.tfvars
├── justfile                # just init/plan/apply
└── README.md               # This file
```
