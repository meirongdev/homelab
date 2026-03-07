# Plans And Records

> Time-ordered implementation plans, migrations, and incident retrospectives.
> Last updated: 2026-03-07

## How To Use This Folder

1. 新方案: 新建 `YYYY-MM-DD-<topic>.md`
2. 状态追踪: 在文首维护 `状态` 与 `结论`
3. 收敛完成后: 将稳定结论回写到 `../architecture/`

## Plan Status Summary

### Active (2026-03)

| Plan | Status |
|------|--------|
| [2026-03-07 架构优化方案](2026-03-07-homelab-oracle-architecture-optimization.md) | ✅ Approved |
| [2026-03-07 Cilium 迁移修复](2026-03-07-post-cilium-fix-plan.md) | ✅ Complete |
| [2026-03-06 Cilium 安装](2026-03-06-cilium-mesh-installation.md) | ✅ Complete |

### Completed (2026-02 ~ 2026-03)

| Plan | Date | Summary |
|------|------|---------|
| [Sink 短链](2026-03-03-sink-cloudflare-worker.md) | 03-03 | Cloudflare Workers URL shortener |
| [Timeslot 部署](2026-03-02-timeslot-deployment.md) | 03-02 | 日历可见性服务 oracle-k3s |
| [OTel Tracing](2026-03-01-otel-tracing-improvement.md) | 03-01 | 双集群 traces pipeline |
| [信息管道](2026-02-28-info-pipeline-miniflux-karakeep-gotify.md) | 02-28 | Miniflux → KaraKeep → Gotify |
| [SSO 集成](2026-02-25-sso-integration.md) | 02-25 | ZITADEL + oauth2-proxy |
| [Oracle 可观测](2026-02-22-oracle-migration-observability.md) | 02-22 | OTel Collector → homelab |
| [Uptime Kuma](2026-02-21-uptime-kuma-deployment.md) | 02-21 | 外部健康监控 |
| [Tailscale 网络](2026-02-21-tailscale-network-design.md) | 02-21 | 跨集群路由设计 |
| [OTel 日志迁移](2026-02-21-otel-log-migration.md) | 02-21 | Promtail → OTel Collector |
| [Grafana Dashboards](2026-02-21-grafana-loki-dashboards.md) | 02-21 | Loki dashboard GitOps |
| [Calibre-Web 迁移](2026-02-21-calibre-web-automated-migration.md) | 02-21 | K3s + log-exporter sidecar |
| [Oracle K3s](2026-02-20-oracle-cloud-k3s-cluster.md) | 02-20 | Oracle Cloud Free Tier |
| [Image Updater](2026-02-19-argocd-image-updater.md) | 02-19 | CRD model v1.1.0 |
| [Dev Platform](2026-02-19-dev-platform-design.md) | 02-19 | 平台设计蓝图 |

### Archived (Design Docs)

以下 design 文档是对应 implementation 文档的前期设计，结论已合并到 architecture/ 或 implementation 文档中:

- `2026-02-21-calibre-web-automated-migration-design.md` → 见 `2026-02-21-calibre-web-automated-migration.md`
- `2026-02-21-grafana-loki-dashboards-design.md` → 见 `2026-02-21-grafana-loki-dashboards.md`
- `2026-02-21-otel-log-migration-design.md` → 见 `2026-02-21-otel-log-migration.md`
