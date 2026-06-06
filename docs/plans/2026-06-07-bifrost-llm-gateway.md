# Bifrost LLM gateway (replaces Cloudflare AI Gateway)

**Date**: 2026-06-07
**Status**: implemented (code) — pending operator steps (ZITADEL client + Vault secret + DNS apply + CF dashboard delete)

## Why

The repo had a Cloudflare AI Gateway (`shared-llm`) intended as the unified LLM
egress. Its own design doc (`docs/superpowers/specs/2026-05-31-cloudflare-ai-gateway-design.md`)
flagged the blocker: CF AI Gateway custom providers need a **Cloudflare-edge-reachable
HTTPS upstream**, but the target models live on **Tailscale `100.x`** machines
(DGX Spark, `100.89.15.120`) that CF's edge cannot reach. So it could never front them.

**Bifrost** (`maximhq/bifrost`, OSS, OpenAI-compatible) runs *inside* the homelab
cluster — whose node is on Tailscale (`100.94.186.7`) — so it reaches `100.x` models
directly. It is exposed publicly through the existing Cloudflare Tunnel → Cilium Gateway.

## What changed

- **Removed** the CF AI Gateway: `cloudflare/terraform/ai-gateway.tf`, its `ai_gateway_*`
  vars, README section + token perms, and the `Account → AI Gateway` line in CONVENTIONS.
  `terraform state rm cloudflare_ai_gateway.shared` was run (state clean). The actual
  `shared-llm` resource must be deleted in the **CF dashboard** (provider delete is broken).
- **Added** Bifrost on homelab, namespace `bifrost`, own ArgoCD Application
  (`argocd/applications/bifrost.yaml` → `k8s/helm/manifests/bifrost.yaml`).
- **Public exposure** at `llm.meirong.dev` (CF tunnel ingress + DNS via Terraform).

## Exposure / auth design

Bifrost serves inference **and** an admin UI/config-API on one port (8080). The OSS
admin plane has **no auth** (SSO/RBAC is enterprise-only). So the single HTTPRoute on
`llm.meirong.dev` splits by path (longest-prefix wins):

| Path | Backend | Auth |
|------|---------|------|
| `/v1`, `/openai`, `/anthropic`, `/genai` | `bifrost:8080` (direct) | Bifrost **virtual keys** (`enforce_auth_on_inference: true`); header `x-bf-vk`/`x-api-key` |
| everything else (`/`, `/api`, `/oauth2/*`) | `oauth2-proxy:4180` → bifrost | **ZITADEL OIDC** (oauth2-proxy reverse-proxy mode) |

Programmatic inference clients can't do interactive OIDC, so they bypass oauth2-proxy
and authenticate with virtual keys; browsers hit the admin UI and must log in via ZITADEL.

## Secrets / ZITADEL client

- OIDC client provisioned by `zitadel/scripts/configure-bifrost-oauth.sh` (idempotent
  **REST**, not Terraform — the zitadel TF provider's gRPC writes lose trailers across
  the CF edge; same reason SMTP uses a REST script).
- Creds (`client-id`, `client-secret`, `cookie-secret`) live in Vault
  `secret/homelab/bifrost-oauth2-proxy` → ESO `ExternalSecret oauth2-proxy-secret` →
  K8s Secret in the `bifrost` namespace.

## Operator runbook (remaining manual steps)

1. `./zitadel/scripts/configure-bifrost-oauth.sh` → copy the printed `vault kv put`.
2. `vault kv put secret/homelab/bifrost-oauth2-proxy client-id=… client-secret=… cookie-secret=…`
3. `git push origin main` (ArgoCD deploys bifrost + oauth2-proxy within ~3 min).
4. `cd cloudflare/terraform && just apply` (creates the `llm` CNAME + tunnel ingress).
5. Delete `shared-llm` in the Cloudflare dashboard (Account → AI → AI Gateway).
6. Log in to `https://llm.meirong.dev/` via ZITADEL, create a virtual key, and add the
   first Tailscale model provider (UI → Providers → custom, `base_url: http://100.x:port/v1`).

## Key prerequisite / risk

**Pod → Tailscale `100.x` egress**: Bifrost pods must reach model machines' tailnet IPs.
Needs Cilium masquerading pod egress to the node's tailnet IP **and** the target machine's
Tailscale ACL allowing the homelab node. Verify when wiring the first provider:
`kubectl -n bifrost exec deploy/bifrost -- wget -qO- http://<tailscale-ip>:<port>/v1/models`.

## Verify (security-critical)

- `https://llm.meirong.dev/` → 302 to `auth.meirong.dev`, then UI after login.
- `curl https://llm.meirong.dev/v1/models` with **no** key → rejected; with `x-bf-vk` → 200.
- `curl -sI https://llm.meirong.dev/api/...` with no cookie → not anonymous (302/403).
