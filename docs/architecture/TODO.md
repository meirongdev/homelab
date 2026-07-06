# Homelab Project TODO

> Last updated: 2026-07-06
> 当前主线: [2026-07-06 存储本地化迁移 + 备份体系重建](../plans/2026-07-06-storage-local-migration-and-backup-redesign.md)

## Phase 1: Foundation ✅

- [x] Terraform setup for VM provisioning (Proxmox)
- [x] Ansible playbooks for K3s installation (On-prem)
- [x] Helm-based application deployment
- [x] Observability stack (Prometheus, Grafana, Loki, Tempo)
- [x] OTel Collector DaemonSet — 替换 Promtail，OTLP HTTP → Loki 3.x
- [x] Grafana Loki Dashboards — Overview / Pod Browser / Errors / Cluster Search（GitOps via ArgoCD）
- [x] log-exporter sidecar pattern — 支持文件日志应用（Calibre-Web 已实施）
- [x] Oracle Cloud Free Tier K3s Cluster (Terraform + Ansible)
- [x] OTel Tracing — 双集群 OTLP traces → Tempo 全链路追踪

## Phase 2: Security & GitOps ✅

- [x] Deploy HashiCorp Vault to Kubernetes (Helm, `vault` namespace)
- [x] Initialize and unseal Vault
- [x] Configure Kubernetes authentication for ESO
- [x] Install External Secrets Operator (ESO)
- [x] Create ClusterSecretStore (`vault-backend`)
- [x] Migrate all app secrets to Vault
- [x] GitOps with ArgoCD (auto-sync + selfHeal for all managed apps)
- [x] ArgoCD Image Updater — automated `it-tools` image tracking via GHCR

## Phase 3: Multi-Cloud & Security ✅

- [x] Cross-Cluster Networking — Tailscale 双向 Pod CIDR 路由 (homelab ↔ oracle-k3s)
- [x] Identity simplification — 保留 ZITADEL 身份服务，移除共享入口层 SSO
- [x] 信息管道 — Miniflux → Redpanda Connect → KaraKeep → Gotify → Telegram
- [x] Cloudflare WAF — Zone 级 WAF 防护 (自定义规则、速率限制、安全设置)
- [x] Uptime Kuma — 外部健康监控 (status.meirong.dev)
- [x] Cilium CNI — homelab K3s 集群从 Flannel 迁移到 Cilium

## Phase 4: Reliability & Backup 📋 (Current — 主线 = 2026-07-06 计划)

- [x] ~~**Kopia 自动快照**~~: ❌ Kopia 已于 2026-07-05 整体移除（server + CronJob + PVC + Vault secret），全系统当前**零备份**
- [x] **备份体系重建（restic）**: ✅ 2026-07-06 双集群 CronJob 逻辑 dump（Vault raft snapshot / pg_dump(all) / sqlite）→ 106 ZFS 加密仓库 `881fb124bf`，上线
- [x] **恢复演练**: ✅ 2026-07-06 从仓库恢复 Vault snapshot + 两 PG dump + sqlite integrity_check 全通过（2026-07-06 计划 Phase 1 DoD）
- [ ] **存储本地化迁移**: homelab fsync/sqlite/PG 类 PVC 从 `nfs-client` 迁 `local-path`（备份已就绪）。见 2026-07-06 计划 Phase 2
- [ ] **离站备份**: restic 仓库 → 云（OCI always-free/B2），当前仅本地副本。见 2026-07-06 计划 Phase 5
- [ ] **dead-man's switch**: Alertmanager Watchdog（当前 `receiver:"null"`）→ oracle Uptime Kuma push monitor → Gotify(oracle)→Telegram
- [ ] **zpool/SMART 告警**: 补 PrometheusRule（当前仅有看板，无告警）
- [x] **Loki 日志保留**: ✅ 2026-03-19 compactor + retention 168h 已启用
- [x] **Alertmanager**: ✅ severity=warning|critical → gotify-bridge → Gotify → Telegram（生产运行）
- [x] **oracle-k3s Cilium**: 从 Flannel 迁移到 Cilium，统一双集群数据面
- [x] **Uptime Kuma SSO 修复**: maxredirects=0 + accepted_statuscodes 300-399
- [x] **homelab Ubuntu 24.04 重建**: ✅ 2026-03-08 重建完成，K3s v1.34.5+k3s1 + Cilium 1.19.1
- [x] **homelab Cilium Gateway 恢复**: ✅ kube-proxy replacement + Gateway API 验证通过
- [x] **oracle-k3s GitOps 纳管**: ✅ 2026-06-04 hub-and-spoke ArgoCD 经 Tailscale 纳管 oracle-k3s manifests，auto-sync/selfHeal/prune 启用

## Phase 5: Production Hardening 🎯 (Future)

- [x] Cilium ClusterMesh 启用 (跨集群 Service 发现) ✅ 2026-03-08 双集群 connected
- [x] Gateway 标准化: 当前架构以 Cilium Gateway API 为统一入口
- [x] **集群内部安全加固** ✅ 2026-06 已部署: PSA + Kyverno(Audit) + Trivy + kube-bench + 节点 CIS(待重启)
- [x] **运行时检测** ✅ 2026-06 已部署: Tetragon(homelab) + Falco(oracle)
- [ ] **服务重定位（脱离 homelab 故障域）**: Gotify + ZITADEL → oracle-k3s。见 2026-07-06 计划 Phase 3
- [ ] **离站备份 (OCI always-free / B2)**: restic 仓库 → 云（rclone/`restic copy`）。见 2026-07-06 计划 Phase 5（later）
- [ ] **DGX Spark 入编**: 推理服务 IaC + GPU 指标(dcgm) + Bifrost 双机 fallback + SLO。见母文档 P1-5
- [ ] **恢复演练自动化**: 月度 CronJob 校验 restic restore。见母文档 P2-8
- [ ] Vault Dynamic Secrets (PostgreSQL 动态凭据) — 低优先，规模不需要
- [ ] Cloudflare Pro WAF (Managed Ruleset + OWASP CRS) — 可选
- [ ] Renovate (chart/image 版本自动 PR)；MacBook `TargetDown` 静默规则 — 母文档 P2

### ❌ 已划掉（防过度工程，见母文档"明确不建议做的"）
- ~~Cert-Manager (Let's Encrypt + DNS-01)~~ — TLS 在 Cloudflare 边缘终结、集群内 HTTP，无内网直连 TLS 需求 → 纯负担
- ~~Vault HA / auto-unseal~~ — 单节点无 HA 意义；sealed 已被 ESO 告警覆盖 + 恢复路径已文档化，transit auto-unseal 要再养一个 Vault，不值

---

## Task Roadmap (By Effort)

### 🟢 Quick Wins

- [x] Uptime Kuma SSO 监控修复 (maxredirects config)
- [x] Loki retention 配置 (values.yaml update) ✅ 2026-03-19
- [x] Grafana 旧 dashboard 清理 ✅ 2026-03-19 禁用 AIX/Darwin/proxy dashboard

### 🟡 Medium Effort

- [x] restic 备份 CronJob（双集群，取代已移除的 Kopia）✅ 2026-07-06
- [ ] 存储本地化迁移（nfs-client → local-path，备份就绪后）
- [ ] dead-man's switch（Watchdog → oracle Uptime Kuma push）
- [x] Alertmanager → Gotify 通知模板 ✅
- [x] oracle-k3s Cilium 迁移

### 🔴 High Effort

- [x] Cilium ClusterMesh connect + failover validation ✅ 2026-03-08
- [x] homelab Cilium Gateway 恢复后双集群统一 cutover 验证 ✅ 2026-03-08
- [ ] Gotify + ZITADEL 迁 oracle-k3s（脱离 homelab 故障域）
- [ ] DGX Spark 入编（IaC + GPU 指标 + Bifrost fallback + SLO）

### ❌ 已取消

- ~~Cilium External Workloads — NAS 纳入 Cilium 网络~~ (取消，2026-03-19)
  - 原因：`CiliumExternalWorkload` CRD 及 `cilium external-workloads` CLI 命令已从 Cilium 1.15+ Helm chart 中移除，Cilium 1.19.1 不再支持此功能。
  - 若需限制 NFS 访问，可改用 `CiliumNetworkPolicy` + `fromCIDR: 192.168.50.106/32` 的轻量方案，无需在 NAS 上安装 Cilium agent。
