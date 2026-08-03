# Runbooks

> 可直接执行的运维操作手册（SOP）。**只收针对本 homelab 基础设施、可照抄执行的流程。**
> Last updated: 2026-07-31

| Runbook | 什么时候用 |
|---------|-----------|
| [backup-recovery.md](backup-recovery.md) | 备份运维与恢复（数据分级、restore SOP、检查清单） |
| [open-notebook-ingest.md](open-notebook-ingest.md) | 把 Calibre 书库的某批书灌进 Open Notebook（按需摄取，非全量同步） |
| [dns-network-failure-recovery.md](dns-network-failure-recovery.md) | 断网/路由器重启后服务不自愈、隧道 530、kubectl 不通 |
| [security-hardening.md](security-hardening.md) | 安全组件部署 / 验证 / 回滚 |
| [cilium-gateway-cutover.md](cilium-gateway-cutover.md) | 重新部署或整体验证入口链路（Tunnel → Gateway → Service） |
| [homelab-rebuild-ubuntu-24-04.md](homelab-rebuild-ubuntu-24-04.md) | 节点重建；Cilium 数据面变更后节点不稳定 |
| [argocd-control-plane-on-oracle.md](argocd-control-plane-on-oracle.md) | 重装/升级 ArgoCD、集群凭据过期、回滚控制面、`argocd.meirong.dev` 跨集群搬家 |
| [stateful-service-cross-cluster-migration.md](stateful-service-cross-cluster-migration.md) | 把带 PVC 的服务在 homelab ↔ oracle 之间搬家（两遍 rsync、域名两步切换、退役与残余清扫） |

> 故障复盘见 [records/](../records/README.md)；非基础设施的工具流程见 [guides/](../guides/README.md)
> （`hermes-agent.md` 于 2026-07-31 按此规则迁去 guides/）。

## Runbook Standard

1. **触发条件 + 成功判定**写在文首
2. **命令可执行**：完整命令、执行目录、`--context`
3. **可回滚**：变更类必须给回滚路径；恢复类（本身即回滚）注明豁免
4. **事后复盘**：把时间线与根因写进 [`records/`](../records/README.md)
