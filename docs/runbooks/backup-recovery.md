# Backup & Recovery Runbook

> Last updated: 2026-07-06
> 设计与执行: [../plans/storage/2026-07-06-storage-local-migration-and-backup-redesign.md](../plans/storage/2026-07-06-storage-local-migration-and-backup-redesign.md)

## Status

**🟢 restic 备份已上线并验证（2026-07-06，Phase 1）。** 双集群每夜逻辑 dump → 106 ZFS 加密仓库 `881fb124bf`。恢复演练通过（Vault snapshot + 两 PG dump + sqlite integrity_check 全 OK）。
**离站（Phase 5）仍待做** —— 当前仅本地仓库（raidz1 + sanoid 保护），无异地副本；屋内灾难仍是敞口，属计划 Phase 5。

- 清单：kustomize base+overlay `backup/`（2026-07-07 双集群合并；共用骨架在 `backup/base`）。
- homelab: `backup/overlays/homelab`（ArgoCD `backup` App，CronJob 03:00）— Vault raft snapshot + zitadel `pg_dump` + sqlite。
- oracle-k3s: `backup/overlays/oracle`（随 ArgoCD `oracle-k3s` App 同步，CronJob 03:30）— `pg_dumpall`(miniflux+karakeep) + sqlite。
- 手动触发：`just backup-run`（homelab）/ `kubectl --context oracle-k3s -n backup create job --from=cronjob/restic-backup <name>`。
- 查快照（在 106）：`RESTIC_PASSWORD=… restic -r /storage/restic snapshots`。

## 设计（serverless restic，取代 Kopia）

**为什么换掉 Kopia**：Kopia 复杂度几乎全来自 server 模式（TLS/gRPC/NodePort/524），而它存在只为让无 NFS 的 oracle-k3s 经 gRPC 推备份。restic 无 server：每集群 CronJob 直接 `restic backup` 到同一加密仓库。

**仓库**: 单一 restic 仓库落在 **storage-106 ZFS 专用 dataset** `mrstorage/restic`（`/storage/restic`，raidz1 + sanoid 快照保护、50G 配额）。AES 加密，明文不出域。

**接入**（106 已在 tailnet：`storage` / `100.110.27.111` / `tag:homelab`）:
- homelab CronJob → `sftp:root@192.168.50.106:/storage/restic`（LAN）
- oracle-k3s CronJob → `sftp:root@100.110.27.111:/storage/restic`（Tailscale）

**备份内容与机制**:
| 数据 | 集群 | 机制（一致性）|
|------|------|------|
| Vault (raft) | homelab | `vault operator raft snapshot save`（network API）|
| ZITADEL PG | oracle（迁移后）| `pg_dump`（network）|
| Miniflux PG | oracle | `pg_dump`（network）|
| sqlite: bifrost / calibre-config | homelab | 特权 CronJob hostPath 读 local-path + `sqlite3 ".backup"`（在线 API）|
| sqlite: gotify / karakeep / uptime-kuma / timeslot | oracle | 同上 |
| meilisearch | oracle | dump / tar |
| **Calibre 书库 (100Gi)** | homelab | **不进 restic** — 留 NFS/ZFS，靠 raidz1 + sanoid 快照（书可再下载）|

**为什么 sqlite 走 hostPath**：local-path 卷是 RWO、被 app 占用，旁路 Pod 无法挂载。单节点场景用特权 CronJob 直接读节点 `/var/lib/rancher/k3s/storage/`，对 sqlite 用在线 `.backup` API（读活库安全），无需改任何 app。

**保留**: `restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune`。

**凭据**: Vault `secret/homelab/restic`（repo 密码 + 专用 SSH key）→ ESO → 各集群 `backup` ns Secret。

**离站（later）**: 106 上 weekly `rclone sync /storage/restic <cloud>:` 或 `restic copy` 到云 repo（OCI always-free 20GB / B2）。仓库已加密，离站零额外风险。需人工先开云桶（计划 Phase 5 门 G3）。

## 恢复（restore）

```bash
# 列快照
restic -r sftp:root@192.168.50.106:/storage/restic snapshots

# 恢复到临时目录
restic -r <repo> restore latest --target /tmp/restore --host <homelab|oracle-k3s>

# Vault：新 Vault init+unseal 后 → vault operator raft snapshot restore -force /tmp/restore/vault.snap → 用旧 unseal keys 解封
# PG  ：psql -U <user> -d <db> < /tmp/restore/<db>.sql（或 pg_restore）
# sqlite：直接替换 app PVC 内 .db（app 停机时），sqlite3 <db> "PRAGMA integrity_check"
```

Vault unseal keys: `vault-keys.json` / K8s secret `vault-backup-keys`（见记忆 `vault-pod-token-empty`）。

## 保护层次（互补）
1. **ZFS raidz1**（106）— 容 1 盘。
2. **sanoid 快照**（106，含 restic dataset）— 秒级回滚，防误删/损坏/勒索。
3. **restic → 106 仓库** — 护迁到 local-path 的关键数据（无自带冗余）。
4. **离站（later）** — 抗屋内灾难（106 磁盘全损/失窃/火灾）。

## 相关文档
- 主计划: `docs/plans/2026-07-06-storage-local-migration-and-backup-redesign.md`
- 战略母文档: `architecture-optimization-2026-07-04.md`（P0-1 离站备份）
- 存储 106 收尾: `docs/plans/2026-07-04-storage-106-utilization-and-backup-simplification.md`（ARC/sanoid）
