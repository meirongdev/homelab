# Homelab Docs Portal

> Last updated: 2026-03-07
> Scope: 双集群 homelab（homelab + oracle-k3s）的架构、运维与实施记录。

## 文档分层

1. `architecture/`: 当前生效的架构事实（source of truth）
2. `runbooks/`: 可直接执行的运维手册（SOP）
3. `plans/`: 带日期的方案/复盘/迁移记录（历史上下文）

编写规则：

1. 架构事实写进 `architecture/`，不要只写在 `plans/`
2. 临时决策与排障过程写进 `plans/`
3. 命令步骤必须可执行，避免"思路型描述"
4. 过期内容在原文标注 `Deprecated` 并链接替代文档

## 快速入口

1. 项目约定: [CONVENTIONS.md](CONVENTIONS.md)
2. 架构索引: [architecture/README.md](architecture/README.md)
3. 运维索引: [runbooks/README.md](runbooks/README.md)
4. 计划索引: [plans/README.md](plans/README.md)

## 当前运行态摘要

| 集群 | CNI | 跨集群 underlay | Ingress Gateway |
|------|-----|------------------|-----------------|
| homelab | Cilium (eBPF + VXLAN) | Tailscale (Pod CIDR only) | Cilium Gateway API |
| oracle-k3s | Cilium (eBPF + VXLAN) | Tailscale (Pod CIDR only) | Cilium Gateway API |

### 服务总览

| 服务 | 集群 | URL | 认证 |
|------|------|-----|------|
| Calibre-Web | homelab | book.meirong.dev | SSO |
| Gotify | homelab | notify.meirong.dev | SSO |
| Grafana | homelab | grafana.meirong.dev | SSO |
| Vault | homelab | vault.meirong.dev | SSO |
| ArgoCD | homelab | argocd.meirong.dev | 内置 |
| ZITADEL | homelab | auth.meirong.dev | OIDC |
| Kopia | homelab | backup.meirong.dev | SSO + Basic Auth |
| Homepage | oracle-k3s | home.meirong.dev | 公开 |
| IT-Tools | oracle-k3s | tool.meirong.dev | 公开 |
| Stirling-PDF | oracle-k3s | pdf.meirong.dev | 公开 |
| Squoosh | oracle-k3s | squoosh.meirong.dev | 公开 |
| Miniflux | oracle-k3s | rss.meirong.dev | 内置 |
| KaraKeep | oracle-k3s | keep.meirong.dev | SSO |
| Timeslot | oracle-k3s | slot.meirong.dev | Basic Auth |
| Uptime Kuma | oracle-k3s | status.meirong.dev | 公开 |
| Sink (短链) | Cloudflare Workers | s.meirong.dev | N/A |

### 备份状态

| 数据 | 备份方式 | 状态 |
|------|---------|------|
| Vault PVC | Kopia CronJob | ✅ 每日自动快照 |
| ZITADEL PostgreSQL | Kopia CronJob | ✅ 每日自动快照 |
| Calibre-Web / Gotify | Kopia CronJob | ✅ 周期快照 |
| oracle-k3s 应用数据 | pg_dump + Kopia CronJob | ✅ 已接入 |

详见 [备份与恢复方案](plans/2026-03-07-homelab-oracle-architecture-optimization.md#2-应用数据分类与备份策略)

## 推荐阅读顺序

1. [architecture/tailscale-network.md](architecture/tailscale-network.md) — 跨集群网络
2. [architecture/observability-multicluster.md](architecture/observability-multicluster.md) — 可观测方案
3. [architecture/k8s-qos-resource-management.md](architecture/k8s-qos-resource-management.md) — 资源管理
4. [runbooks/kopia-backup.md](runbooks/kopia-backup.md) — 备份操作
5. [plans/2026-03-07-homelab-oracle-architecture-optimization.md](plans/2026-03-07-homelab-oracle-architecture-optimization.md) — 架构优化方案
