# Developer Platform Design

**Date:** 2026-02-19
**Status:** Approved

## Goal

Transform the existing homelab into a personal developer platform that enables rapid deployment of new personal projects, with:

- Unified SSO/OIDC authentication (no login code per project)
- Automatic HTTPS subdomains via Cloudflare
- Internal mTLS between microservices
- Unified observability via OpenTelemetry (OTLP) — services emit once, backend routes automatically
- Standard CI/CD pipeline (GitHub Actions → GHCR → ArgoCD)
- Project scaffold service for bootstrapping new services
- Secure database provisioning via Vault dynamic credentials

---

## Current State (Baseline)

```
Internet → Cloudflare DNS → Cloudflare Tunnel → Traefik → K8s Services
                                                              │
                                              ┌───────────────┼───────────────┐
                                              │               │               │
                                           ArgoCD          Vault +        PostgreSQL
                                        (GitOps CD)       ESO (secrets)  (database)
                                              │
                                    GitHub Actions + GHCR
                                          (CI + images)
```

**Observability:** Loki + Grafana + Tempo + Prometheus (monitoring namespace)

---

## Target Architecture

```
Internet
    │
Cloudflare (TLS termination, DNS)
    │
Cloudflare Tunnel (cloudflared pod)
    │
Traefik (Gateway API / HTTPRoute)
    │
┌───────────────────────────────────────────────────────────┐
│  K3s Cluster                                              │
│                                                           │
│  ┌─────────────┐    ┌─────────────┐    ┌──────────────┐  │
│  │  ZITADEL    │    │  Scaffold   │    │  Personal    │  │
│  │  (SSO/OIDC) │    │  Service    │    │  Services    │  │
│  │  zitadel ns │    │  scaffold ns│    │  (per app)   │  │
│  └─────────────┘    └─────────────┘    └──────────────┘  │
│                                               │           │
│  ┌─────────────────────────────────────────── ┼ ───────┐  │
│  │  Istio Ambient Mode (mTLS layer)           │       │  │
│  │  ztunnel (DaemonSet, node-level L4)        │       │  │
│  │  waypoint proxy (per-namespace L7, opt.)   │       │  │
│  └────────────────────────────────────────────────────┘  │
│                                                           │
│  ┌─────────────┐    ┌─────────────┐    ┌──────────────┐  │
│  │  Vault      │    │  cert-      │    │  PostgreSQL  │  │
│  │  (PKI + KV) │◄──►│  manager   │    │  (database)  │  │
│  │  vault ns   │    │  cert-mgr ns│    │  database ns │  │
│  └─────────────┘    └─────────────┘    └──────────────┘  │
│                                                           │
│  ┌──────────────────────────────────────────────────────┐ │
│  │  OTel Collector (OTLP gateway)                       │ │
│  │    ← Services / Istio ztunnel / Spring Boot agent    │ │
│  │    → Loki (logs) │ Tempo (traces) │ Prometheus (metrics)│ │
│  │  Grafana (unified UI, unchanged)                     │ │
│  └──────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────┘
        │                         │
   GitHub (code +            GHCR (images)
   Actions CI)                    │
        │                         │
        └──────── ArgoCD CD ───────┘
                 (auto-sync from Git)
```

---

## Components

### P1 — ZITADEL (SSO/OIDC)

| Item | Detail |
|------|--------|
| Namespace | `zitadel` |
| Subdomain | `auth.meirong.dev` |
| Backend DB | PostgreSQL (existing, new schema `zitadel`) |
| Protocol | OIDC / OAuth2 |
| Integration | Personal projects register as OIDC clients; users log in once via `auth.meirong.dev` |
| ArgoCD managed | Yes (`argocd/applications/zitadel.yaml`) |

New projects get an OIDC client ID/secret from ZITADEL (stored in Vault), injected via ESO at deploy time. No login UI needed per project.

### P2 — cert-manager + Vault PKI

| Item | Detail |
|------|--------|
| Namespace | `cert-manager` |
| Issuer | Vault PKI secrets engine (internal CA) |
| Purpose | Issue TLS certs for Istio's trust anchor and internal service identity |
| External TLS | Still handled by Cloudflare (unchanged) |
| ArgoCD managed | Yes (`argocd/applications/cert-manager.yaml`) |

Vault PKI provides the root CA. cert-manager issues workload certificates for Istio to use as its trust anchor, enabling automatic rotation without manual intervention.

### P3 — OpenTelemetry (Unified Observability)

| Item | Detail |
|------|--------|
| Operator | OpenTelemetry Operator (manages Collector instances + auto-instrumentation) |
| Collector | `OpenTelemetryCollector` CR in `monitoring` namespace, mode: `Deployment` |
| OTLP endpoint | `otel-collector.monitoring.svc:4317` (gRPC) / `4318` (HTTP) |
| Exporters | Loki (logs), Tempo (traces), Prometheus remote_write (metrics) |
| Auto-instrumentation | `Instrumentation` CR for Java — injects OTel Java Agent into Spring Boot pods automatically |
| Grafana Alloy | Replaces Promtail for node/system log collection; forwards via OTLP |
| ArgoCD managed | Yes (`argocd/applications/otel.yaml`) |

**What changes:**
- Services only need `OTEL_EXPORTER_OTLP_ENDPOINT` env var — no per-backend SDK config
- Spring Boot pods in labeled namespaces get OTel Java Agent injected automatically (zero code change)
- Istio Ambient ztunnel exports mesh metrics via OTLP natively
- Loki / Tempo / Prometheus backends remain unchanged; Grafana dashboards untouched

**What stays the same:**
- All LGTM backends (Loki, Grafana, Tempo, Prometheus) — not managed by ArgoCD, no migration needed
- Grafana UI, existing dashboards, alerting rules

---

### P4 — Istio Ambient Mode

| Item | Detail |
|------|--------|
| Mode | Ambient (no sidecars) |
| L4 component | `ztunnel` DaemonSet (node-level, shared) |
| L7 component | Waypoint proxy (per-namespace, opt-in) |
| CNI impact | None — does not replace K3s Flannel |
| mTLS | Automatic for all pods in labeled namespaces |
| ArgoCD managed | Yes (`argocd/applications/istio.yaml`) |

Opt-in per namespace via label: `istio.io/dataplane-mode: ambient`. Personal service namespaces are enrolled; system namespaces (kube-system, monitoring) are not.

### P5 — CI/CD Templates

| Item | Detail |
|------|--------|
| Repository | `github.com/meirongdev/service-template` (GitHub template repo) |
| CI | `.github/workflows/ci.yaml` — build + test + push to GHCR |
| CD | `helm/` — standard Helm chart scaffold |
| ArgoCD | `argocd-application.yaml.tmpl` — ready-to-apply Application manifest |
| Image Updater | Pre-configured `ImageUpdater` CR annotations for GHCR tracking |

Workflow for a new project:
1. "Use this template" on GitHub → new repo
2. Push → GitHub Actions builds and pushes image to GHCR
3. Apply ArgoCD Application → live at `<name>.meirong.dev` within minutes

### P6 — Scaffold Service

| Item | Detail |
|------|--------|
| Namespace | `scaffold` |
| Subdomain | `scaffold.meirong.dev` |
| Tech | Spring Boot + Spring Initializr customization API |
| Auth | ZITADEL OIDC (only accessible when logged in) |
| Function | Web UI to generate project ZIP: choose framework, DB, auth preset, CI template |
| ArgoCD managed | Yes (`argocd/applications/scaffold.yaml`) |

Presets available:
- **Spring Boot + PostgreSQL + OIDC** — most common personal project stack
- **Spring Boot microservice** — no DB, Istio mTLS ready
- **Static frontend** — Nginx + GHCR pipeline

### P7 — Vault Dynamic DB Credentials

| Item | Detail |
|------|--------|
| Vault engine | `database` secrets engine for PostgreSQL |
| Flow | App requests short-lived DB creds from Vault at startup via ESO `VaultDynamicSecret` |
| Benefit | No static passwords in K8s Secrets; auto-rotation |
| Depends on | Vault PKI (P2) already bootstrapped |

---

## New Project Onboarding Flow (Post-Platform)

```
1. scaffold.meirong.dev
   → Generate project from template (Spring Boot / microservice / frontend)
   → Download ZIP or push directly to new GitHub repo

2. GitHub repo created
   → GitHub Actions CI: build → test → push image to GHCR

3. Helm chart + ArgoCD Application committed to homelab repo
   → git push → ArgoCD auto-deploys within 3 min

4. cloudflare/terraform/terraform.tfvars updated with new subdomain
   → just apply → DNS live

5. ZITADEL: register new OIDC client
   → Store client_id/secret in Vault
   → ESO syncs to K8s Secret → app reads at startup

6. OTel 自动接入
   → Spring Boot 服务所在 namespace 有 Instrumentation CR
   → OTel Operator 自动注入 Java Agent，无需改代码
   → traces → Tempo，logs → Loki，metrics → Prometheus

7. (Optional) Vault dynamic DB credentials configured
   → App gets ephemeral PostgreSQL credentials at startup
```

---

## Implementation Phases

### Phase 1 — ZITADEL (SSO)

**Deliverables:**
- ZITADEL deployed in `zitadel` namespace via Helm + ArgoCD
- PostgreSQL database `zitadel` schema initialized
- `auth.meirong.dev` HTTPRoute in gateway.yaml + Cloudflare DNS
- ZITADEL admin credentials stored in Vault
- One test OIDC client created and verified

**Files to create/modify:**
- `k8s/helm/values/zitadel.yaml`
- `k8s/helm/manifests/zitadel.yaml`
- `k8s/helm/manifests/gateway.yaml` (add HTTPRoute)
- `argocd/applications/zitadel.yaml`
- `cloudflare/terraform/terraform.tfvars` (add `auth` subdomain)

---

### Phase 2 — cert-manager + Vault PKI

**Deliverables:**
- cert-manager deployed via Helm + ArgoCD
- Vault PKI secrets engine enabled and configured as internal CA
- `ClusterIssuer` pointing to Vault PKI
- Test certificate issued and verified

**Files to create/modify:**
- `k8s/helm/values/cert-manager.yaml`
- `k8s/helm/manifests/cert-manager.yaml` (ClusterIssuer, VaultIssuer)
- `argocd/applications/cert-manager.yaml`

---

### Phase 3 — OpenTelemetry (Unified Observability)

**Deliverables:**
- OTel Operator deployed via Helm + ArgoCD
- `OpenTelemetryCollector` CR configured with OTLP receivers and exporters to Loki / Tempo / Prometheus
- `Instrumentation` CR for Java auto-instrumentation (Spring Boot)
- Grafana Alloy deployed to replace Promtail for node/system logs
- Verified: Spring Boot test app emits traces to Tempo and logs to Loki via OTLP with zero code changes

**Files to create/modify:**
- `k8s/helm/values/otel-operator.yaml`
- `k8s/helm/manifests/otel.yaml` (Collector CR, Instrumentation CR)
- `k8s/helm/values/grafana-alloy.yaml`
- `argocd/applications/otel.yaml`

---

### Phase 4 — Istio Ambient Mode

**Deliverables:**
- Istio installed in ambient mode (no sidecars) via Helm + ArgoCD
- ztunnel DaemonSet running on the node
- `personal-services` namespace labeled for ambient mode
- mTLS verified between two test services
- Waypoint proxy deployed in `personal-services` (L7 policy opt-in)
- Istio OTLP metrics export pointed at OTel Collector

**Files to create/modify:**
- `k8s/helm/values/istio-base.yaml`, `istio-cni.yaml`, `ztunnel.yaml`, `istiod.yaml`
- `argocd/applications/istio.yaml`
- `k8s/helm/manifests/personal-services.yaml` (namespace label)

---

### Phase 5 — CI/CD Templates

**Deliverables:**
- GitHub template repository `meirongdev/service-template` created
- Standard `ci.yaml` GitHub Actions workflow (build → GHCR push)
- Standard Helm chart (`helm/`) with configurable values, OTel env vars pre-set
- `ImageUpdater` CR annotation examples
- ArgoCD Application template

**Files to create:**
- New GitHub repo (outside homelab repo)
- `docs/plans/new-service-runbook.md` — step-by-step guide for new projects

---

### Phase 6 — Scaffold Service

**Deliverables:**
- Spring Boot application wrapping Spring Initializr
- Custom presets: Spring Boot + PostgreSQL + OIDC, microservice (OTel + Istio ready), static frontend
- Deployed to `scaffold` namespace, accessible at `scaffold.meirong.dev`
- Protected by ZITADEL OIDC

**Files to create/modify:**
- New GitHub repo `meirongdev/scaffold-service`
- `k8s/helm/manifests/scaffold.yaml`
- `argocd/applications/scaffold.yaml`
- `cloudflare/terraform/terraform.tfvars` (add `scaffold` subdomain)

---

### Phase 7 — Vault Dynamic DB Credentials

**Deliverables:**
- Vault `database` secrets engine configured for PostgreSQL
- Role defined per application (e.g., `myapp-role` → limited permissions)
- ESO `VaultDynamicSecret` resource template created
- One existing service migrated as proof of concept

**Files to create/modify:**
- `k8s/helm/manifests/vault-eso-config.yaml` (dynamic secret config)
- `docs/plans/vault-dynamic-db-runbook.md`

---

## Dependency Graph

```
P1 (ZITADEL)
    └── P6 (Scaffold — needs OIDC)

P2 (cert-manager + Vault PKI)
    └── P4 (Istio — needs trust anchor)
    └── P7 (Vault dynamic DB — Vault PKI already used)

P3 (OTel)
    └── P4 (Istio — exports metrics to OTel Collector)

P5 (CI/CD templates) — independent, can start anytime

Parallel start: P1 + P2 + P3 + P5
```

---

## Resource Estimate (Single Node)

| Component | RAM |
|-----------|-----|
| ZITADEL | ~200MB |
| cert-manager | ~50MB |
| OTel Collector + Operator | ~150MB |
| Grafana Alloy (replaces Promtail) | ~80MB |
| Istio (ambient ztunnel) | ~150MB |
| Scaffold service | ~256MB |
| **Total new** | **~886MB** |

Current node has sufficient headroom assuming 4GB+ RAM available.
