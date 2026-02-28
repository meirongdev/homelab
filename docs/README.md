# Homelab 文档索引

> 项目总览、架构文档、运维手册。

---

## 目录结构

```
docs/
├── README.md                          # 本文件 — 文档索引
├── CONVENTIONS.md                     # 项目惯例 & AI 助手上下文（CLAUDE.md/GEMINI.md 软链目标）
├── architecture/                      # 架构设计与技术选型
│   ├── TODO.md                        # 项目阶段进度
│   ├── tailscale-network.md           # 跨集群 Tailscale 子网路由
│   ├── observability-multicluster.md  # 多集群可观测性（Loki/Prometheus 聚合）
│   ├── observability-otel-logging.md  # OTel 日志架构（filelog → Loki）
│   ├── cloudflare-tunnel-observability.md  # Cloudflare Tunnel 流量监控
│   └── argocd-image-updater.md        # ArgoCD Image Updater 工作原理
├── runbooks/                          # 运维操作手册
│   ├── kopia-backup.md                # Kopia 备份服务使用指南
│   └── dns-network-failure-recovery.md  # DNS/网络故障恢复手册
└── plans/                             # 设计方案与实施记录（按日期）
    ├── 2026-02-19-argocd-image-updater.md
    ├── 2026-02-19-dev-platform-design.md
    ├── 2026-02-20-oracle-cloud-k3s-cluster.md
    ├── 2026-02-21-calibre-web-automated-migration-design.md
    ├── 2026-02-21-calibre-web-automated-migration.md
    ├── 2026-02-21-grafana-loki-dashboards-design.md
    ├── 2026-02-21-grafana-loki-dashboards.md
    ├── 2026-02-21-otel-log-migration-design.md
    ├── 2026-02-21-otel-log-migration.md
    ├── 2026-02-21-tailscale-network-design.md
    ├── 2026-02-21-uptime-kuma-deployment.md
    ├── 2026-02-22-oracle-migration-observability.md
    ├── 2026-02-25-sso-integration.md
    └── 2026-02-28-info-pipeline-miniflux-karakeep-gotify.md
```

---

## 快速导航

### 架构
- [项目阶段进度](architecture/TODO.md)
- [跨集群网络 (Tailscale)](architecture/tailscale-network.md)
- [多集群可观测性](architecture/observability-multicluster.md)
- [OTel 日志架构](architecture/observability-otel-logging.md)
- [Cloudflare Tunnel 监控](architecture/cloudflare-tunnel-observability.md)
- [ArgoCD Image Updater](architecture/argocd-image-updater.md)

### 运维手册
- [Kopia 备份操作](runbooks/kopia-backup.md)
- [DNS/网络故障恢复](runbooks/dns-network-failure-recovery.md)

### 各模块惯例
参见 [CONVENTIONS.md](CONVENTIONS.md)（同 `CLAUDE.md` / `GEMINI.md`）

---

## 当前系统状态

| 集群 | 节点 | 状态 |
|------|------|------|
| homelab (k3s-homelab) | 10.10.10.10 / Tailscale 100.107.254.112 | 运行中 |
| oracle-k3s | 10.0.0.26 / Tailscale 100.107.166.37 | 运行中 |

| 服务 | 集群 | URL | SSO |
|------|------|-----|-----|
| Homepage | oracle-k3s | home.meirong.dev | ✅ ForwardAuth |
| Calibre-Web | homelab | book.meirong.dev | ✅ ForwardAuth |
| IT-Tools | oracle-k3s | tool.meirong.dev | ✅ ForwardAuth |
| Stirling-PDF | oracle-k3s | pdf.meirong.dev | ✅ ForwardAuth |
| Squoosh | oracle-k3s | squoosh.meirong.dev | ✅ ForwardAuth |
| Grafana | homelab | grafana.meirong.dev | ✅ ForwardAuth |
| HashiCorp Vault | homelab | vault.meirong.dev | ✅ ForwardAuth |
| ArgoCD | homelab | argocd.meirong.dev | 自带登录 |
| ZITADEL (SSO) | homelab | auth.meirong.dev | — (IdP) |
| Kopia Backup | homelab | backup.meirong.dev (Web) / 10.10.10.10:31515 (CLI) | ✅ ForwardAuth |
| Uptime Kuma | oracle-k3s | status.meirong.dev | 公开 |
| Miniflux | oracle-k3s | rss.meirong.dev | 自带登录 |
| KaraKeep | oracle-k3s | keep.meirong.dev | ✅ ForwardAuth |
| Gotify | homelab | notify.meirong.dev | ✅ ForwardAuth |
