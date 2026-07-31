# Homelab Docs Portal

> Last updated: 2026-07-31
> 当前开放项: 离站备份、Terraform state → R2、DGX Spark 入编 — 见 [plans/ROADMAP.md](plans/ROADMAP.md)
> （2026-07-06 存储本地化 + 备份重建计划已于 2026-07-11 完成，转为历史记录）

## 文档分层

| 目录 | 内容 | 维护规则 |
|------|------|----------|
| `ARCHITECTURE.md` | 架构概览 (单页) | 与 reference/ 同步 |
| `reference/` | 当前生效的架构事实 (source of truth) | 架构变更必同步 |
| `guides/` | 面向任务的跨领域流程 | 非日期绑定 |
| `runbooks/` | 可直接执行的运维手册 (SOP) | 命令可执行, 可回滚 |
| `plans/` | 带日期的方案/复盘/迁移记录 (按类别) | 完成后收敛到 reference/ |
| `records/` | 故障复盘/事故报告 | 时间线和根因 |
| `decisions/` | 技术决策记录 (轻量 ADR) | 场景+选项+取舍 |
| `assets/` | 图片/架构图 | 引用链接 |

**编写规则**: 架构事实写 `reference/` 而非仅写 `plans/`；过期内容标注 `Deprecated` 并链接替代文档。
`docs/architecture/` 已废弃（内容已拆进 `reference/`+`decisions/`），只保留一张旧路径→新路径的映射表。

## 快速入口

1. 项目约定: [CONVENTIONS.md](CONVENTIONS.md) — 开发规则与 AI 上下文
2. 架构概览: [ARCHITECTURE.md](ARCHITECTURE.md) — 双集群总览
3. 参考索引: [reference/README.md](reference/README.md)
4. 运维手册: [runbooks/README.md](runbooks/README.md)
5. 计划索引: [plans/README.md](plans/README.md)
6. 决策记录: [decisions/README.md](decisions/README.md)
7. 故障复盘: [records/README.md](records/README.md)
8. 安全总览: [reference/security.md](reference/security.md) — 纵深防御 + 威胁覆盖矩阵

## 当前运行态摘要

| 集群 | CNI | 跨集群 underlay | Ingress Gateway |
|------|-----|------------------|-----------------|
| homelab | Cilium (eBPF + VXLAN) | Tailscale (Pod CIDR only) | Cilium Gateway API |
| oracle-k3s | Cilium (eBPF + VXLAN) | Tailscale (Pod CIDR only) | Cilium Gateway API |

### 服务总览

见 [CONVENTIONS.md § Services](CONVENTIONS.md#services)（唯一真相源，含集群/namespace/URL）。
集群外还有一个 **Sink 短链服务**（`s.meirong.dev`，Cloudflare Workers，源码是 `cloudflare/workers/sink/` submodule）。

SSO 状态: `HTTPRoute` 层不再承载共享 SSO，改为应用原生 OIDC（少数无认证的应用用 per-app oauth2-proxy）。
ZITADEL 仍是唯一 IdP，详见 CONVENTIONS.md 的 Identity 段与 [plans/security/2026-03-08-cilium-zitadel-sso-plan.md](plans/security/2026-03-08-cilium-zitadel-sso-plan.md)。

Oracle 集群工作负载的 Vault 路径约定: `secret/oracle-k3s/<service>`。

### 备份状态

| 数据 | 状态 |
|------|------|
| Vault / PG / sqlite | 🟢 restic 每夜备份 → 106 ZFS 仓库 (2026-07-06 恢复演练通过) |
| Calibre 书库 | 🟢 **自 2026-07-11 起纳入 restic 夜备**（书库已随存储本地化迁到 `local-path`，不再受 106 的 ZFS raidz1/sanoid 保护，所以必须进 restic） |
| 整机 VM | 🟢 PVE 每周 vzdump (VM 100 → 106 `backups`, keep-last=3) |
| 离站副本 | 🔴 待做 — 见 [plans/ROADMAP.md](plans/ROADMAP.md) Phase 5 |

## 推荐阅读顺序

1. [reference/tailscale-network.md](reference/tailscale-network.md) — 跨集群网络
2. [reference/observability-multicluster.md](reference/observability-multicluster.md) — 可观测方案
3. [reference/k8s-qos-resource-management.md](reference/k8s-qos-resource-management.md) — 资源管理
4. [runbooks/backup-recovery.md](runbooks/backup-recovery.md) — 备份与恢复
5. [plans/networking/2026-03-07-homelab-oracle-architecture-optimization.md](plans/networking/2026-03-07-homelab-oracle-architecture-optimization.md) — 架构优化方案
