# Crossplane 不引入：单人静态云面用不上控制面，且最大那块云面没有活的 provider

> 日期: 2026-07-07（2026-08-13 从[技术债盘点与演进路线 §三](../plans/architecture/2026-07-07-tech-debt-and-evolution.md)拆出为独立 ADR，结论未变）
> 状态: ❌ 否决（**结论仍然有效**）—— 重评条件见文末，满足其一再议
> 关联：[external-dns-adoption](external-dns-adoption.md)（子域名 toil 的实际解法）·
> [演进路线](../plans/architecture/2026-07-07-tech-debt-and-evolution.md)（2026-07-07 原始评估与当时的市场快照）

## Context

2026-07 盘点技术债时，仓库有 **5 个 Terraform root**（`cloudflare/terraform`、`proxmox/terraform`、
`tailscale/terraform`、`cloud/oracle/terraform`、`cloud/oracle/cloudflare`）state 全在笔记本本地，
且"加一个子域名要改 terraform + 改 gateway"是固定两步手工流程。

Crossplane v2（2025-08 GA，评估时 v2.3：MR/XR 全面 namespaced、composition functions、去 claim）
是当时最常被提名的答案——把云资源也变成 K8s 对象，由控制器持续 reconcile，
顺带让 IaC 获得 GitOps 语义。问题是：**它解决的是不是我们的问题**。

## Options

| 方案 | 结论 |
|---|---|
| **Crossplane 统管云面** | ❌ 否决 —— provider 现实 + 三条结构性理由，见下 |
| 只用 Crossplane 管 Cloudflare（最大云面） | ❌ 不可能：该 provider 已死（见下表） |
| 维持 Terraform + 逐个补短板 | ✅ 采纳 —— external-dns 消掉子域名 toil、R2 backend 消掉 state 单点 |

### Provider 现实（2026-07 逐一核查）

| 本仓库云面 | Provider | 状态 | 结论 |
|---|---|---|---|
| Cloudflare（最大外部 API 面） | [cdloh/provider-cloudflare](https://github.com/cdloh/provider-cloudflare) | v0.1.0，**2023-01 后无更新**，13 stars，无 v2 支持 | ❌ 死 |
| OCI | [oracle/crossplane-provider-oci](https://github.com/oracle/crossplane-provider-oci) | 官方，upjet family，[已支持 v2](https://blogs.oracle.com/cloud-infrastructure/crossplane-provider-for-oci-crossplane-v2) | ✅ 活，但本仓库仅 1 台实例 |
| Proxmox | 社区 provider | 2026-02 仍有更新，但很年轻 | ⚠️ 不敢托付 VM 生命周期 |
| Tailscale | 无像样 provider | — | ❌ |

**最大的那块云面没有活 provider**，这一条就足以否决"统管"叙事。

## Decision

**不引入 Crossplane。** 即使 provider 全都活着也不该用，理由是结构性的：

1. **问题不匹配**。Crossplane v2 的设计目标是"平台团队向多租户提供自助式基础设施 API"
   （namespaced MR、composition functions 都为此服务）。本仓库是单人、两个单节点集群、
   云资源少而静态（1 台 OCI 实例、1 份 CF zone 配置、几台 PVE VM、1 份 Tailscale ACL），
   控制器 7×24 reconcile 的收益趋近零。
2. **鸡生蛋**。Crossplane 跑在集群里，却要管"集群赖以存在"的资源（OCI 实例、PVE VM）。
   集群挂 → 修复工具跟着挂，**DR 路径反而变复杂**——与"故障域集中"那条诊断直接冲突。
3. **资源开销**。upjet 系 provider 每 family 常驻数百 MB 内存，吃的正是 homelab
   单节点最紧张的资源（宿主余量见 [homelab-host-power-thermal.md](../reference/homelab-host-power-thermal.md)）。

### 那些痛点改用什么解

| 痛点 | Crossplane 路线 | 实际采用的更轻解 | 落地 |
|---|---|---|---|
| 子域名两步走 | CF provider（已死） | **external-dns**（~20MB 控制器） | ✅ 2026-07-19/20 两集群全量，见 [ADR](external-dns-adoption.md) |
| Terraform 缺 GitOps 感 | provider-terraform 套娃 | **R2 state backend + `use_lockfile`** | 🚧 未做，ROADMAP 开放项 #2 · [方案](../plans/architecture/2026-08-03-tf-state-r2.md) |
| 学习/履历动机 | — | 在 oracle-k3s 装官方 OCI provider 管一个非关键 bucket 当沙箱，**不迁生产路径** | 未做 |

## Consequences

- 云面继续由 Terraform 管，**接受**"state 在本地、无锁"这个已知缺口，直到 R2 backend 落地（ROADMAP #2）。
- 子域名 toil 已被 external-dns 单独消除，**不需要**为它引入控制面——这是本决策成立的关键前提之一：
  痛点被逐个拆掉后，"统管"的剩余收益不足以支付上面三条成本。
- 不获得跨云统一 API / 自助式资源申请能力。单人场景下这不是损失。

## 重新评估条件（满足其一再议）

- 出现**真实多租户/自助需求**（他人向本平台申请资源）；
- Cloudflare 出现官方或活跃维护的 provider，**且** homelab 已有多节点（控制面不再是单点，
  「鸡生蛋」那条才失效）。

## 来源

[Crossplane v2 docs](https://docs.crossplane.io/latest/whats-new/) ·
[InfoQ: Crossplane v2.0](https://www.infoq.com/news/2025/08/crossplane-applications-v2/) ·
[oracle/crossplane-provider-oci](https://github.com/oracle/crossplane-provider-oci) ·
[Oracle blog: OCI provider × Crossplane v2](https://blogs.oracle.com/cloud-infrastructure/crossplane-provider-for-oci-crossplane-v2) ·
[cdloh/provider-cloudflare](https://github.com/cdloh/provider-cloudflare)
