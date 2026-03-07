# Homelab Docs Portal

> Last updated: 2026-03-07
> Scope: 双集群 homelab（homelab + oracle-k3s）的架构、运维与实施记录。

## 文档站点标准

为避免信息漂移，`docs/` 采用固定分层：

1. `architecture/`: 当前生效的架构事实（source of truth）
2. `runbooks/`: 可直接执行的运维手册（SOP）
3. `plans/`: 带日期的方案/复盘/迁移记录（历史上下文）

编写规则：

1. 架构事实写进 `architecture/`，不要只写在 `plans/`
2. 临时决策与排障过程写进 `plans/`
3. 命令步骤必须可执行，避免“思路型描述”
4. 过期内容在原文标注 `Deprecated` 并链接替代文档

## 快速入口

1. 项目约定: [CONVENTIONS.md](CONVENTIONS.md)
2. 架构索引: [architecture/README.md](architecture/README.md)
3. 运维索引: [runbooks/README.md](runbooks/README.md)
4. 计划索引: [plans/README.md](plans/README.md)

## 当前运行态摘要

| 集群 | CNI | 跨集群 underlay | Ingress Gateway |
|------|-----|------------------|-----------------|
| homelab | Cilium | Tailscale (Pod CIDR only) | Traefik Gateway API |
| oracle-k3s | Flannel | Tailscale (Pod CIDR only) | Traefik Gateway API |

| 关键外部入口 | 当前行为 |
|-------------|----------|
| `auth.meirong.dev` | ZITADEL 登录链路（302/200） |
| `book/grafana/vault/notify/backup.meirong.dev` | SSO 保护（默认 3xx） |
| `argocd.meirong.dev` | 自带登录（200） |
| `status/home/tool/rss.meirong.dev` | 公开访问（200） |

## 推荐阅读顺序

1. [architecture/tailscale-network.md](architecture/tailscale-network.md)
2. [architecture/observability-multicluster.md](architecture/observability-multicluster.md)
3. [plans/2026-03-07-post-cilium-fix-plan.md](plans/2026-03-07-post-cilium-fix-plan.md)
4. [plans/2026-03-07-homelab-oracle-architecture-optimization.md](plans/2026-03-07-homelab-oracle-architecture-optimization.md)
