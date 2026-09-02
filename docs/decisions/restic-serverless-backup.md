# 备份选 restic（无 server，CronJob 直推 106），取代 Kopia

> 日期: 2026-07-05 移除 Kopia / 2026-07-06 restic 上线 · 2026-09-02 补写本 ADR
> 状态: ✅ 已实施，双集群 + worker 共三个 Job
> 关联：[执行过程与迁移分期](../plans/storage/2026-07-06-storage-local-migration-and-backup-redesign.md)（历史快照）·
> [reference/storage.md](../reference/storage.md)（备份设计与 PVC 清单的**唯一真相源**）·
> [runbooks/backup-recovery.md](../runbooks/backup-recovery.md)（恢复 SOP）

> ⚠️ **本文是 2026-09-02 补写的**：此前备份工具选型的唯一记录是上面那份 plan，
> 而 plan 按 R1 是冻结快照。本文只搬决策与取舍，分期执行步骤仍在 plan 里。

## Context

2026-07 有两件事同时发生，互为前提：

1. **存储要本地化**。106（NAS）宕机三天暴露出 `nfs-client` 是运行时依赖，且 sqlite 应用在
   NFS 上 fcntl 锁极慢。结论是把有状态 PVC 全迁 `local-path`。
2. **迁过去就没有底层冗余了**。`local-path` 是节点单盘，无 raidz1、无 ZFS 快照。
   所以**备份必须先于迁移建好并验证可恢复**，它是唯一安全网。

而当时的实际状态是 **零备份**：Kopia 已于 2026-07-05 整体移除（server + CronJob + PVC +
Vault secret），106 上既无 restic 也无 rclone。

## Options

### 继续用 Kopia
它的复杂度几乎全来自 **server 模式**：TLS、gRPC、NodePort，以及经 Cloudflare 时的 524。
而这套 server 存在的唯一理由是让**没有 NFS 的 oracle** 能推备份 —— 一个可以用别的方式
解决的问题。为一个副作用养一整套控制面。

### restic，无 server，每集群一个 CronJob 直推 ← 采纳
oracle 经 Tailscale 直连 106 的 sftp，server 模式那一整层直接不存在。
restic 的仓库锁天然支持多主机错峰写，所以两个集群可以共用一个仓库。

### 备份到云而不是 106
离站是对的方向，但需要先人工开桶，且当时的紧迫任务是「迁移前必须有可验证的备份」。
选择先落 106、离站后补（至今仍是 [ROADMAP 开放项 #1](../ROADMAP.md)，**火灾/失窃即全损**）。

## Decision

- **restic，无常驻 server**；每集群一个 CronJob 直推 `sftp:root@<106>:/storage/restic`。
  homelab 走 LAN（<1ms），oracle 走 106 的 Tailscale IP。单一加密仓库，错峰跑。
- **备份的是逻辑 dump 不是数据目录**：Postgres 逐库 `pg_dump`、Vault raft snapshot、
  sqlite 单独拷。数据目录原样拷贝对有 WAL 的库不可靠。
- **凭据进 Vault**（`secret/homelab/restic`）→ ESO 物化到各集群 `backup` ns。
- **显式白名单**：备份哪些卷写在 `backup/overlays/*/backup-script.yaml` 里。

## Consequences

- ✅ 恢复演练 2026-07-06 通过；2026-08-13 起 `restic-restore-drill` CronJob 每月真恢复 +
  8 条判据 + 3 条告警，判据敏感度用损坏数据逐条实测过（7 种坏法全判出）。
- ☠️ **白名单是显式的，新增有状态应用不加进去就静默不备份**。`trends-data` 曾因此漏备
  两个月。这是 CI 规则 [H4](../reference/manifest-safety-checks.md) 存在的原因 ——
  但 H4 只看**清单里声明的** PVC：CNPG 由 operator 动态创建的卷、helm 装出来的卷它都看不见，
  加一个 Postgres 租户必须手工加一行 `pg_dump`，没有任何检查会提醒。
- ⚠️ **三个 Job 不是两个**：homelab 控制面 03:00、homelab worker 02:00（2026-08-16 新增，
  控制面那份读不到 worker 的 hostPath）、oracle 03:30。加节点要记得加 Job。
- ⚠️ 106 已不再是「非运行时依赖」：2026-08-13 起它承载 homelab worker VM，08-16 起提供
  媒体只读 NFS。它宕机不再只是暂停备份窗口。
- **仍未闭环**：离站副本。当前只有 106 本地一份，恢复演练只证明「106 上那份能恢复」。

## 重新评估条件

- 离站落地后重看仓库布局（`restic copy` 到云桶 vs 106 侧 `rclone sync`，两者对
  「勒索软件加密了 106」的抵抗力不同）。
- 数据量增长到 prune 时间不可接受时，重看单仓库共用的选择。
