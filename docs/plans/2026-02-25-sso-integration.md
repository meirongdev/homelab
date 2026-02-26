# SSO Integration Plan — ZITADEL + oauth2-proxy + Traefik ForwardAuth

**Date:** 2026-02-25  
**Status:** In Progress  
**Author:** Matthew  

---

## 1. Background & Goal

All user-facing services are now split across two clusters:

| Cluster | Services |
|---------|----------|
| **homelab** (k3s-homelab) | Calibre-Web, Grafana, ArgoCD, Vault, Kopia |
| **oracle-k3s** | IT-Tools, Stirling-PDF, Squoosh, Uptime Kuma, Miniflux, Homepage |

Currently none of these services share authentication — each has its own login (or none at all). The goal is to add Single Sign-On (SSO) so one identity (ZITADEL account) grants access to all protected services.

---

## 2. Architecture

```
Internet → Cloudflare Tunnel → Traefik (oracle-k3s)
                                      │
                           ┌──────────┴──────────┐
                           │  Middleware:          │
                           │  sso-forwardauth     │──→ oauth2-proxy (oracle-k3s)
                           │  (per HTTPRoute)     │       │
                           └──────────┬──────────┘       │  OIDC
                                      │               ZITADEL (homelab)
                                 Backend Service     via Tailscale
```

**Components:**

| Component | Cluster | Namespace | Role |
|-----------|---------|-----------|------|
| **ZITADEL** | homelab (Phase 2) | `zitadel` | OIDC Identity Provider |
| **oauth2-proxy** | oracle-k3s | `auth-system` | ForwardAuth middleware (stateless) |
| **Traefik Middleware** | oracle-k3s | `kube-system` | Intercept requests, call oauth2-proxy |

**Phase 1 (this document):** Deploy oauth2-proxy on oracle-k3s. Use a temporary upstream OIDC provider (GitHub OAuth2) for immediate testing, then swap to ZITADEL in Phase 2.

**Phase 2:** Deploy ZITADEL on homelab, update oauth2-proxy to point to ZITADEL via Tailscale (`http://100.107.254.112`). Add native OIDC for Grafana, ArgoCD, Vault, Miniflux.

---

## 3. Per-Service SSO Analysis (Oracle K3s Cluster)

### 3.1 IT-Tools (`tool.meirong.dev`)

- **Current auth:** None — publicly accessible, no login
- **Cluster:** oracle-k3s (`personal-services` namespace)
- **SSO approach:** ✅ **Traefik ForwardAuth middleware**
- **Rationale:** Stateless tool collection with no built-in auth. ForwardAuth adds access control at the Traefik layer without any changes to the deployment.
- **Risk:** Low
- **Implementation:** Add `ExtensionRef` filter referencing the `sso-forwardauth` Middleware to the `it-tools` HTTPRoute.
- **User experience:** Visit `tool.meirong.dev` → redirect to OIDC login if no session → access granted after login.

### 3.2 Stirling-PDF (`pdf.meirong.dev`)

- **Current auth:** Built-in username/password login (SECURITY_ENABLE_LOGIN=true, credentials from Vault)
- **Cluster:** oracle-k3s (`personal-services` namespace)
- **SSO approach:** ✅ **Traefik ForwardAuth middleware** (replace built-in login)
- **Rationale:** Stirling-PDF's own login is redundant once ForwardAuth is in place. Disabling `SECURITY_ENABLE_LOGIN` removes friction.
- **Risk:** Low — existing PVC/configs unaffected
- **Implementation:**
  1. Set `SECURITY_ENABLE_LOGIN=false` in Deployment env vars
  2. Remove `SECURITY_INITIALLOGIN_*` env vars (no longer needed)
  3. Remove the `stirling-pdf-auth` ExternalSecret (Vault path `oracle-k3s/stirling-pdf`)
  4. Add ForwardAuth ExtensionRef filter to `stirling-pdf` HTTPRoute
- **Note:** The `DOCKER_ENABLE_SECURITY=true` env var must remain (controls whether the security module compiles in), but `SECURITY_ENABLE_LOGIN=false` disables the login gate itself.
- **User experience:** Visit `pdf.meirong.dev` → OIDC login → Stirling-PDF loads directly (no second login).

### 3.3 Squoosh (`squoosh.meirong.dev`)

- **Current auth:** None — publicly accessible
- **Cluster:** oracle-k3s (`personal-services` namespace)
- **SSO approach:** ✅ **Traefik ForwardAuth middleware**
- **Rationale:** Static image compression tool, no built-in auth. ForwardAuth is the only viable option.
- **Risk:** Low
- **Implementation:** Add ForwardAuth ExtensionRef filter to `squoosh` HTTPRoute.
- **User experience:** Visit `squoosh.meirong.dev` → OIDC login → tool accessible.

### 3.4 Uptime Kuma (`status.meirong.dev`)

- **Current auth:** Built-in admin password (from Vault via ESO)
- **Cluster:** oracle-k3s (`personal-services` namespace)
- **SSO approach:** ❌ **Skip SSO — intentionally excluded**
- **Rationale:** Uptime Kuma serves a **public status page** as its primary function. Requiring OIDC login would prevent external users (e.g., when checking if the site is down) from seeing status. The admin panel is already password-protected.
- **Implementation:** No changes. Remains publicly accessible.
- **Future consideration:** If a separate admin-only subdomain is desired, a second HTTPRoute for `/dashboard*` with ForwardAuth could be added.

### 3.5 Homepage (`home.meirong.dev`)

- **Current auth:** None — publicly accessible dashboard
- **Cluster:** oracle-k3s (`homepage` namespace)
- **SSO approach:** ✅ **Traefik ForwardAuth middleware**
- **Rationale:** Homepage displays cluster service status and bookmarks. Contains internal service URLs that should not be public-facing.
- **Risk:** Low — stateless, no session state
- **Implementation:** Add ForwardAuth ExtensionRef filter to `homepage` HTTPRoute in `base/gateway.yaml`.
- **User experience:** Visit `home.meirong.dev` → OIDC login → dashboard accessible.

### 3.6 Miniflux (`rss.meirong.dev`)

- **Current auth:** Built-in username/password
- **Cluster:** oracle-k3s (`rss-system` namespace)
- **SSO approach:** ✅ **Native OAuth2 / OIDC** (Phase 2 — after ZITADEL deployed)
- **Rationale:** Miniflux has native OAuth2/OIDC support via `OAUTH2_*` environment variables. Direct integration gives better UX (no double-login, token refresh works).
- **Phase 1:** Keep existing built-in login.
- **Phase 2 implementation:**
  - Create OIDC client in ZITADEL
  - Add `OAUTH2_PROVIDER=oidc`, `OAUTH2_OIDC_DISCOVERY_URL`, `OAUTH2_CLIENT_ID/SECRET`, `OAUTH2_REDIRECT_URL`, `OAUTH2_USER_CREATION=1` env vars
  - Store credentials in Vault at `secret/oracle-k3s/miniflux-oidc`

---

## 4. Per-Service SSO Analysis (Homelab Cluster)

### 4.1 Calibre-Web (`book.meirong.dev`)

- **Cluster:** homelab
- **Current auth:** Built-in username/password
- **SSO approach:** ✅ **Traefik ForwardAuth middleware** (Phase 2)
- **Note:** Calibre-Web supports `REMOTE_USER` header-based auth. With oauth2-proxy forwarding `X-Forwarded-User`, Calibre-Web can auto-login the user. Phase 2.

### 4.2 Grafana (`grafana.meirong.dev`)

- **Cluster:** homelab
- **SSO approach:** ✅ **Native `auth.generic_oauth`** (Phase 2)
- **Config:** Add `auth.generic_oauth` block to `k8s/helm/values/kube-prometheus-stack.yaml`

### 4.3 ArgoCD (`argocd.meirong.dev`)

- **Cluster:** homelab
- **SSO approach:** ✅ **Native Dex/OIDC** (Phase 2)
- **Config:** Update `argocd/install/argocd-cm-patch.yaml` with `oidc.config`

### 4.4 Vault (`vault.meirong.dev`)

- **Cluster:** homelab
- **SSO approach:** ✅ **Native OIDC auth method** (Phase 2)
- **Config:** `vault auth enable oidc` + role configuration

### 4.5 Kopia (`NodePort 31515`)

- **SSO approach:** ❌ **Skip** — LAN-only NodePort, not Cloudflare-exposed. Internal access only.

---

## 5. Implementation Plan

### Phase 1: oracle-k3s ForwardAuth (This PR)

#### 5.1 Deploy oauth2-proxy on oracle-k3s

**New file:** `cloud/oracle/manifests/auth-system/namespace.yaml`  
**New file:** `cloud/oracle/manifests/auth-system/oauth2-proxy.yaml`  
**New file:** `cloud/oracle/manifests/auth-system/external-secret.yaml`

oauth2-proxy is configured with:
- OIDC provider: GitHub OAuth2 (temporary for Phase 1 validation; replaced by ZITADEL in Phase 2)
- Cookie domain: `.meirong.dev` (so one login covers all subdomains)
- Upstream: `static://202` (oauth2-proxy acts purely as auth gate, not proxy)
- Email allowlist: your personal GitHub email

**Vault secrets required:**
```bash
# Store in homelab Vault (oracle-k3s reads via Tailscale)
vault kv put secret/oracle-k3s/oauth2-proxy \
  client-id=<github_oauth_app_client_id> \
  client-secret=<github_oauth_app_client_secret> \
  cookie-secret=$(python3 -c "import secrets,base64; print(base64.b64encode(secrets.token_bytes(32)).decode())")
```

#### 5.2 Add Traefik Middleware

**Modified file:** `cloud/oracle/manifests/base/traefik-config.yaml`

Add a `Middleware` resource in `kube-system`:
```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: sso-forwardauth
  namespace: kube-system
spec:
  forwardAuth:
    address: http://oauth2-proxy.auth-system.svc.cluster.local:4180/oauth2/auth
    trustForwardHeader: true
    authResponseHeaders:
      - X-Auth-Request-User
      - X-Auth-Request-Email
      - X-Auth-Request-Groups
      - Authorization
```

#### 5.3 Apply ForwardAuth to HTTPRoutes

**Modified file:** `cloud/oracle/manifests/base/gateway.yaml`
**Modified file:** `cloud/oracle/manifests/personal-services/it-tools.yaml`
**Modified file:** `cloud/oracle/manifests/personal-services/squoosh.yaml`

**Modified file:** `cloud/oracle/manifests/personal-services/stirling-pdf.yaml`
- Remove ExternalSecret for stirling-pdf-auth
- Set `SECURITY_ENABLE_LOGIN=false`

#### 5.4 Add oauth2-proxy callback route

oauth2-proxy needs its own HTTPRoute for the OAuth2 callback:
- Hostname: `oauth.meirong.dev` (or reuse a service subdomain)
- Routes `/oauth2/*` to oauth2-proxy service

Add `oauth` subdomain to `cloud/oracle/cloudflare/terraform.tfvars`.

#### 5.5 Verification checklist

- [ ] oauth2-proxy pod is `Running` in `auth-system` namespace
- [ ] Middleware resource created successfully
- [ ] Visit `tool.meirong.dev` → redirected to GitHub OAuth login
- [ ] After GitHub login → IT-Tools accessible
- [ ] Session cookie persists across `tool.meirong.dev`, `squoosh.meirong.dev`, `pdf.meirong.dev`, `home.meirong.dev`
- [ ] `status.meirong.dev` remains accessible without login
- [ ] `rss.meirong.dev` still uses built-in login (unchanged)

### Phase 2: ZITADEL + Homelab SSO (Future)

1. Deploy ZITADEL on homelab (`zitadel` namespace)
2. Add `auth.meirong.dev` DNS record
3. Create OIDC clients for: oauth2-proxy, Grafana, ArgoCD, Vault, Miniflux
4. Update oauth2-proxy on oracle-k3s to use ZITADEL OIDC discovery URL
5. Configure native OIDC for Grafana, ArgoCD, Vault
6. Configure OAuth2 for Miniflux
7. Deploy oauth2-proxy on homelab for Calibre-Web

---

## 6. Vault Secrets Summary

| Vault Path | Keys | Used By |
|------------|------|---------|
| `secret/oracle-k3s/oauth2-proxy` | `client-id`, `client-secret`, `cookie-secret` | oauth2-proxy (Phase 1) |
| `secret/homelab/zitadel` | `master-key`, `db-password` | ZITADEL (Phase 2) |
| `secret/homelab/oauth2-proxy` | `client-id`, `client-secret`, `cookie-secret` | homelab oauth2-proxy (Phase 2) |
| `secret/homelab/grafana-oidc` | `client-id`, `client-secret` | Grafana (Phase 2) |
| `secret/homelab/argocd-oidc` | `client-id`, `client-secret` | ArgoCD (Phase 2) |
| `secret/oracle-k3s/miniflux-oidc` | `client-id`, `client-secret` | Miniflux (Phase 2) |

---

## 7. File Changes (Phase 1)

### New Files
| File | Description |
|------|-------------|
| `cloud/oracle/manifests/auth-system/namespace.yaml` | `auth-system` namespace |
| `cloud/oracle/manifests/auth-system/oauth2-proxy.yaml` | oauth2-proxy Deployment + Service |
| `cloud/oracle/manifests/auth-system/external-secret.yaml` | ESO ExternalSecret for oauth2-proxy credentials |
| `cloud/oracle/manifests/auth-system/httproute.yaml` | HTTPRoute for `/oauth2/*` callback path |

### Modified Files
| File | Change |
|------|--------|
| `cloud/oracle/manifests/base/traefik-config.yaml` | Add `sso-forwardauth` Middleware |
| `cloud/oracle/manifests/base/gateway.yaml` | Add ForwardAuth filter to homepage, uptime-kuma HTTPRoutes; add ReferenceGrant for auth-system |
| `cloud/oracle/manifests/personal-services/it-tools.yaml` | Add ForwardAuth filter to HTTPRoute |
| `cloud/oracle/manifests/personal-services/squoosh.yaml` | Add ForwardAuth filter to HTTPRoute |
| `cloud/oracle/manifests/personal-services/stirling-pdf.yaml` | Remove own auth, add ForwardAuth filter |
| `cloud/oracle/manifests/kustomization.yaml` | Add auth-system resources |
| `cloud/oracle/cloudflare/terraform.tfvars` | Add `oauth` subdomain |
| `cloud/oracle/justfile` | Add `deploy-auth`, `deploy-personal-services` targets |

---

## 8. Rollback

```bash
# Remove ForwardAuth filters → services become unauthenticated
kubectl --context oracle-k3s delete middleware sso-forwardauth -n kube-system

# Remove oauth2-proxy
kubectl --context oracle-k3s delete -f cloud/oracle/manifests/auth-system/

# Restore stirling-pdf auth
kubectl --context oracle-k3s apply -f cloud/oracle/manifests/personal-services/stirling-pdf.yaml
```

---

## 9. Resource Impact (oracle-k3s)

| Component | CPU Request | Memory Request | Memory Limit |
|-----------|-------------|---------------|--------------|
| oauth2-proxy | 10m | 32Mi | 64Mi |

oracle-k3s is an ARM instance. oauth2-proxy is a Go binary — minimal overhead.
