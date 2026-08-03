# Plans — Architecture

> 舰队级架构诊断与演进建议。**全部是写作当日的快照，不是现状**——
> 这些文档 2026-07-31 从 `reference/` 迁入，因为 `reference/` 只放常青事实。
> 落地情况见 [ROADMAP](../../ROADMAP.md)。

| 日期 | 方案 | 状态 |
|------|------|------|
| 2026-08-02 | [homelab → oracle 负载迁移](2026-08-02-homelab-to-oracle-workload-migration.md)（Loki/Tempo + ArgoCD + calibre 全部迁完，含残余清扫；**推翻 2026-07-04 的两条结论**。可复用的操作 SOP 已提炼为 [runbook](../../runbooks/stateful-service-cross-cluster-migration.md)） | ✅ 完成（Vault 仍为剩余候选） |
| 2026-07-07 | [技术债盘点与演进路线](2026-07-07-tech-debt-and-evolution.md)（含 **Crossplane 不引入**结论） | ⚠️ 部分落地 |
| 2026-07-06 | [服务资源分配优化建议](2026-07-06-resource-optimization.md) | ⚠️ 部分落地 |
| 2026-07-04 | [舰队机器与集群架构优化](2026-07-04-fleet-architecture-optimization.md)（ROADMAP 的 `P0-x`/`P1-x`/`P2-x` 编号出自这里） | ⚠️ 部分落地 |

> 已归档（从未实施 / 已取消 / 已被取代 / 前提消失）的方案见 [plans/archive/](../archive/README.md)。
