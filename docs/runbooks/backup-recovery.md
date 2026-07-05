# Backup & Recovery Runbook

> Last updated: 2026-07-05

## Status

**Kopia 已移除（2026-07-05）。** 备份方案待重新设计。详见 `docs/plans/2026-07-04-storage-106-utilization-and-backup-simplification.md` 的 Option A（restic）或后续简化方案。

### 移除前历史

- Kopia server（homelab `kopia` namespace）及所有备份 CronJob（包括 oracle-k3s 侧）已彻底清理
- Kopia PVC 数据（~20GB）已从 storage-106 NFS 删除
- Vault `secret/homelab/kopia` 已删除

### 当前保护状态

| 服务 | 集群 | 备份状态 |
|------|------|---------|
| Vault | homelab | ❌ 无离站备份 |
| ZITADEL PostgreSQL | homelab | ❌ 无离站备份 |
| Calibre-Web | homelab | ❌ 无离站备份 |
| Gotify | homelab | ❌ 无离站备份 |
| Miniflux PostgreSQL | oracle-k3s | ❌ 无备份 |
| KaraKeep | oracle-k3s | ❌ 无备份 |
| Uptime Kuma | oracle-k3s | ❌ 无备份 |
| Timeslot | oracle-k3s | ❌ 无备份 |

### 恢复旧备份数据

Kopia 仓库数据已删除。若需从 Kopia 恢复旧数据，需从 git 历史恢复 manifest 并重新部署 Kopia server。

## 相关文档

- `docs/plans/2026-07-04-storage-106-utilization-and-backup-simplification.md` — 备份简化方案
- `docs/architecture/architecture-optimization-2026-07-04.md` — 架构优化建议
