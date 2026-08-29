# Runbooks

> 可直接执行的运维操作手册（SOP）。**只收针对本 homelab 基础设施、可照抄执行的流程。**
> Last updated: 2026-08-29

| Runbook | 什么时候用 |
|---------|-----------|
| [backup-recovery.md](backup-recovery.md) | 备份运维与恢复（数据分级、restore SOP、检查清单） |
| [open-notebook-ingest.md](open-notebook-ingest.md) | 把 Calibre 书库的某批书灌进 Open Notebook（按需摄取，非全量同步） |
| [multica-install.md](multica-install.md) | 安装/重建 Multica（AI 编码 agent 协作台）：Vault 先行、AppProject 手工 apply、首次引导两阶段、M2 daemon 走 PAT |
| [readlist-bootstrap.md](readlist-bootstrap.md) | readlist 空库引导（首次上线 / `readlist-data` 丢失后）：snapshot→score→核对→ingest→score |
| [dns-network-failure-recovery.md](dns-network-failure-recovery.md) | 断网/路由器重启后服务不自愈、隧道 530、kubectl 不通 |
| [security-hardening.md](security-hardening.md) | 安全组件部署 / 验证 / 回滚 |
| [cilium-gateway-cutover.md](cilium-gateway-cutover.md) | 重新部署或整体验证入口链路（Tunnel → Gateway → Service） |
| [homelab-rebuild-ubuntu-24-04.md](homelab-rebuild-ubuntu-24-04.md) | 节点重建；Cilium 数据面变更后节点不稳定 |
| [proxmox-host-upgrade.md](proxmox-host-upgrade.md) | 升 `pve` / `storage-106` 宿主的内核与 PVE 本体；含「两台都没配 Proxmox 源」的根因、☠️ 顺序反了会装上 `zfs-dkms` 的陷阱、停机面与 GRUB 回滚 |
| [oracle-k3s-rebuild.md](oracle-k3s-rebuild.md) | oracle-k3s 节点不可恢复时重建（OCI 终止/OS 损坏）；含数据盘点、ArgoCD 控制面重装、ClusterMesh 重连 |
| [argocd-control-plane-on-oracle.md](argocd-control-plane-on-oracle.md) | 重装/升级 ArgoCD、集群凭据过期、回滚控制面、`argocd.meirong.dev` 跨集群搬家 |
| [stateful-service-cross-cluster-migration.md](stateful-service-cross-cluster-migration.md) | 把带 PVC 的服务在 homelab ↔ oracle 之间搬家（两遍 rsync、域名两步切换、退役与残余清扫） |
| [oracle-k3s-shape-downsize.md](oracle-k3s-shape-downsize.md) | 改 A1 shape（`ocpus`/`memory_gb`）；含 requests 右尺寸前置、hugepages 回收、system-reserved、停机面与验证 |
| [krr-report-triage.md](krr-report-triage.md) | 周一收到 KRR 报告后怎么读怎么处理：五类分诊、地板值与空结果两类误读、改哪里怎么下发、改完怎么验证生效 |
| [suspicious-traffic-investigation.md](suspicious-traffic-investigation.md) | cf-analytics 面板出现认不出来的流量：按 UA/IP 下钻到 path 与状态码、判读四条经验、加白名单还是加 WAF 规则 |

> 故障复盘见 [records/](../records/README.md)；非基础设施的工具流程见 [guides/](../guides/README.md)
> （`hermes-agent.md` 于 2026-07-31 按此规则迁去 guides/）。

## Runbook Standard

1. **触发条件 + 成功判定**写在文首
2. **命令可执行**：完整命令、执行目录、`--context`
3. **可回滚**：变更类必须给回滚路径；恢复类（本身即回滚）注明豁免
4. **事后复盘**：把时间线与根因写进 [`records/`](../records/README.md)
