# Homelab Project TODO

> Last updated: 2026-03-08

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

## Phase 4: Reliability & Backup 📋 (Current)

- [x] **Kopia 自动快照**: P0 数据 (Vault / ZITADEL PG) 每日快照 + P1 数据每周快照
- [x] **oracle-k3s 备份接入**: pg_dump CronJob + SQLite 文件级快照 (Miniflux / KaraKeep / Timeslot)
- [ ] **恢复演练**: 验证 Vault 恢复 SOP
- [ ] **Loki 日志保留**: 配置 compaction 与 retention policies
- [ ] **Alertmanager**: 告警规则 → Gotify → Telegram 通知链路
- [x] **oracle-k3s Cilium**: 从 Flannel 迁移到 Cilium，统一双集群数据面
- [x] **Uptime Kuma SSO 修复**: maxredirects=0 + accepted_statuscodes 300-399
- [x] **homelab Ubuntu 24.04 重建**: ✅ 2026-03-08 重建完成，K3s v1.34.5+k3s1 + Cilium 1.19.1
- [x] **homelab Cilium Gateway 恢复**: ✅ kube-proxy replacement + Gateway API 验证通过

## Phase 5: Production Hardening 🎯 (Future)

- [x] Cilium ClusterMesh 启用 (跨集群 Service 发现) ✅ 2026-03-08 双集群 connected
- [x] Gateway 标准化: 当前架构以 Cilium Gateway API 为统一入口
- [ ] Cert-Manager (Let's Encrypt + Cloudflare DNS-01)
- [ ] Vault Dynamic Secrets (PostgreSQL 动态凭据)
- [ ] 离站备份 (Backblaze B2 / S3)
- [ ] Cloudflare Pro WAF (Managed Ruleset + OWASP CRS)

---

## Task Roadmap (By Effort)

### 🟢 Quick Wins

- [x] Uptime Kuma SSO 监控修复 (maxredirects config)
- [ ] Loki retention 配置 (values.yaml update)
- [ ] Grafana 旧 dashboard 清理

### 🟡 Medium Effort

- [x] Kopia 自动快照 CronJob (K8s manifest)
- [ ] Alertmanager → Gotify 通知模板
- [ ] Cert-Manager 安装 + Let's Encrypt ClusterIssuer
- [x] oracle-k3s Cilium 迁移

### 🔴 High Effort

- [x] Cilium ClusterMesh connect + failover validation ✅ 2026-03-08
- [x] homelab Cilium Gateway 恢复后双集群统一 cutover 验证 ✅ 2026-03-08
- [ ] Vault HA + auto-unseal
