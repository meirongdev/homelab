# Cloudflare AI Gateway Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a shared Cloudflare AI Gateway to `cloudflare/terraform/` so homelab services can start using a single account-level AI egress point, without wiring any self-hosted model providers yet.

**Architecture:** Keep AI Gateway in the existing Cloudflare Terraform layer beside Tunnel, DNS, and WAF resources. Upgrade the Cloudflare provider to a version that supports `cloudflare_ai_gateway`, add one gateway resource plus explicit variables, and document that future DGX Spark / Tailnet-backed model endpoints must first be exposed as Cloudflare-reachable HTTPS origins.

**Tech Stack:** Terraform, Cloudflare Terraform Provider, just, Markdown

---

## File structure and responsibilities

- `cloudflare/terraform/provider.tf` — pin the Cloudflare provider to a version that includes `cloudflare_ai_gateway`
- `cloudflare/terraform/.terraform.lock.hcl` — record the upgraded provider selection after `terraform init -upgrade`
- `cloudflare/terraform/variables.tf` — define the AI Gateway variables and safe defaults
- `cloudflare/terraform/ai-gateway.tf` — declare the shared `cloudflare_ai_gateway` resource
- `cloudflare/terraform/terraform.tfvars.example` — show the expected AI Gateway values in the example configuration
- `cloudflare/terraform/README.md` — explain what the gateway is, required token permissions, and why Tailscale `100.x` endpoints are not valid upstreams yet

---

### Task 1: Upgrade the Cloudflare provider to one that supports AI Gateway

**Files:**
- Modify: `cloudflare/terraform/provider.tf`
- Modify: `cloudflare/terraform/.terraform.lock.hcl`
- Test: `cloudflare/terraform/` (`terraform init -upgrade`)

- [ ] **Step 1: Change the provider version constraint**

Replace the `cloudflare` provider block in `cloudflare/terraform/provider.tf` with:

```hcl
terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.19"
    }
  }

  # R2 backend (commented out due to local TLS handshake issues with LibreSSL 3.3.6)
  # To enable: uncomment below and run `just init`
  # backend "s3" {
  #   bucket                      = "terraform-backend"
  #   key                         = "cloudflare.tfstate"
  #   region                      = "auto"
  #   skip_credentials_validation = true
  #   skip_metadata_api_check     = true
  #   skip_region_validation      = true
  #   skip_requesting_account_id  = true
  #   skip_s3_checksum            = true
  #   force_path_style            = true
  # }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
```

- [ ] **Step 2: Refresh the provider lock file**

Run:

```bash
cd /Users/matthew/projects/homelab/cloudflare/terraform
terraform init -upgrade
```

Expected: Terraform downloads `cloudflare/cloudflare` `5.19.x` or newer `5.x` and rewrites `.terraform.lock.hcl`.

- [ ] **Step 3: Verify the lock file now references the upgraded provider**

Run:

```bash
cd /Users/matthew/projects/homelab/cloudflare/terraform
rg 'cloudflare/cloudflare|version = "5\\.' .terraform.lock.hcl -n
```

Expected: `.terraform.lock.hcl` shows `registry.terraform.io/cloudflare/cloudflare` with a version at or above `5.19.0`.

- [ ] **Step 4: Commit the provider upgrade**

Run:

```bash
cd /Users/matthew/projects/homelab
git add cloudflare/terraform/provider.tf cloudflare/terraform/.terraform.lock.hcl
git commit -m "chore: upgrade cloudflare provider for ai gateway"
```

Expected: One commit containing only the provider constraint and lock file refresh.

---

### Task 2: Add the shared AI Gateway Terraform resource and variables

**Files:**
- Create: `cloudflare/terraform/ai-gateway.tf`
- Modify: `cloudflare/terraform/variables.tf`
- Modify: `cloudflare/terraform/terraform.tfvars.example`
- Test: `cloudflare/terraform/` (`terraform fmt`, `terraform validate`)

- [ ] **Step 1: Add AI Gateway variables with safe defaults**

Append these blocks to `cloudflare/terraform/variables.tf` after the existing `ingress_rules` variable:

```hcl
variable "ai_gateway_id" {
  description = "Shared Cloudflare AI Gateway ID"
  type        = string
  default     = "shared-llm"
}

variable "ai_gateway_authentication" {
  description = "Require a Cloudflare token when calling the AI Gateway"
  type        = bool
  default     = true
}

variable "ai_gateway_cache_invalidate_on_update" {
  description = "Invalidate cached responses when the AI Gateway configuration changes"
  type        = bool
  default     = true
}

variable "ai_gateway_cache_ttl" {
  description = "AI Gateway cache TTL in seconds; 0 disables caching"
  type        = number
  default     = 0
}

variable "ai_gateway_collect_logs" {
  description = "Enable AI Gateway request logging"
  type        = bool
  default     = true
}

variable "ai_gateway_rate_limiting_interval" {
  description = "AI Gateway rate limiting interval in seconds; 0 disables rate limiting"
  type        = number
  default     = 0
}

variable "ai_gateway_rate_limiting_limit" {
  description = "AI Gateway rate limit for each interval; 0 disables rate limiting"
  type        = number
  default     = 0
}
```

- [ ] **Step 2: Create the gateway resource**

Create `cloudflare/terraform/ai-gateway.tf` with:

```hcl
resource "cloudflare_ai_gateway" "shared" {
  account_id = var.cloudflare_account_id
  id         = var.ai_gateway_id

  authentication              = var.ai_gateway_authentication
  cache_invalidate_on_update  = var.ai_gateway_cache_invalidate_on_update
  cache_ttl                   = var.ai_gateway_cache_ttl
  collect_logs                = var.ai_gateway_collect_logs
  rate_limiting_interval      = var.ai_gateway_rate_limiting_interval
  rate_limiting_limit         = var.ai_gateway_rate_limiting_limit
}
```

- [ ] **Step 3: Update the example tfvars file**

Add these example values to `cloudflare/terraform/terraform.tfvars.example` after `tunnel_id`:

```hcl
ai_gateway_id                         = "shared-llm"
ai_gateway_authentication             = true
ai_gateway_cache_invalidate_on_update = true
ai_gateway_cache_ttl                  = 0
ai_gateway_collect_logs               = true
ai_gateway_rate_limiting_interval     = 0
ai_gateway_rate_limiting_limit        = 0
```

- [ ] **Step 4: Format the Terraform files**

Run:

```bash
cd /Users/matthew/projects/homelab/cloudflare/terraform
terraform fmt provider.tf variables.tf ai-gateway.tf terraform.tfvars.example
```

Expected: Terraform reformats any spacing/alignment differences and exits successfully.

- [ ] **Step 5: Validate the new resource graph**

Run:

```bash
cd /Users/matthew/projects/homelab/cloudflare/terraform
terraform validate -var="cloudflare_api_token=dummy-token"
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 6: Commit the AI Gateway Terraform resource**

Run:

```bash
cd /Users/matthew/projects/homelab
git add cloudflare/terraform/variables.tf cloudflare/terraform/ai-gateway.tf cloudflare/terraform/terraform.tfvars.example
git commit -m "feat: add cloudflare ai gateway"
```

Expected: One commit containing the new resource and variable wiring.

---

### Task 3: Document AI Gateway usage and the private-upstream constraint

**Files:**
- Modify: `cloudflare/terraform/README.md`
- Test: `cloudflare/terraform/README.md` (content review in diff)

- [ ] **Step 1: Expand the prerequisite permissions**

In the `## Prerequisites` section of `cloudflare/terraform/README.md`, replace the permission list with:

```md
- A Cloudflare API Token with:
  - **Zone** → `DNS` → **Edit**
  - **Zone** → `Zone WAF` → **Edit**
  - **Zone** → `Zone Settings` → **Edit**
  - **Account** → `Cloudflare Tunnel` → **Edit**
  - **Account** → `AI Gateway` → **Read**
  - **Account** → `AI Gateway` → **Edit**
```

- [ ] **Step 2: Add an AI Gateway section**

Insert this section after `## Usage`:

```md
## AI Gateway

This Terraform project also manages a shared Cloudflare AI Gateway named `shared-llm`.

- The gateway is an **account-level Cloudflare resource**, not a Kubernetes workload.
- `homelab` and `oracle-k3s` applications can both call this same gateway.
- This repository only creates the gateway itself for now; it does **not** yet create custom providers for self-hosted models.

### Why no self-hosted model providers yet?

Cloudflare AI Gateway custom providers require a **Cloudflare-reachable HTTPS upstream**.

- A Tailscale `100.x` address is reachable from your tailnet, but not from Cloudflare's edge.
- Before wiring `nv-dgx-spark` or `100.89.15.120` into AI Gateway, expose each model endpoint behind a Cloudflare-reachable HTTPS hostname.
- For DGX Spark, prefer exposing the Bifrost gateway rather than individual `vLLM` ports so AI Gateway only targets one stable upstream.
```

- [ ] **Step 3: Update the file structure section**

Replace the file structure block near the bottom of `cloudflare/terraform/README.md` with:

```md
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

- [ ] **Step 4: Review the README diff for the three required messages**

Run:

```bash
cd /Users/matthew/projects/homelab
git --no-pager diff -- cloudflare/terraform/README.md
```

Expected: The diff clearly says all three of these things:

1. AI Gateway is managed in `cloudflare/terraform/`
2. AI Gateway is not a cluster workload
3. Tailscale `100.x` endpoints are not valid AI Gateway upstreams until they have a Cloudflare-reachable HTTPS hostname

- [ ] **Step 5: Commit the documentation update**

Run:

```bash
cd /Users/matthew/projects/homelab
git add cloudflare/terraform/README.md
git commit -m "docs: document cloudflare ai gateway"
```

Expected: One commit containing only the README changes.

---

### Task 4: Run the end-to-end Terraform checks for the new gateway

**Files:**
- Verify: `cloudflare/terraform/provider.tf`
- Verify: `cloudflare/terraform/.terraform.lock.hcl`
- Verify: `cloudflare/terraform/variables.tf`
- Verify: `cloudflare/terraform/ai-gateway.tf`
- Verify: `cloudflare/terraform/terraform.tfvars.example`
- Verify: `cloudflare/terraform/README.md`
- Test: `cloudflare/terraform/` (`terraform validate`, `just plan`)

- [ ] **Step 1: Reinitialize the working directory with the upgraded provider**

Run:

```bash
cd /Users/matthew/projects/homelab/cloudflare/terraform
terraform init
```

Expected: Terraform reuses the already-upgraded provider and reports `Terraform has been successfully initialized!`

- [ ] **Step 2: Re-run validation against the final file set**

Run:

```bash
cd /Users/matthew/projects/homelab/cloudflare/terraform
terraform validate -var="cloudflare_api_token=dummy-token"
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Run the repository’s standard plan command**

Run:

```bash
cd /Users/matthew/projects/homelab/cloudflare/terraform
just plan
```

Expected: The plan shows one new `cloudflare_ai_gateway.shared` resource and does not show unexpected edits to the existing tunnel, DNS, or WAF resources.

- [ ] **Step 4: Review the final changed files**

Run:

```bash
cd /Users/matthew/projects/homelab
git --no-pager diff --stat
```

Expected: The diff only includes:

- `cloudflare/terraform/provider.tf`
- `cloudflare/terraform/.terraform.lock.hcl`
- `cloudflare/terraform/variables.tf`
- `cloudflare/terraform/ai-gateway.tf`
- `cloudflare/terraform/terraform.tfvars.example`
- `cloudflare/terraform/README.md`

- [ ] **Step 5: Verify the commit history is the expected three-commit sequence**

Run:

```bash
cd /Users/matthew/projects/homelab
git --no-pager log --oneline -n 3
```

Expected: The most recent commits are, in order, `docs: document cloudflare ai gateway`, `feat: add cloudflare ai gateway`, and `chore: upgrade cloudflare provider for ai gateway`.
