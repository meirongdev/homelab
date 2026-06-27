# Homelab Development Conventions & Context

This file provides guidance for AI assistants (Claude, Gemini) and developers working in this repository.
It is symlinked as `CLAUDE.md` and `GEMINI.md` in the project root for automatic AI context loading.

## Project Overview

A five-layer dual-cluster Homelab infrastructure-as-code setup:
1. **Proxmox VM** (`proxmox/`) — VM provisioning on Proxmox VE.
2. **Kubernetes Clusters** (`k8s/ansible/` + `cloud/oracle/`) — homelab K3s (Cilium CNI) + oracle-k3s (Cilium CNI).
3. **Applications** (`k8s/helm/` + `cloud/oracle/manifests/`) — Helm charts and K8s manifests for observability, databases, and personal services.
4. **External Access** (`cloudflare/`) — Cloudflare Tunnel and DNS management via Terraform.
5. **GitOps** (`argocd/`) — ArgoCD continuously syncs manifests from Git to both clusters.

## Project Structure

```
homelab/
├── proxmox/
│   ├── terraform/      # IaC to provision the Ubuntu VM on Proxmox VE
│   └── ansible/        # Downloads cloud images
├── k8s/
│   ├── ansible/        # K3s installation and node configuration
│   └── helm/
│       ├── values/     # Helm release configurations (one file per chart)
│       └── manifests/  # Raw K8s YAML (Calibre-Web, Homepage, Vault, Gateway, etc.)
├── cloud/
│   └── oracle/         # Oracle Cloud K3s cluster IaC + manifests
│       ├── ansible/    # oracle-k3s node setup
│       ├── terraform/  # OCI VM provisioning
│       └── manifests/  # oracle-k3s workloads (rss-system, homepage, monitoring, etc.)
├── argocd/
│   ├── install/        # ArgoCD install patches (TLS disable)
│   ├── projects/       # AppProject definitions (RBAC)
│   └── applications/   # ArgoCD Application manifests (one per logical group)
├── cloudflare/
│   └── terraform/      # Cloudflare Tunnel ingress rules + DNS records
├── tailscale/
│   └── terraform/      # Tailscale ACL + node pre-auth keys
└── docs/
    ├── README.md       # 文档索引
    ├── CONVENTIONS.md  # This file (symlinked as CLAUDE.md and GEMINI.md)
    ├── architecture/   # Architecture notes and TODO
    ├── runbooks/       # 运维操作手册 (Kopia, DNS recovery, etc.)
    └── plans/          # Implementation plan records
```

## Key Commands (Context-Dependent)

### Infrastructure (Proxmox)
Run from `proxmox/terraform/`:
```bash
make init    # terraform init
make plan    # terraform plan
make apply   # terraform apply
```

### Kubernetes Setup (K3s)
Run from `k8s/ansible/`:
```bash
just setup-k8s        # Install K3s single-node cluster
just fetch-kubeconfig # Sync kubeconfig to ~/.kube/config
just cleanup-k8s      # Uninstall K3s
```

### Application Deployment
Run from `k8s/helm/`:
```bash
just init                  # Initialize .env from .env.example
just deploy-all            # Deploy full observability stack (LGTM)
just setup-nfs-provisioner # Install NFS storage provisioner
just setup-postgres        # Deploy PostgreSQL
just deploy-homepage       # First-time deploy Homepage dashboard
just update-homepage       # Update Homepage config + restart pod (apply + rollout restart)
just status                # Check monitoring namespace state
```

### ArgoCD GitOps
Run from `k8s/helm/`:
```bash
just deploy-argocd      # Install ArgoCD + register all Applications (idempotent)
just deploy-argocd-dns  # Apply Cloudflare DNS for argocd.meirong.dev
just argocd-password    # Print initial admin password
just argocd-sync        # Trigger immediate full sync (bypasses 3-min poll)
just argocd-status      # Show all Application sync/health status
```

### External Access (Cloudflare)
Run from `cloudflare/terraform/`:
```bash
just init    # terraform init
just plan    # Preview DNS/Tunnel changes
just apply   # Apply DNS/Tunnel changes
```

## Architecture Details

### Networking & Ingress
- All external traffic flows: `Internet → Cloudflare DNS → Cloudflare Tunnel → Cilium Gateway API → Services`
- **Cloudflare Tunnel**: `cloudflared` pod in `cloudflare` namespace forwards to the Cilium-managed Gateway service (`cilium-gateway-<gateway-name>.kube-system.svc:80`). oracle-k3s uses `--protocol http2` (Oracle Cloud NSG blocks outbound UDP/QUIC).
- **Ingress**: Cilium Gateway API is the only in-cluster HTTP entrypoint (`HTTPRoute` resources in `manifests/gateway.yaml`)
- **CNI**: Both clusters use **Cilium** (eBPF + VXLAN); homelab deployed 2026-03-06, oracle-k3s migrated from Flannel 2026-03-07
  - homelab Cilium is **Helm-managed via `just deploy-cilium`** (not ArgoCD); values codified in `k8s/cilium/values.yaml` (+ `README.md`). Pinned to v1.19.1 images. The recipe pins `--version 1.19.1`, applies that file, and restores the live `cilium-ca` for ClusterMesh (self-signs on a fresh install).
  - **`gatewayAPI.enableAppProtocol: true` is required** — without it, ZITADEL console v1 gRPC calls (auth.v1/admin.v1) 404 through the gateway because Envoy's grpc_web filter sends converted native-gRPC over HTTP/1.1 to a backend that needs h2c. Honouring Service `appProtocol` gives `zitadel:8080` an explicit h2c upstream. Runbook: `docs/runbooks/zitadel-console-grpc-404.md`
- **homelab K8s Node**: `10.10.10.10` / Tailscale `100.94.186.7` | **Proxmox host** (`pve`): `192.168.50.4` / Tailscale `100.118.193.51` (Ryzen 5600H laptop; runs the `k8s-node` VM)
- **oracle-k3s Node**: `10.0.0.26` / Tailscale `100.107.166.37`
- **Cross-cluster network**: Tailscale subnet routing (Pod CIDR only): homelab `10.42.0.0/16`; oracle-k3s `10.52.0.0/16`。Cilium ClusterMesh active (connected 2026-03-08 via `cilium clustermesh connect --source-endpoint 100.94.186.7:32379 --destination-endpoint 100.107.166.37:32379 --allow-mismatching-ca`). KVStoreMesh enabled on both sides. 见 `docs/architecture/tailscale-network.md`
- **Exception — Kopia**: **Web UI + CLI 都经 NodePort 31515（Tailscale `100.94.186.7`），不经 Cloudflare Tunnel/Gateway**。两个原因叠加：(1) Kopia gRPC-Go client 的 bidirectional streaming 经 Tunnel 524 超时；(2) kopia 服务器为 TLS（自签），Cilium Gateway 无法对自签后端发起 TLS（移除了 `backup.meirong.dev` 路由）。直连：`kopia repository connect server --url=https://100.94.186.7:31515 --server-cert-fingerprint=<sha256> --override-username=admin`。详见 `docs/runbooks/backup-recovery.md`。

### Cloudflare WAF & Security
- **Status**: ✅ 生产运行中（2026-02-28 上线）
- **Scope**: Zone-level — protects ALL subdomains across both tunnels (homelab + oracle-k3s)
- **Config**: `cloudflare/terraform/waf.tf`（Terraform 管理，`just apply` 部署）
- **Zone settings**: SSL Full, TLS 1.2+, Always HTTPS, Security Level Medium, Browser Integrity Check, Email Obfuscation, Hotlink Protection, Opportunistic Encryption
- **Custom WAF rules** (5/5 used):
  1. Block WordPress/PHP/admin scanner paths
  2. Block sensitive file access (`.env`, `.git`, `.htaccess`, etc.)
  3. Block known vulnerability scanner user agents (sqlmap, nikto, nmap, etc.)
  4. Managed Challenge for high threat score visitors (score > 14)
  5. Block non-standard HTTP methods (TRACE, CONNECT, etc.)
- **Rate limiting**: Auth endpoints (`/login`, `/oauth2`, `/signin`, `/v1/auth`) — 30 req/10s per IP
- **Pro plan upgrade**: Managed Ruleset (SQLi/XSS/RCE) + OWASP CRS + Leaked Credentials Detection（见 `waf.tf` 注释段）
- **API Token 权限**: Zone DNS Edit + Zone WAF Edit + Zone Settings Edit + Cloudflare Tunnel Edit

### 集群内部安全 (Pod 基线 / 准入 / 扫描 / 节点 CIS)
- **定位**: 上面的 WAF/Identity 是**南北向**边缘安全；这一层补**集群内部**（准入管控、镜像 CVE/配置扫描、Pod 安全基线、节点 CIS）。完整部署/验证/回滚见 `docs/runbooks/security-hardening.md`。设计与权衡见 `docs/plans/2026-06-16-k3s-security-hardening.md`。
- **硬约束驱动选型**: homelab 单节点 5600H 笔记本（idle ~74°C、重启需 `just homelab-recover`），故全部 **fail-open + 控 CPU**：Kyverno `failurePolicy: Ignore`、Trivy 串行扫描、周期型工具优先。
- **Pod Security Admission (PSA)**: 内置准入，**永远在线的基线地板**（Kyverno 挂了也生效）。homelab 经 **`just harden-psa`**（幂等 `kubectl label`，**刻意不走 ArgoCD**——渲染 Namespace 对象的 App 配 prune+selfHeal 会有"误同步 prune 删 ns + 级联删 PVC"的致命风险）；oracle 在 kustomize 树各 `*/namespace.yaml` 的 labels 里声明（那些 ns 本就被 kustomize 拥有，改现有资源无 prune 风险）。**等级**: 应用 ns `enforce=baseline`（实测零特权工作负载）；`kube-system`/`monitoring` `enforce=privileged`（cilium/node-exporter/otel/grafana 需特权）显式豁免，但仍打 `warn/audit=baseline` 留审计线索。**不做 `restricted`**（grafana 跑 root，属后续逐 ns 的活）。
- **Kyverno**（准入策略即代码，仅 homelab）: Helm App `kyverno`（`values/kyverno.yaml`，所有 controller `replicas:1`、`backgroundScanInterval:24h`），策略 CR 单独由 `kyverno-policies` App 同步（`manifests/kyverno-policies/`，便于**逐条 Audit→Enforce**）。4 条策略全部 `validationFailureAction: Audit` + `failurePolicy: Ignore` 起步：require-requests-limits / disallow-latest-tag / restrict-image-registries（噪声最大，长期 Audit）/ require-probes。系统 ns 由 Kyverno 默认 resourceFilters 已排除。**Audit→Enforce**: 读 `kubectl get polr -A` 确认某策略零违规后，改对应文件的 action 为 `Enforce` 再 push。
- **Trivy Operator**（镜像 CVE / 配置审计 / RBAC / 暴露密钥，仅 homelab）: Helm App，ns `trivy-system`，`values/trivy-operator.yaml`。热节点关键: `scanJobsConcurrentLimit:1` + `builtInTrivyServer`(ClientServer 模式 + NFS PVC 持久化漏洞 DB) + `severity:HIGH,CRITICAL` + `ignoreUnfixed` + 关 `clusterComplianceEnabled`（CIS 交给 kube-bench）。指标经 ServiceMonitor(**带 `release: kube-prometheus-stack`**)抓取；告警 `manifests/trivy-alerts.yaml`（critical CVE→warning、暴露密钥→critical、absent 元告警）；看板 `manifests/trivy-dashboard.yaml`（Grafana `Security` 文件夹）。后两者已并入 `monitoring-dashboards` App 的 include glob。
- **kube-bench**（CIS 巡检）: `manifests/kube-bench.yaml`（专用 `kube-bench` ns 标 privileged + 每周 CronJob），独立 ArgoCD App。**必须用 k3s 基准**（`--benchmark k3s-cis-*`，否则满屏假 FAIL）；结果打 stdout→Loki（按 `{namespace="kube-bench"}` 查）。
- **节点 CIS 加固**: `k8s/ansible/playbooks/setup-k3s.yaml` 加 `/etc/sysctl.d/31-k8s-protect-kernel.conf`(protect-kernel-defaults 所需 sysctl) + config.yaml `protect-kernel-defaults: true`。**顺序保障**: sysctl drop-in 先落盘持久化，故 k3s 重启时检查必过。**现有节点需维护窗口 `systemctl restart k3s`/重启才生效**。**API 审计日志刻意延后**（磁盘紧）。
- **⚠️ chart 版本**: Kyverno/Trivy 的 `argocd/applications/*.yaml` pin 的 chart 版本**部署前须 `helm search repo ... --versions` 核对**（避免 sync 失败）。**AppProject** `argocd/projects/homelab.yaml` 的 `sourceRepos` 已加 kyverno+aquasecurity 仓库，但 AppProject 非 ArgoCD 自动同步，需 `kubectl apply` 一次。
- **延后/门控**: **Cilium 网络默认拒绝**不在本批（DNS/ClusterMesh/Envoy/egress 链路复杂，单用户收益边际低）。Hubble 已启用做流量可见性，作为日后单命名空间灰度强制的前置（见 runbook）。
- **运行时检测（Phase 2，已部署）**: 按集群选型落地——homelab→**Tetragon**（Cilium 原生、内核态过滤省 CPU、不加热；Helm App `tetragon`，chart 1.7.0，in-cluster ns `tetragon`，`values/tetragon.yaml`）；oracle→**Falco + Falcosidekick→Gotify**（规则开箱即用，CPU 余量大；Helm App `falco`，chart 9.1.0，部署到 oracle 外部集群 ns `falco`，`values/falco.yaml`，falcosidekick→Gotify token 经 `cloud/oracle/manifests/falco/` 注入）。安全事件看板 `manifests/security-events-dashboard.yaml`（Grafana `Security` 文件夹）。

### Identity
- **Status**: ZITADEL remains available at `auth.meirong.dev`, but shared ingress-layer SSO has been removed.
- **Current model**: services are either public, gated by **native ZITADEL OIDC** (see list below), or rely on their own built-in auth (for example Vault, Kopia, and Timeslot admin Basic Auth).
- **Reason**: removing the Traefik ForwardAuth / oauth2-proxy chain simplifies ingress and avoids a second auth hop on every request.
- **Recommended direction**: keep `HTTPRoute` resources controller-neutral and add auth at the app layer. Prefer native OIDC with ZITADEL first; use a per-app `oauth2-proxy` reverse-proxy only for apps that cannot speak OIDC directly.
- **Native ZITADEL OIDC apps** (no oauth2-proxy): **Stirling-PDF** (`pdf`), **Grafana** (`grafana`), **Miniflux** (`rss`), **KaraKeep** (`keep`), and **ArgoCD** (`argocd`) speak OIDC directly. Each has a confidential WEB client provisioned (idempotently) by `zitadel/scripts/configure-oidc-app.sh` (REST, not Terraform — TF/gRPC writes break across the CF edge); creds live in Vault under the app's own path (`secret/homelab/{grafana,argocd-oidc}`, `secret/oracle-k3s/{stirling-pdf,miniflux,karakeep}`, keys `oauth_client_id`/`oauth_client_secret`) → ESO → the app's K8s Secret. **Local username/password login is kept enabled as a fallback on each** (no lockout). Redirect URIs: Grafana `…/login/generic_oauth`, Miniflux `…/oauth2/oidc/callback`, Stirling `…/login/oauth2/code/oidc`, KaraKeep `…/api/auth/callback/custom`, ArgoCD `…/auth/callback` (+ `http://localhost:8085/auth/callback` for CLI).
  - **Deploy paths differ**: Grafana → `just deploy-prometheus`; ArgoCD → `just deploy-argocd` (both Helm, **not** ArgoCD-managed; run after the Vault write). Miniflux/Stirling/KaraKeep + ArgoCD's `argocd-oidc` ExternalSecret reconcile via ArgoCD on `git push` (oracle-k3s app, and `vault-eso` app for argocd-oidc).
  - **Grafana**: `role_attribute_path: "'Admin'"` grants Admin to any ZITADEL-authenticated identity (safe for this single-user, locked-down IdP).
  - **Miniflux**: `OAUTH2_USER_CREATION=1` auto-provisions on first SSO login; to keep admin rights, log in as the local admin first and link the OIDC identity under Settings.
  - **KaraKeep**: NextAuth custom provider; `OAUTH_ALLOW_DANGEROUS_EMAIL_ACCOUNT_LINKING=true` links the ZITADEL identity to the existing account by verified email (ZITADEL verifies emails), so SSO logs into the current account while `DISABLE_SIGNUPS=true` still blocks self-registration.
  - **ArgoCD**: dex stays disabled — native `configs.cm.oidc.config` with `clientID/clientSecret: $argocd-oidc:oidc.client*` resolved from an ESO secret labeled `app.kubernetes.io/part-of=argocd` (kept separate from the chart-managed `argocd-secret`). `rbac.policy.default: role:admin` grants admin to any authenticated identity. **Gotcha**: changing `oidc.config` only hot-reloads the ConfigMap — `argocd-server` must be `rollout restart`ed or the first SSO login 500s with `Initializing OIDC provider (issuer: )` (empty). On Helm 4 (SSA by default), `just deploy-argocd` needed a one-time `--force-conflicts` to take the `gateway` health field from a stale `kubectl-patch` manager.
- **Bifrost example of this pattern**: Bifrost's OSS admin UI/config-API have no auth, so they sit behind a per-app `oauth2-proxy` (reverse-proxy mode, ZITADEL OIDC) in the `bifrost` namespace; the inference API (`/v1`,`/openai`,`/anthropic`,`/genai`) is routed direct to Bifrost and gated by Bifrost virtual keys. The OIDC client is provisioned by `zitadel/scripts/configure-bifrost-oauth.sh` (REST, not Terraform — TF writes break across the CF edge); creds land in Vault `secret/homelab/bifrost-oauth2-proxy` → ESO.
- **GitHub social login (federated IdP)**: GitHub is added to ZITADEL as an **instance-level external IdP**, so every ZITADEL-OIDC app (Bifrost admin, etc.) automatically gains a "Sign in with GitHub" button — ZITADEL stays the single IdP. Provisioned by `zitadel/scripts/configure-github-idp.sh` (REST, same reason as the others — TF/gRPC writes break across the CF edge). **Locked down**: `isCreationAllowed/isAutoCreation=false`, `autoLinking=AUTO_LINKING_OPTION_EMAIL` — no stranger can self-register; a GitHub identity logs in only by linking to a pre-existing ZITADEL user via matching verified email. Currently linked to `zitadel-admin` (GitHub `meirongdev`, extUserId `137514603`). **Gotchas**: (1) this instance runs **Login V2** (`zitadel-login` pod), whose IdP callback is `https://auth.meirong.dev/idps/callback` — NOT the v1 `/ui/login/login/externalidp/callback`; the GitHub OAuth App's Authorization callback URL must be exactly that. (2) ZITADEL reads only GitHub's **public** email, so first-time email auto-linking required the GitHub account's email to be public; once linked it matches by GitHub user ID, so the email can be made private again.

### GitOps (ArgoCD)
- ArgoCD runs in the `argocd` namespace, UI at `argocd.meirong.dev`
- **Install**: ArgoCD is **Helm-managed** — chart `argo/argo-cd` `9.5.11` (appVersion v3.3.9), release `argocd`, values in `k8s/helm/values/argocd-values.yaml`, deployed via `just deploy-argocd`. `argocd-values.yaml` is the source of truth (repo-server DNS-gate initContainer, Cilium Gateway health check, ESO ignoreDifferences, `server.insecure`, slim install with dex/notifications/CRDs disabled all live there). History: originally a stock-manifest kubectl install; an in-place Helm adoption was impossible (immutable `.spec.selector` label differences between stock and chart), so it was migrated via a maintenance-window reinstall (delete chart-managed workloads, keep CRDs + Application CRs + `argocd-secret`/`argocd-redis`, then `helm upgrade --install`). Applications survived untouched (they're CRs); ArgoCD downtime ~4 min, managed services unaffected.
- **Sync poll interval**: 3 minutes (auto-syncs after every `git push`)
- **Managed by ArgoCD** (auto-sync + selfHeal; homelab in-cluster, plus oracle-k3s as an external cluster):
  - `root` App → `argocd/applications/` (App-of-Apps; manages all child Applications below)
  - `personal-services` App → `manifests/{calibre-web.yaml,calibre-ebook-sync.yaml,gotify.yaml,personal-services-limits.yaml}` (homelab)
  - `gateway` App → `manifests/gateway.yaml` (homelab Cilium Gateway)
  - `cloudflare` App → `manifests/cloudflare-tunnel.yaml` (homelab)
  - `vault-eso` App → `manifests/{vault-eso-config,*-external-secret}.yaml` (homelab)
  - `kopia` App → `manifests/{kopia.yaml,kopia-backup.yaml}` (homelab)
  - `zitadel` App → `manifests/zitadel.yaml` (homelab)
  - `calibre-metadata` App → `k8s/helm/manifests/calibre-metadata/` (Kustomize)
  - `monitoring-dashboards` App → `k8s/helm/manifests/grafana-dashboards.yaml` 等 ConfigMap
  - `argocd-image-updater` App → Helm chart `argo/argocd-image-updater` v1.1.1
  - `oracle-k3s` App → `cloud/oracle/manifests/` (Kustomize) on the **oracle-k3s external cluster** via Tailscale (`https://100.107.166.37:6443`); cluster cred from Vault→ESO secret `oracle-k3s-cluster` (Task: `docs/plans/2026-06-04-oracle-k3s-argocd-gitops.md`). Added 2026-06-04.
  - `bifrost` App → `manifests/bifrost.yaml` (homelab LLM gateway + oauth2-proxy)
  - `kyverno` App (Helm chart) + `kyverno-policies` App → `manifests/kyverno-policies/` (homelab admission policies)
  - `trivy-operator` App (Helm chart, `trivy-system` ns) — image CVE / config scanning (homelab)
  - `kube-bench` App → `manifests/kube-bench.yaml` (homelab CIS CronJob)
  - `namespace-guardrails` App → `manifests/namespace-guardrails.yaml` (homelab LimitRange guardrails)
  - `tetragon` App (Helm chart, `tetragon` ns) — runtime detection (homelab)
  - `falco` App (Helm chart, `falco` ns) — runtime detection on the **oracle-k3s external cluster**
- **NOT managed by ArgoCD** (manual `just` commands):
  - HashiCorp Vault — requires manual init/unseal (see `just homelab-recover` for restart recovery)
  - External Secrets Operator — depends on Vault
  - kube-prometheus-stack / Loki / Tempo — Helm releases
  - PostgreSQL — stateful, avoid auto-prune
  - NFS Provisioner — infrastructure layer
  - Cloudflare Terraform — non-K8s resources
- **oracle-k3s manifests** (`cloud/oracle/manifests/`): **under GitOps as of 2026-06-04** — managed by the homelab ArgoCD `oracle-k3s` Application over Tailscale (oracle registered as an external cluster, `https://100.107.166.37:6443`, bearer-token cred from Vault `secret/homelab/argocd-oracle-cluster` materialised by ESO into the `oracle-k3s-cluster` cluster Secret). Auto-sync + selfHeal + **prune** are on; stateful PVCs (`miniflux-db-pvc`, `karakeep-data`, `meilisearch-data`, `uptime-kuma-data`, `stirling-pdf-configs`) carry `argocd.argoproj.io/sync-options: Prune=false`. `git push` → reconciles within 3 min, same as homelab. Bootstrap RBAC (`argocd-manager` SA + cluster-admin) is in `cloud/oracle/bootstrap/argocd-manager.yaml` — applied manually once, kept **out** of the kustomize tree. The `vault-token` Secret (rss-system) remains a manual bootstrap dependency (not pruned, see `base/vault-store.yaml`). Migration record + caveats: `docs/plans/2026-06-04-oracle-k3s-argocd-gitops.md`.

### Storage
- **NFS host**: `192.168.50.106` (PVE node, `storage` group in `proxmox/ansible/inventory.yaml`). Data lives on a **ZFS pool `mrstorage` mounted at `/storage`** (separate from the OS disk), provisioned by `proxmox/ansible/storage-playbook.yaml`.
- **Two NFS exports** (`/etc/exports`, Ansible-managed):
  - `/storage` (`192.168.50.0/24` + Tailscale `100.89.15.120`) — backs the `nfs-client` dynamic provisioner (`nfs-subdir-external-provisioner`), which creates per-PVC subdirs under `/storage/nfs/k8s/` (see `k8s/helm/values/nfs-values.yaml`).
  - `/storage/calibre` (`*`, `all_squash` anon uid/gid 1000) — static RWX PV for the Calibre book library (`calibre-books-pv`).
- **Only homelab uses this NFS.** oracle-k3s has no `nfs-client` StorageClass — its stateful PVCs use OCI-local `local-path`.
- **OS reinstall is data-safe**: the OS is on the boot disk; all data is on the `mrstorage` ZFS pool. After a host rebuild, re-running `storage-playbook.yaml` does `zpool import -f mrstorage` + rebuilds `/etc/exports` + `exportfs -ra`. Because the ZFS dataset is unchanged, existing NFS PVs keep the same file handles (no `ESTALE`) and pods re-mount transparently. Expect a brief node wedge while NFS is down — the classic containerd `failed to reserve container name` symptom — which self-heals once NFS returns. (Verified 2026-06-13 reinstall: pods restarted/recovered, no data loss.)
- PVCs for stateful services (e.g. Calibre-Web) carry `argocd.argoproj.io/sync-options: Prune=false` to prevent accidental deletion

### Secrets Management
- **HashiCorp Vault**: Primary source of truth for all app secrets (running in `vault` namespace)
- **External Secrets Operator (ESO)**: Syncs Vault secrets → K8s Secrets automatically
- **ESO health alerting**: `externalsecret`/`(cluster)secretstore` `Ready=False` (Vault sealed, token expired/revoked, or a bad `remoteRef` key) alerts via Gotify — closes the silent-stale-secret gap (an unsynced Secret otherwise keeps serving its last value with no error). Rule: `k8s/helm/manifests/eso-alerts.yaml`; details under Observability › Alerting.
- Local `.env` files: Used for initial bootstrap tokens only (gitignored)

### Observability
- LGTM stack (Loki, Grafana, Tempo, Prometheus/Mimir) in `monitoring` namespace
- Grafana accessible at `grafana.meirong.dev`
- **Three signals**: Logs (Loki), Metrics (Prometheus), Traces (Tempo) — all collected via Otel Collector
- **Multi-cluster monitoring**: All telemetry carries a `cluster` label (`homelab`, `oracle-k3s`, `dgx-spark`, or `macbook`)
  - homelab: Prometheus `scrapeClasses` default relabeling adds `cluster=homelab` to all local scrape targets
  - oracle-k3s: OTel Collector pushes all metrics (node-exporter, kube-state-metrics, cloudflared, external-secrets) via `prometheusremotewrite` with `cluster=oracle-k3s`
  - **No prometheus-agent on oracle-k3s** — the single OTel Collector handles both logs, metrics, and traces
  - **dgx-spark** (2× GB10, metrics-only — not a K8s cluster): homelab Prometheus pull-scrapes node_exporter on both DGX Spark servers over **Tailscale** (job `node-exporter-dgx-spark`, static targets `100.97.87.120:9100` / `100.67.164.92:9100`, `cluster=dgx-spark`). `additionalScrapeConfigs` are injected verbatim (scrapeClasses don't relabel them), so `cluster`/`nodename` are set per-target. node_exporter is deployed from the **`nv-dgx-spark` repo** (`make node-exporter-deploy`, docker `--net=host --pid=host`); Grafana dashboard **"DGX Spark / Node Exporter"** (`k8s/helm/manifests/dgx-spark-node-dashboard.yaml`). Tailnet ACL already allows `tag:homelab → *:*`. SMART disk health (`smartctl_exporter`, :9633, job `smartctl-dgx-spark`) is deployed separately — see the **Disk health (SMART)** bullet below.
  - **macbook** (Apple Silicon laptop, metrics-only — not a K8s cluster): homelab Prometheus pull-scrapes node_exporter over **Tailscale** (job `node-exporter-macbook`, static target `100.89.15.120:9100`, `cluster=macbook`/`nodename=macbook-pro`). node_exporter is the prebuilt **`darwin-arm64` binary** (`~/.local/bin/node_exporter`, no Homebrew — the Mac can't reach GitHub, so the tarball was `scp`'d in) run by a **LaunchAgent** (`~/Library/LaunchAgents/com.prometheus.node_exporter.plist`, `--web.listen-address=:9100`, no sudo). SSH: `ssh -i ~/.ssh/vgio matthew@100.89.15.120`. Same verbatim-inject `additionalScrapeConfigs` pattern as dgx-spark. ⚠️ It's a laptop — the target flaps on sleep/logout, so expect intermittent `TargetDown` (severity `warning`) → Gotify noise; silence the `node-exporter-macbook` job in Alertmanager if it bites. Host config (node_exporter LaunchAgent + headless `pmset` power policy) is codified as Ansible in **`macbook/ansible/`** (`just node-exporter` / `just power`, idempotent); GUI-only / login-password steps (auto-login, immediate screen lock, Amphetamine "allow display sleep", Tailscale unattended, static wallpaper) are documented in its README as manual. **No SMART**: Apple Silicon's internal NVMe doesn't expose standard SMART attributes, so the MacBook has no disk-health export (filesystem usage/IO only).
- **Disk health (SMART)** (2026-06-27): the Linux bare-metal hosts run **`smartctl_exporter`** (:9633), pull-scraped by homelab Prometheus (jobs `smartctl-storage-106` / `smartctl-proxmox-pve` / `smartctl-dgx-spark`, 120s interval; `nodename` labels match the node-exporter jobs so a dashboard's `$nodename` dropdown drives node + SMART together).
  - **storage-106 + proxmox-pve** (amd64): host systemd service (GitHub binary) — `cd proxmox/ansible && just node-exporter` (one playbook installs node_exporter + smartctl_exporter on both hosts).
  - **dgx-spark ×2** (arm64): host systemd service from the **`nv-dgx-spark` repo** — `make smartctl-exporter-deploy`. **Not a container** (unlike its node-exporter): `quay.io/prometheuscommunity/smartctl-exporter` is **amd64-only** and GB10 is aarch64, so the GitHub `linux-arm64` binary is downloaded on the control machine and shipped over SSH (DGX can't reach github.com; `smartctl` is already present in DGX OS).
  - **macbook**: none (Apple Silicon doesn't expose SMART — see above).
  - Dashboards: Grafana **Hardware** folder — `storage-106` / `proxmox-pve` / `dgx-spark` carry SMART panels (health / temperature / SSD wear / power-on-hours).
  - **⚠️ metric gotcha**: disk temperature is `smartctl_device_temperature{temperature_type="current"}` (uniform across NVMe + SATA), **NOT** `smartctl_device_temperature_celsius` (no such metric in v0.14.0 — using it leaves temp panels silently empty). SSD wear: NVMe `100 - smartctl_device_percentage_used`, SATA `smartctl_attr_normalized_value{attribute_name=~"Media_Wearout_Indicator|Wear_Leveling_Count|SSD_Life_Left|Percent_Lifetime_Remain"}` (the wear bargauges carry both targets to cover either drive type).
- **Traces pipeline** (2026-03-01):
  - Apps send OTLP traces → OTel Collector (gRPC :4317 / HTTP :4318) → Tempo
  - homelab OTel Collector exports to `tempo.monitoring.svc.cluster.local:4317`
  - oracle-k3s OTel Collector exports to `100.94.186.7:31317` (Tempo NodePort via Tailscale)
  - Grafana Tempo datasource: tracesToLogs (Loki), tracesToMetrics (Prometheus), nodeGraph, serviceMap
- **App instrumentation** (env vars for any OTel SDK):
  ```
  OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.monitoring.svc:4317
  OTEL_SERVICE_NAME=<service-name>
  OTEL_RESOURCE_ATTRIBUTES=cluster=<homelab|oracle-k3s>,k8s.namespace.name=<ns>
  ```
- **Alerting** (Alertmanager → Gotify): `severity: warning|critical` rules route to Gotify (via `alertmanager-gotify-bridge`); `info`/`Watchdog` are dropped. **New `PrometheusRule`/`ServiceMonitor` resources MUST carry the label `release: kube-prometheus-stack`** or the operator's `ruleSelector`/`serviceMonitorSelector` ignores them silently. First rule: **ESO health** (`eso-alerts.yaml`, deployed via the ArgoCD `monitoring-dashboards` Application). A single rule covers both clusters since oracle ESO metrics arrive remote-written with `cluster=oracle-k3s`.
- **Dashboards 组织** (2026-06-15 整改，治理面板平铺混乱 + 跨集群指标叠加): Grafana 面板按文件夹分组，核心配置在 `k8s/helm/values/kube-prometheus-stack.yaml` 的 `grafana.sidecar.dashboards`：
  - **文件夹**: `folderAnnotation: grafana_folder` + `provider.foldersFromFilesStructure: true`。每个 dashboard ConfigMap 用注解 `grafana_folder: <名称>` 指定文件夹。当前布局: `Platform`(多集群总览, Home) / `Logs`(Loki 日志) / `Hardware`(裸金属主机: Storage-106 / Proxmox-pve / DGX Spark / MacBook + 功耗概览, 含 SMART 硬盘健康) / `Kubernetes Built-in`(chart 自带 mixin 面板, 由 `sidecar.dashboards.annotations.grafana_folder` 统一归档, 不污染顶层)。
  - **多集群选择器**: `multicluster.global.enabled: true` 让 ~21 张内置 mixin 面板出现可见的 `cluster` 下拉(`hide:0`)。指标均带 `cluster` 标签(`homelab`/`oracle-k3s`/`dgx-spark`); 关闭时这些面板会把三集群指标求和叠加，无法分析。
  - **Home 面板**: `grafana.ini` 的 `dashboards.default_home_dashboard_path: /tmp/dashboards/Platform/multicluster-overview.json`(sidecar 把带 `grafana_folder: Platform` 注解的 CM 写入该子目录, 故路径含 `Platform/`)。
  - **数据源固定与稳定 uid**: 数据源 uid 现为稳定值 `prometheus` / `loki` / `tempo`。Prometheus 类面板(multicluster / dgx)的 `datasource` 模板变量固定并隐藏(`hide:2`, 值 `prometheus`); Loki 类面板保持自动选择(集群内仅一个 Loki)。
    - **⚠️ 给已存在的数据源赋 uid 必须用 `grafana.deleteDatasources`**: 本集群 Grafana 用 NFS PVC 持久化，库里已有按 name 自动生成随机 uid 的 Loki/Tempo。直接在 provisioning 里给它们加 `uid:` 会让 Grafana 12.x 报 `Datasource provisioning error: data source not found` 并整个 **Pod CrashLoop**(2026-06-15 踩坑)。解法是 `grafana.deleteDatasources`(按 name 先删旧记录)+ `additionalDataSources`(以稳定 uid 重建)——删建同 uid，幂等。
  - **trace↔log↔metric 关联**: Tempo 数据源配 `tracesToLogsV2`→`loki` / `tracesToMetrics`→`prometheus` / `serviceMap`→`prometheus`(均为后向引用，Tempo 在文件中排在 Loki/Prometheus 之后才能解析)。**不要在 Loki 侧配指向 Tempo 的 `datasourceUid`**(前向引用，Tempo 尚未创建 → not found 崩溃); logs→trace 跳转如需要用 Grafana Correlations 单独加。`tracesToLogsV2.tags` 把 span 属性映射到 Loki 标签(`service.name`→`service_name` 等)。
  - **门户下钻**: `Platform` 总览顶部有按 **tag** 的 dashboard 链接(`kubernetes-mixin`/`node-exporter-mixin`/`loki`/`dgx-spark`) — 用 tag 而非 UID, 避免内置面板 UID 变更后失效。
  - **Tag 体系**: 自定义面板统一带 `curated`; 按信号带 `logs`/`metrics`(便于在 Dashboards 列表按 tag 过滤)。
  - 分工: folder/多集群/Home/datasource-uid 在 values(Helm, 需 `just deploy-prometheus`); `grafana_folder` 注解与 dashboard JSON 在 manifests(ArgoCD `monitoring-dashboards` App 自动同步)。
- **SLI / SLO** (2026-06-16 上线): 服务可用性 SLO 基于**一手的 Cilium Gateway Envoy L7 指标**(真实入口请求，非合成探测)，用 **Sloth** 生成规则。
  - **一手指标来源**: `cilium-envoy` DaemonSet 默认在 `:9964` 暴露 Envoy 指标(`cilium-config` `enable-metrics=true`/`external-envoy-proxy=true`)，`manifests/cilium-envoy-servicemonitor.yaml` 的 ServiceMonitor 抓取它(metricRelabelings 只留 RED 指标)。关键指标 `envoy_cluster_upstream_rq_xx{envoy_cluster_name="<gw>/<ns>_<svc>_<port>", envoy_response_code_class="2|3|4|5"}` —— 按网关路由 + 响应码。**无需改 Cilium**(数据面/ClusterMesh CA 不动)。
  - **Sloth**: `just deploy-sloth`(Helm，`values/sloth-values.yaml`，**非 ArgoCD**)。`sloth.extraLabels.release=kube-prometheus-stack` 让生成的 PrometheusRule 被 operator 的 ruleSelector 选中; `defaultSloPeriod=30d`; 关掉 commonPlugins 的 git-sync sidecar。CRD `PrometheusServiceLevel` 由 chart 安装。
  - **SLO 定义**: `manifests/slos.yaml`(一个 `PrometheusServiceLevel`，多条 SLO，ArgoCD 管理)。当前 6 个服务可用性 99%/30d(error=5xx, total=全部类)。**新增/改服务或目标**: 在 `spec.slos[]` 追加一条(`errorQuery`/`totalQuery` 用 `envoy_cluster_name=~".*/<ns>_<svc>_.*"` 正则匹配路由) + 改 `objective`，`git push` 即可。
  - **告警**: 每个 SLO 生成多窗口燃尽率告警，`pageAlert→severity:critical` / `ticketAlert→severity:warning`，经现有 Alertmanager(`severity=~"critical|warning"`)路由到 Gotify。
  - **看板**: Grafana `SLO` 文件夹 → "SLO / Service Availability"(`manifests/slo-dashboard.yaml`，错误预算剩余/燃尽率/SLI 错误率)。
  - **⚠️ 零流量盲区**: 真实流量 SLI 在服务**无人访问时为空/NaN**(`rate()` 无样本)。这是一手指标的固有特性，非故障; 燃尽率告警只在真出现 5xx 时触发。闲置服务若要稳定可用性信号，叠一层合成探测(Uptime Kuma/blackbox)兜底。
- **Deployment summary**: Only two components to deploy for observability changes:
  1. `just deploy-prometheus` (homelab kube-prometheus-stack Helm release)
  2. `kubectl --context oracle-k3s apply -f cloud/oracle/manifests/monitoring/otel-collector.yaml` + `kubectl --context oracle-k3s rollout restart daemonset/otel-collector -n monitoring` (oracle-k3s OTel Collector)
  - Dashboard ConfigMaps: auto-synced by ArgoCD after `git push` (via `monitoring-dashboards` Application)
  - **DGX Spark node_exporter** is a one-time deploy from the `nv-dgx-spark` repo (`make node-exporter-deploy`); the homelab scrape job + dashboard land via `just deploy-prometheus` + `git push`.
  - **SMART disk health (`smartctl_exporter`)** is a one-time deploy: `cd proxmox/ansible && just node-exporter` (storage-106 + pve, amd64) and `nv-dgx-spark && make smartctl-exporter-deploy` (DGX ×2, arm64); scrape jobs + dashboards then land via `just deploy-prometheus` + `git push`. Details: **Disk health (SMART)** above.
  - **ESO metrics** are a one-time enablement: homelab ServiceMonitor via `just deploy-eso` (`serviceMonitor.enabled` in `external-secrets-values.yaml`); oracle metrics Service via `just install-eso` (`--set metrics.service.enabled=true`). The `eso-alerts.yaml` PrometheusRule then reconciles via ArgoCD on `git push`.

### Services
| Service | Cluster | Namespace | URL |
|---------|---------|-----------|-----|
| Homepage | oracle-k3s | `homepage` | `home.meirong.dev` |
| IT-Tools | oracle-k3s | `personal-services` | `tool.meirong.dev` |
| Stirling-PDF | oracle-k3s | `personal-services` | `pdf.meirong.dev` |
| Squoosh | oracle-k3s | `personal-services` | `squoosh.meirong.dev` |
| Trends | oracle-k3s | `personal-services` | `trends.meirong.dev` |
| Timeslot | oracle-k3s | `personal-services` | `slot.meirong.dev` |
| Uptime Kuma | oracle-k3s | `personal-services` | `status.meirong.dev` |
| Miniflux | oracle-k3s | `rss-system` | `rss.meirong.dev` |
| KaraKeep | oracle-k3s | `rss-system` | `keep.meirong.dev` |
| Redpanda Connect | oracle-k3s | `rss-system` | Internal only |
| Calibre-Web | homelab | `personal-services` | `book.meirong.dev` |
| Gotify | homelab | `personal-services` | `notify.meirong.dev` |
| Grafana | homelab | `monitoring` | `grafana.meirong.dev` |
| HashiCorp Vault | homelab | `vault` | `vault.meirong.dev` |
| ArgoCD | homelab | `argocd` | `argocd.meirong.dev` |
| ZITADEL (SSO) | homelab | `zitadel` | `auth.meirong.dev` |
| Bifrost (LLM gateway) | homelab | `bifrost` | `llm.meirong.dev` (inference API + ZITADEL-gated admin UI) |
| Kopia Backup | homelab | `kopia` | `https://100.94.186.7:31515` (Web + CLI, Tailscale NodePort, 自签 cert) |
| PostgreSQL | oracle-k3s | `rss-system` | Internal only |

## Conventions

- **Task Runners**: Use `just` for Ansible, Helm, and Cloudflare Terraform; `make` for Proxmox Terraform.
- **Commits**: Conventional Commits format (`feat:`, `fix:`, `chore:`).
- **Helm Config**: Prefer `values/*.yaml` files; avoid inline `--set` flags.
- **New Services (GitOps flow)**:
  1. Create `manifests/<service>.yaml`
  2. Add HTTPRoute + optional ReferenceGrant to `manifests/gateway.yaml`
  3. Add filename to `argocd/applications/personal-services.yaml` include list
  4. Add subdomain to `cloudflare/terraform/terraform.tfvars`
  5. `git push` → ArgoCD auto-deploys within 3 minutes
  6. `cd cloudflare/terraform && just apply` for DNS
  7. Add the new URL to the Uptime Kuma provisioner (see below)
  - **Exception**: services needing ArgoCD Image Updater (e.g. `it-tools`) get their own Kustomize Application (`manifests/<service>/`) and `argocd/applications/<service>.yaml` instead of joining `personal-services`
- **Uptime Kuma monitors**: All monitors are defined as code in `manifests/uptime-kuma.yaml` under the `MONITORS` list in the `uptime-kuma-provisioner` ConfigMap. To add a monitor for a new service:
  1. Append an entry to `MONITORS` in the ConfigMap:
     ```python
     {"name": "My Service", "url": "https://<subdomain>.meirong.dev"},
     ```
  2. `git push` → ArgoCD PostSync hook re-runs the provisioner Job automatically
  3. The script is idempotent: existing monitors are skipped, only new ones are created
  - Admin credentials live in Vault at `secret/oracle-k3s/uptime-kuma` (keys: `admin_username`, `admin_password`), synced via ESO ExternalSecret `uptime-kuma-admin` in `personal-services` namespace
- **Oracle service secrets**: workloads running on `oracle-k3s` should use Vault paths under `secret/oracle-k3s/<service>`. Do not store Oracle-only app credentials under `secret/homelab/*`.
- **Grafana dashboards (新增/修改)**: dashboard 以 ConfigMap 形式放 `k8s/helm/manifests/`，由 ArgoCD `monitoring-dashboards` App 同步、Grafana sidecar 热加载。约定:
  1. ConfigMap 必须带 label `grafana_dashboard: "1"`、annotation `grafana_folder: <Platform|Logs|Hardware|…>`(否则掉进顶层 General)，data key 以 `.json` 结尾。
  2. dashboard JSON 的 `datasource` 模板变量固定并隐藏(`hide:2`, 值 `loki`/`prometheus`); 查询尽量用 `cluster=~"$cluster"` 以支持多集群过滤。
  3. tag 带 `curated` + 信号 tag(`logs`/`metrics`), 便于按 tag 过滤。
  4. 把文件名加入 `argocd/applications/monitoring-dashboards.yaml` 的 `directory.include` 列表。
  5. `git push` → ArgoCD 同步; 若改动落在 `grafana.sidecar`/`grafana.ini`(folder / 多集群选择器 / Home / datasource uid) 则还需 `just deploy-prometheus`。
  - 详见 Observability › **Dashboards 组织**。
- **Homepage config updates**: ArgoCD auto-syncs the ConfigMap on `git push`, but `subPath` volume mounts require a pod restart to reload — run `just update-homepage` (does `apply` + `rollout restart` in one step). Do NOT use `kubectl delete configmap` as ArgoCD will conflict.
- **HTTPRoute template**: Always include explicit `group`/`kind` in `parentRefs` and `group`/`kind`/`weight` in `backendRefs` to prevent ArgoCD OutOfSync drift caused by Gateway controller defaults.
- **ArgoCD Image Updater** (v1.1.1): Uses CRD model — create an `ImageUpdater` CR (not just annotations). Set `useAnnotations: true` in the CR to read image config from Application annotations. Use strategy `newest-build` (not `latest`, deprecated).
- **ArgoCD Application definitions** (`argocd/applications/*.yaml`): The `root` Application (App-of-Apps) watches this directory recursively, so editing any `*.yaml` here and pushing is enough — ArgoCD will reconcile within the 3-min poll. Manual `kubectl apply` is only needed for the initial `root.yaml` bootstrap, or if `root` itself is missing.
- **ArgoCD self-heal caveat**: Resources already managed by an Application (for example `gateway` managing `manifests/gateway.yaml`) must be changed in Git first. Ad-hoc `kubectl patch/apply` fixes on live resources will be reconciled away on the next sync.
- **Kustomize namespace caveat**: The global `namespace:` field in `kustomization.yaml` runs as a transformer after JSON patches, overriding them. Declare namespace explicitly in each manifest instead when resources span multiple namespaces.
- **Chinese Comments**: Permitted and used in `justfile` for clarity.
- **SSH**: User `root`, Key `~/.ssh/vgio`.

### Backup & Recovery
- **Kopia**: Backup server in `kopia` namespace (homelab), NFS repository 1Ti
- **Web UI + CLI**: `https://100.94.186.7:31515` (Tailscale NodePort 31515, 自签 cert)。kopia 服务器为 TLS
  (`--tls-generate-cert`, cert 在 config PVC 持久化 → fingerprint 稳定)。**不经 Cloudflare Tunnel/Gateway**
  ——kopia 转 TLS 后 Cilium Gateway 无法对自签后端发起 TLS（`appProtocol: https` 不触发后端 TLS），故移除了
  `backup.meirong.dev` 的 gateway 路由（A 方案；保住公网 SSO 入口的 B 方案=BackendTLSPolicy，单用户不值当）。
- **CLI 连接**: `kopia repository connect server --url=https://100.94.186.7:31515 --server-cert-fingerprint=<sha256> --override-username=admin`（gRPC direct，NOT via Tunnel，bidirectional streaming 经 Tunnel 524 超时）。密码 Vault `secret/homelab/kopia` `password`。
- **oracle 远程备份**: oracle 无 NFS、只能经此 kopia 服务器 gRPC（故服务器必须 TLS）；连接脚本 scheme 自适应（https 才传 fingerprint）。备份用户 `backup@oracle-k3s` 经 `just kopia-add-user` 注册。根因/修复见 `docs/runbooks/backup-recovery.md`。
- **Secrets**: Vault `secret/homelab/kopia` (keys: `password`, `repo-password`)
- **Data priority**: P0 (Vault, ZITADEL PG) → P1 (Calibre-Web, Miniflux PG, KaraKeep, Gotify) → P2 (monitoring data)
- **Automated backups**: 
  - homelab: CronJob in `kopia` namespace, 每天 02:00 UTC — Vault, ZITADEL PG, Calibre-Web, Gotify
  - oracle-k3s `rss-system`: CronJob 每天 03:00 UTC — Miniflux PG, KaraKeep
  - oracle-k3s `personal-services`: CronJob 每天 03:30 UTC — Uptime Kuma, Timeslot
- **Remaining gap**: 无离站副本 (所有备份在 NFS 后端同一主机)
- **Runbook**: `docs/runbooks/backup-recovery.md`
