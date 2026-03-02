# Timeslot Deployment — 2026-03-02

## Overview

Deploy [timeslot](https://github.com/meirongdev/timeslot) — a self-hosted calendar visibility system — onto the **oracle-k3s** cluster, managed via the Kustomize manifest at `cloud/oracle/manifests/`.

## Architecture

| Property | Value |
|----------|-------|
| Cluster | oracle-k3s |
| Namespace | `personal-services` |
| URL | `https://slot.meirong.dev` |
| SSO | `sso-forwardauth` Middleware (defined in `base/traefik-config.yaml` for `personal-services` ns) |
| Storage | `local-path` StorageClass, **100Mi** PVC at `/data` (SQLite + small footprint) |
| Secret | Vault `secret/oracle-k3s/timeslot` → injected at Helm install time via `deploy-timeslot` justfile recipe |
| Image | `ghcr.io/meirongdev/timeslot:latest` |
| Helm chart | `deploy/helm` in [meirongdev/timeslot](https://github.com/meirongdev/timeslot) (not published to Helm repo — sparse-cloned at deploy time) |

## Secret Injection Pattern (Helm Integration)

The upstream Helm chart (`deploy/helm`) handles app resources (Deployment, Service, PVC, ConfigMap, Secret) natively:

1. The `deploy-timeslot` justfile recipe reads `admin_password` from Vault (`secret/oracle-k3s/timeslot`) via `kubectl exec -n vault vault-0`
2. It passes `--set config.adminPassword=<value>` to `helm upgrade --install` at deploy time — Vault is the source of truth; ESO is **not** used for this service
3. The Helm chart's init container (`busybox`) substitutes `$ADMIN_PASSWORD` from the Helm-managed Secret into `config.json` at pod startup
4. The HTTPRoute (`slot.meirong.dev → timeslot:8080`) is a supplementary resource in `manifests/personal-services/timeslot.yaml` (Kustomize-managed, not in the Helm chart)

## Files Changed

| File | Change |
|------|--------|
| `cloud/oracle/manifests/personal-services/timeslot.yaml` | **Updated** — HTTPRoute only (Helm manages Deployment/Service/PVC/ConfigMap/Secret) |
| `cloud/oracle/justfile` | **Added** `deploy-timeslot` recipe (sparse-clone chart, inject secret from Vault, helm upgrade) |
| `docs/plans/2026-03-02-timeslot-deployment.md` | This file |

## Key oracle-k3s Differences vs homelab

- **Gateway name**: `oracle-gateway` (not `homelab-gateway`)
- **Storage class**: `local-path` (not `nfs-client`)
- **Vault key format**: `oracle-k3s/timeslot` (not `homelab/timeslot`) — under `secret/oracle-k3s/timeslot` in Vault
- **SSO middleware**: Already defined in `base/traefik-config.yaml` for `personal-services` ns
- **Secret management**: Password injected at Helm install time (no ESO ExternalSecret needed)
- **App resources**: Managed by Helm (`deploy-timeslot`); HTTPRoute only managed by Kustomize

## Deployment Steps

```bash
# 1. Store secret in Vault (oracle-k3s namespace to distinguish from homelab secrets)
kubectl --context k3s-homelab exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN=\$VAULT_TOKEN vault kv put secret/oracle-k3s/timeslot admin_password=<password>"

# 2. Deploy Helm chart (fetches chart from GitHub, injects secret from Vault)
cd cloud/oracle
just deploy-timeslot

# 3. Apply Kustomize manifests (for HTTPRoute + other oracle-k3s resources)
just deploy-manifests
# or just the personal-services subset:
# kubectl --context oracle-k3s apply -f manifests/personal-services/

# 4. Re-provision uptime-kuma monitors
just provision-uptime-kuma
```

## Cloudflare DNS (manual step)

Oracle-k3s DNS records are NOT managed by Terraform (only homelab tunnel is). Add `slot.meirong.dev` manually:

1. Cloudflare dashboard → Zero Trust → Tunnels → oracle-k3s tunnel
2. Public Hostnames → Add a public hostname:
   - Subdomain: `slot`
   - Domain: `meirong.dev`
   - Service: `http://traefik.kube-system.svc:80`
3. DNS record is created automatically

## Verification

```bash
# Helm release status
helm --kube-context oracle-k3s list -n personal-services

# Pod status
kubectl --context oracle-k3s -n personal-services get pods -l app.kubernetes.io/name=timeslot

# Init container rendered config (password should appear as *** in logs only)
kubectl --context oracle-k3s -n personal-services logs -l app.kubernetes.io/name=timeslot -c config-init

# HTTPRoute synced
kubectl --context oracle-k3s -n personal-services get httproute timeslot

# Local connectivity test
kubectl --context oracle-k3s -n personal-services port-forward svc/timeslot 8080:8080
curl http://localhost:8080/api/slots

# External access (after DNS)
curl -I https://slot.meirong.dev
```
