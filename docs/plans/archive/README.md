# Plans — Archive

> **这里的东西都不存在于当前系统**：要么从未实施，要么已整体移除/取代/失效。
> 读它们只为回答「当初为什么考虑过 X，后来为什么没做/不做了」。
> **不要照着这里的任何步骤执行。**
>
> 已完成**且东西还在跑**的方案不在这里——它们解释了系统为何是现在这样，仍留在各自类别目录下。
> 完成后又被整体退役的（Bifrost、ArgoCD Image Updater）**在这里**，判据是东西还在不在。
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
| 2026-06-07 | [Bifrost LLM 网关](2026-06-07-bifrost-llm-gateway.md) | 落地后 2026-08-08 整体退役：`bifrost` ArgoCD App（网关 + oauth2-proxy 管理面 + dgx-proxy）全删，`llm.meirong.dev` 下线。**接替者尚未落地**——[LiteLLM 迁移](../apps/2026-08-01-litellm-gateway-migration.md)仍是 📐 设计，当前消费方（jobs-sg / Open Notebook）直连 DGX vLLM |
| 2026-03-15 | [NAS 经 Cilium External Workload 入网](2026-03-15-cilium-external-workload-nas.md) | 技术上不可行：`CiliumExternalWorkload` CRD 与 CLI 已从 Cilium 1.15+ 移除 |
| 2026-03-03 | [Sink 短链 — Cloudflare Workers](2026-03-03-sink-cloudflare-worker.md) | 2026-05-27 整体退役（commit `806950b`）：submodule + workers justfile + Homepage 条目移除；短链服务下线 |
| 2026-02-19 | [ArgoCD Image Updater](2026-02-19-argocd-image-updater.md) | 落地后 2026-08-03 退役：0 个 `ImageUpdater` CR、空转数月从未更新任何镜像，App + values + oracle 侧旧注解一并移除。选型约束见 [decisions/argocd-image-updater.md](../../decisions/argocd-image-updater.md) |

## 已被取代

| 日期 | 方案 | 被谁取代 |
|------|------|---------|
| 2026-07-06 | [服务资源分配优化建议](2026-07-06-resource-optimization.md) | 调的那套服务在 homelab 上已不存在（calibre-web 迁 oracle、Bifrost/oauth2-proxy/image-updater 退役、VM 12→13GB），逐条数值全部失效。原则见 [reference/k8s-qos-resource-management.md](../../reference/k8s-qos-resource-management.md)，数值以 `values/` 和集群为准 |
| 2026-07-05 | [Calibre 元数据补全](2026-07-05-calibre-metadata-enrichment.md) | 「阶段三：文件 mtime 兜底」被证明有害（487 本 pubdate 被写成看似真实的值，下游 readlist 只认得出 37 本）。现行做法见 [guides/calibre-metadata-enrichment.md](../../guides/calibre-metadata-enrichment.md)（怎么做）与 [reference/calibre-metadata.md](../../reference/calibre-metadata.md)（现状） |
| 2026-05-31 | [Cloudflare AI Gateway — 实现计划](2026-05-31-cloudflare-ai-gateway.md) | 自建 [Bifrost](2026-06-07-bifrost-llm-gateway.md)（其本身也已于 2026-08-08 退役，见上）。CF 边缘够不到 Tailscale `100.x` 上的模型，方案根本走不通 |
| 2026-05-31 | [Cloudflare AI Gateway — 设计](2026-05-31-cloudflare-ai-gateway-design.md) | 同上 |
| 2026-02-25 | [SSO 集成 — Traefik ForwardAuth](2026-02-25-sso-integration.md) | Traefik 与共享入口层 SSO 双双移除；现为**各应用原生 OIDC**，见 [reference/identity.md](../../reference/identity.md) |
| 2026-03-07 | [架构简化建议](2026-03-07-simplification-recommendations.md) | 核心建议 #5「oracle 留在 ArgoCD 外」已被 [2026-06-04 GitOps 纳管](../networking/2026-06-04-oracle-k3s-argocd-gitops.md)推翻 |
| 2026-02-21 | [Calibre-Web-Automated 迁移 — 设计](2026-02-21-calibre-web-automated-migration-design.md) | 已由[实现文档](../apps/2026-02-21-calibre-web-automated-migration.md)落地并取代 |
| 2026-02-21 | [Grafana Loki 面板 — 设计](2026-02-21-grafana-loki-dashboards-design.md) | 已由[实现文档](../observability/2026-02-21-grafana-loki-dashboards.md)落地并取代 |
| 2026-02-21 | [OTel 日志迁移 — 设计](2026-02-21-otel-log-migration-design.md) | 已由[实现文档](../observability/2026-02-21-otel-log-migration.md)落地并取代 |

## 前提已消失

| 日期 | 方案 | 为什么失效 |
|------|------|-----------|
| 2026-03-08 | [Calibre-Web NFS 权限修复](2026-03-08-calibre-web-nfs-permissions-fix.md) | 修的是 NFS 上 root-owned 目录问题，而 NFS 已于 2026-07-11 整体退役，全部 PVC 转 `local-path` |
