# Backup & Recovery Runbook

> Last updated: 2026-08-14
> 设计与执行: [../plans/storage/2026-07-06-storage-local-migration-and-backup-redesign.md](../plans/storage/2026-07-06-storage-local-migration-and-backup-redesign.md)
>
> **触发条件**：备份/恢复运维（含月度恢复演练）、或数据丢失/损坏后需要从 restic 恢复。
> **成功判定**：恢复后数据可用（按 § 恢复逐类验证）；演练则 8 条判据全过（见「演练失败怎么办」）。
> **回滚**：豁免——本文本身就是恢复类操作，恢复到哪个快照由你选的快照决定，无额外回滚路径。

## Status

**🟢 restic 备份已上线并验证（2026-07-06，Phase 1）。** 双集群每夜逻辑 dump → 106 ZFS 加密仓库 `881fb124bf`。恢复演练通过（Vault snapshot + 两 PG dump + sqlite integrity_check 全 OK）。
**月度恢复演练已自动化（2026-08-13）**：`restic-restore-drill` CronJob 每月 1 日 04:00 CST 真恢复 + 跑 8 条判据，
见下方「演练失败怎么办」与 [reference/storage.md](../reference/storage.md#月度恢复演练2026-08-13-上线)。
**离站（Phase 5）仍待做** —— 当前仅本地仓库（raidz1 + sanoid 保护），无异地副本；屋内灾难仍是敞口，属计划 Phase 5。

- 清单：kustomize base+overlay `backup/`（2026-07-07 双集群合并；共用骨架在 `backup/base`）。
- homelab: `backup/overlays/homelab`（ArgoCD `backup` App，CronJob 03:00）— Vault raft snapshot + sqlite（open-notebook / jobs-sg）。
- oracle-k3s: `backup/overlays/oracle`（随 ArgoCD `oracle-k3s` App 同步，CronJob 03:30）— 逐库 `pg_dump`（`apps-pg`/miniflux → `miniflux.sql`，`zitadel-pg`/zitadel → `zitadel.sql`）+ sqlite + 书库整目录。
  ⚠️ 2026-08-06 前是 `pg_dumpall` 出 `pg_all.sql`；**恢复更早的快照时找的是那个文件名**。改成逐库 dump 的原因见 [decisions/shared-postgres-platform.md](../decisions/shared-postgres-platform.md)。
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
| sqlite: open-notebook checkpoints / jobs-sg | homelab | 特权 CronJob hostPath 读 local-path + `sqlite3 ".backup"`（在线 API）|
| sqlite: karakeep / uptime-kuma / timeslot / calibre-web-config / readlist | oracle | 同上（白名单见 `backup/overlays/oracle/backup-script.yaml`）。2026-08-11 移除 stirling-pdf（退役，接替者 BentoPDF 服务端零状态）|
| meilisearch | oracle | **不备份** —— 索引可由 karakeep 重建（2026-08-06 起显式排除）|
| SurrealDB: open-notebook | homelab | HTTP `GET /export` 逻辑导出 → `open-notebook.surql`（rocksdb 是活进程持有的 `.sst/MANIFEST`，热拷不一致）。口令走 optional 卷，缺失时只 warn 不中断夜备 |
| **Calibre 书库** | oracle（2026-08-03 迁入）| **已进 restic**：`calibre-books-local`（~23G）目录整体纳入，增量去重。⚠️ 本行原写"不进 restic，留 NFS/ZFS"，NFS 退役后已不成立 |

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
# SurrealDB (open-notebook)：新库起来后从集群内 POST 回去（口令 = vault secret/homelab/open-notebook 的 surreal-password）
#   curl -sSf -u "root:<pw>" -H "Surreal-NS: open_notebook" -H "Surreal-DB: open_notebook" \
#        --data-binary @/tmp/restore/work/open-notebook.surql \
#        http://open-notebook-surrealdb.personal-services.svc:8000/import
```

Vault unseal keys: `vault-keys.json` / K8s secret `vault-backup-keys`（见记忆 `vault-pod-token-empty`）。


## 演练失败怎么办（RestoreDrillFailed）

告警说的是「备份跑了，但恢复出来的数据过不了检查」——夜备的绿灯对此完全无感。

```bash
# 1) 先看是哪条判据（每条都对应一种具体坏法）
kubectl --context k3s-homelab -n backup logs job/<drill-job> | grep -E 'DRILL-FAIL|drill-ok'

# 2) 手动补跑一次（名字必须以 restic-restore-drill 开头，否则告警正则匹配不到）
kubectl --context k3s-homelab -n backup create job \
  --from=cronjob/restic-restore-drill restic-restore-drill-manual-$(date +%m%d)
```

判据 → 含义对照：

| 判据报错 | 说明 | 下一步 |
|---|---|---|
| `快照 … 早于 …（夜备已停？）` | 仓库里没有新快照——**夜备其实已经坏了**，与能否恢复无关 | 查 `BackupNotRunning` / 夜备 Job 日志 |
| `vault.snap 里没有 state.bin` | raft 快照截断/损坏（文件非空也不算数） | 查夜备当晚是否撞 `activeDeadlineSeconds`、Vault token 是否失效 |
| `jobs.db integrity_check = …` / `没有任何表` | sqlite 热拷贝撞上写事务，或恢复出空库 | 用更早的快照恢复；查 jobs-sg 是否在 03:00 窗口有写者 |
| `<db>.sql 没有 pg_dump 收尾标记` | dump 是半截的（**大小看着完全正常**） | 查 oracle 侧夜备是否超时/连接中断 |
| `raw 归档 gzip 校验失败` | **不可再生数据**损坏（MCF 下架职位拿不回来） | 立刻用更早快照核对，别覆盖现有归档 |
| `restic ls 执行失败` | 演练**自身**受阻（多半仓库锁），**不等于数据坏了** | 见下方锁处置，别照着删数据 |

### 仓库锁卡住（restic：repository is already locked）

☠️ restic 的陈旧锁判定靠 **hostname + PID**，而 K8s 里每个 Job 的 Pod hostname 都不同——
**跨 Pod 泄漏的锁在 30 分钟内清不掉**，`restic unlock`（只删陈旧锁）无效。
泄漏来自被 `activeDeadlineSeconds` 杀掉的运行，或管道被提前关闭的 restic（`… | head`）。

```bash
# 先确认没有任何备份/prune 在跑（否则会删掉活锁、打断正在写的备份）
kubectl --context k3s-homelab -n backup get jobs
kubectl --context oracle-k3s   -n backup get jobs
# 确认无活动后，在一个临时 Pod 里（凭据同夜备）：
restic unlock --remove-all
```

## 保护层次（互补）
1. **ZFS raidz1**（106）— 容 1 盘。
2. **sanoid 快照**（106，含 restic dataset）— 秒级回滚，防误删/损坏/勒索。
3. **restic → 106 仓库** — 护迁到 local-path 的关键数据（无自带冗余）。
4. **离站（later）** — 抗屋内灾难（106 磁盘全损/失窃/火灾）。

## 相关文档
- 主计划: `docs/plans/storage/2026-07-06-storage-local-migration-and-backup-redesign.md`
- 战略母文档: `../plans/architecture/2026-07-04-fleet-architecture-optimization.md`（P0-1 离站备份）
- 存储 106 收尾: `docs/plans/storage/2026-07-04-storage-106-utilization-and-backup-simplification.md`（ARC/sanoid）
