# Plans — Archive

> **这里的东西都不存在于当前系统**：要么从未实施，要么已整体移除/取代/失效。
> 读它们只为回答「当初为什么考虑过 X，后来为什么没做/不做了」。
> **不要照着这里的任何步骤执行。**
>
> 已完成**且东西还在跑**的方案不在这里——它们解释了系统为何是现在这样，仍留在 [plans/](../README.md)。
> 完成后又被整体退役的（Cloudflare AI Gateway、ArgoCD Image Updater）**在这里**，判据是东西还在不在。
> 归档判据见 [文档组织规则 R1](../../RULES.md#r1-目录归属一篇文档只属于一类)。

## 从未实施

| 日期 | 方案 | 为什么没做 |
|------|------|-----------|
| 2026-06-06 | [Backstage 开发者门户（RHDH）](2026-06-06-backstage-developer-portal.md) | 设计与 Phase 1 计划都写完但从未执行，repo 内零痕迹；当初要解决的三件事已被更轻的东西覆盖 |
| 2026-03-20 | [Garage S3 部署设计](2026-03-20-garage-s3-design.md) | 三个动因全部消失：Kopia 2026-07-05 移除，Loki/Tempo 一直用本地存储没换 S3 |

## 已取消 / 已退役

| 日期 | 方案 | 为什么 |
|------|------|-----------|
| 2026-05-31 | [Cloudflare AI Gateway](2026-05-31-cloudflare-ai-gateway.md) | 落地后整体 `terraform state rm`。☠️ CF 边缘够不到 Tailscale `100.x` 上的模型，为此专加公网 HTTPS 暴露层不划算；改由集群内自建 [LiteLLM 网关](../../reference/litellm-gateway.md)满足 |
| 2026-02-28 | [信息管道 Miniflux→KaraKeep](2026-02-28-info-pipeline-miniflux-karakeep-gotify.md) | 落地后 2026-08-14 整体退役：实测近 7d 零 webhook 流量、SQLite 仅 564K，而 oracle 内存吃紧。Miniflux/RSSHub 保留，书签功能**无接替者** |
| 2026-03-15 | [NAS 经 Cilium External Workload 入网](2026-03-15-cilium-external-workload-nas.md) | 技术上不可行：`CiliumExternalWorkload` CRD 与 CLI 已从 Cilium 1.15+ 移除 |
| 2026-03-03 | [Sink 短链 — Cloudflare Workers](2026-03-03-sink-cloudflare-worker.md) | 2026-05-27 整体退役（commit `806950b`）：submodule + workers justfile + Homepage 条目移除；短链服务下线 |
| 2026-02-19 | [ArgoCD Image Updater](2026-02-19-argocd-image-updater.md) | 落地后 2026-08-03 退役：0 个 `ImageUpdater` CR、空转数月从未更新任何镜像。选型约束见 [decisions/argocd-image-updater.md](../../decisions/argocd-image-updater.md) |

## 已被取代

| 日期 | 方案 | 被谁取代 |
|------|------|---------|
| 2026-07-06 | [服务资源分配优化建议](2026-07-06-resource-optimization.md) | 调的那套服务在 homelab 上已不存在（calibre-web 迁 oracle、旧 LLM 网关/oauth2-proxy/image-updater 退役、VM 12→13GB），逐条数值全部失效。原则见 [reference/k8s-qos-resource-management.md](../../reference/k8s-qos-resource-management.md)，数值以 `values/` 和集群为准 |
| 2026-07-05 | [Calibre 元数据补全](2026-07-05-calibre-metadata-enrichment.md) | 「阶段三：文件 mtime 兜底」被证明有害（487 本 pubdate 写成看似真实的值，下游 readlist 只认得出 37 本）。现行做法见 [guides](../../guides/calibre-metadata-enrichment.md)，现状见 [reference](../../reference/calibre-metadata.md) |
| 2026-07-04 | [storage-106 充分利用 + 备份简化](2026-07-04-storage-106-utilization-and-backup-simplification.md) | 备份部分（Task 4-6）被 [2026-07-06 存储本地化迁移](../2026-07-06-storage-local-migration-and-backup-redesign.md)取代（Kopia → restic）；ARC 上限 4G 已于 2026-08-13 降到 2G，文中数值全过期 |
| 2026-03-07 | [homelab + oracle 最优架构方案](2026-03-07-homelab-oracle-architecture-optimization.md) | 写于 Traefik / Kopia / NFS 时代，三者现已全部退役。当前架构见 [ARCHITECTURE.md](../../ARCHITECTURE.md) |
| 2026-03-07 | [架构简化建议](2026-03-07-simplification-recommendations.md) | 核心建议 #5「oracle 留在 ArgoCD 外」已被 [2026-06-04 GitOps 纳管](../2026-06-04-oracle-k3s-argocd-gitops.md)推翻 |
| 2026-02-25 | [SSO 集成 — Traefik ForwardAuth](2026-02-25-sso-integration.md) | Traefik 与共享入口层 SSO 双双移除；现为**各应用原生 OIDC**，见 [reference/identity.md](../../reference/identity.md) |
| 2026-02-21 | [Tailscale 跨集群网络设计](2026-02-21-tailscale-network-design.md) | 网络模型此后演进多轮（节点级 /32 underlay + ClusterMesh），当前事实见 [reference/tailscale-network.md](../../reference/tailscale-network.md) |
| 2026-02-19 | [开发者平台设计](2026-02-19-dev-platform-design.md) | 部分落地（ZITADEL/ArgoCD/Vault+ESO 已有），其余明确不做（Cert-Manager、Istio、scaffold 模板）；文中多数文件路径已不存在 |

## 前提已消失

| 日期 | 方案 | 为什么失效 |
|------|------|-----------|
| 2026-03-08 | [Calibre-Web NFS 权限修复](2026-03-08-calibre-web-nfs-permissions-fix.md) | 修的是 NFS 上 root-owned 目录问题，而 NFS 已于 2026-07-11 整体退役，全部 PVC 转 `local-path` |
