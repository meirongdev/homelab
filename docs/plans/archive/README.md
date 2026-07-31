# Plans — Archive

> **这里的东西都不存在于当前系统**：要么从未实施，要么已整体移除/取代/失效。
> 读它们只为回答「当初为什么考虑过 X，后来为什么没做/不做了」。
> **不要照着这里的任何步骤执行。**
>
> 已完成的方案**不在这里**——它们解释了系统为何是现在这样，仍留在各自类别目录下。
> 归档判据见 [文档组织规则 R1](../../README.md)。

## 从未实施

| 日期 | 方案 | 为什么没做 |
|------|------|-----------|
| 2026-06-06 | [Backstage 开发者门户 — 实现计划](2026-06-06-backstage-developer-portal.md) | 计划写完但从未执行；repo 内零痕迹 |
| 2026-06-06 | [Backstage 开发者门户 — 设计](2026-06-06-backstage-developer-portal-design.md) | 同上 |
| 2026-03-20 | [Garage S3 部署设计](2026-03-20-garage-s3-design.md) | 三个动因全部消失：Kopia 2026-07-05 移除，Loki/Tempo 一直用本地存储没换 S3 |

## 已取消

| 日期 | 方案 | 为什么取消 |
|------|------|-----------|
| 2026-03-15 | [NAS 经 Cilium External Workload 入网](2026-03-15-cilium-external-workload-nas.md) | 技术上不可行：`CiliumExternalWorkload` CRD 与 CLI 已从 Cilium 1.15+ 移除 |

## 已被取代

| 日期 | 方案 | 被谁取代 |
|------|------|---------|
| 2026-05-31 | [Cloudflare AI Gateway — 实现计划](2026-05-31-cloudflare-ai-gateway.md) | 自建 [Bifrost](../apps/2026-06-07-bifrost-llm-gateway.md)。CF 边缘够不到 Tailscale `100.x` 上的模型，方案根本走不通 |
| 2026-05-31 | [Cloudflare AI Gateway — 设计](2026-05-31-cloudflare-ai-gateway-design.md) | 同上 |
| 2026-02-25 | [SSO 集成 — Traefik ForwardAuth](2026-02-25-sso-integration.md) | Traefik 与共享入口层 SSO 双双移除；现为**各应用原生 OIDC**，见 [CONVENTIONS § Identity](../../CONVENTIONS.md) |
| 2026-03-07 | [架构简化建议](2026-03-07-simplification-recommendations.md) | 核心建议 #5「oracle 留在 ArgoCD 外」已被 [2026-06-04 GitOps 纳管](../networking/2026-06-04-oracle-k3s-argocd-gitops.md)推翻 |
| 2026-02-21 | [Calibre-Web-Automated 迁移 — 设计](2026-02-21-calibre-web-automated-migration-design.md) | 已由[实现文档](../apps/2026-02-21-calibre-web-automated-migration.md)落地并取代 |
| 2026-02-21 | [Grafana Loki 面板 — 设计](2026-02-21-grafana-loki-dashboards-design.md) | 已由[实现文档](../observability/2026-02-21-grafana-loki-dashboards.md)落地并取代 |
| 2026-02-21 | [OTel 日志迁移 — 设计](2026-02-21-otel-log-migration-design.md) | 已由[实现文档](../observability/2026-02-21-otel-log-migration.md)落地并取代 |

## 前提已消失

| 日期 | 方案 | 为什么失效 |
|------|------|-----------|
| 2026-03-08 | [Calibre-Web NFS 权限修复](2026-03-08-calibre-web-nfs-permissions-fix.md) | 修的是 NFS 上 root-owned 目录问题，而 NFS 已于 2026-07-11 整体退役，全部 PVC 转 `local-path` |
