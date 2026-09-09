# Backup — restic 备份（双集群）

restic 无 server 架构：**三个 CronJob 直推**到 106 ZFS 上的单一加密仓库（homelab 走 LAN
`192.168.50.106`，oracle 走 Tailscale `100.110.27.111`）。☠️ **是三个不是两个**：
`restic-backup-worker` 02:00（worker 的 hostPath 只有它自己能读，控制面那份读不到）·
homelab 控制面 `restic-backup` 03:00 · oracle `restic-backup` 03:30（错峰）。
两台 VM 另有 PVE 侧周备（k8s-node 在 pve、worker 在 106）。
⚠️ **第四个 CronJob 不备份**：homelab 还有 `restic-restore-drill`，每月 1 日 04:00 跑恢复演练
（排在两个夜备之后）。所以 homelab 上 `kubectl -n backup get cronjob` 看到的是**三条**，
oracle 上一条——「三个备份 Job」是跨两集群的总数，不是任一集群的条数。

⚠️ **106 不是「纯冷备份目标」**：它同时是 worker `k8s-worker-106` 的宿主和媒体只读 NFS 源，
且仓库走 sftp——106 不可达 = 当晚备不上、且**恢复也无从恢复**。宕机面逐项见
[reference/storage.md](../docs/reference/storage.md)（唯一真相源，本文不复制）。

## 目录

```
backup/
├── base/                    # 共享：CronJob + namespace（kustomize base）
└── overlays/
    ├── homelab/             # Vault raft snapshot + open-notebook 的 sqlite/json
    │                        #   + Open Notebook 的 SurrealDB 逻辑导出(/export)
    │                        # worker-cronjob.yaml + worker-backup-script.yaml = 第二台节点的独立 Job
    │                        # restore-drill-{cronjob,script}.yaml = 每月恢复演练（不备份）
    └── oracle/              # PG pg_dumpall + 各 sqlite/config PVC + calibre 书库(BOOKS_DIR)
```

**为什么这个 App 在仓库根而不是 `k8s/helm/manifests/` 下**：它是**跨集群**的一份 base +
每集群一个 overlay，两边 destination 不同（homelab overlay → homelab，oracle overlay →
oracle，CI 的 H2 按 `backup/overlays/<集群>` 判集群）。放进任一集群的清单树都会让另一半
失去归属。同理 `images/` 也在根（见 [images/README.md](../images/README.md)）。

⚠️ 各 overlay 的 `backup-script.yaml` / `worker-backup-script.yaml` 里那圈 `for pat in ...` 是**显式白名单**——
新增有状态应用不往里加就静默不备份。该失效模式由 CI 的 H4 规则拦截
（见 [manifest-safety-checks.md](../docs/reference/manifest-safety-checks.md)）。
calibre 书库 2026-08-03 随服务迁 oracle，已不在 homelab overlay 里。

部署:
- homelab → 由 ArgoCD `backup` App 同步（`argocd/applications/backup.yaml`）
- oracle → 随 `oracle-k3s` App 同步

## 快速上手

```bash
just helm backup-run     # 手动触发一次（从仓库根；≡ cd k8s/helm && just backup-run）
```

## 详见

- 运维 SOP: [docs/runbooks/backup-recovery.md](../docs/runbooks/backup-recovery.md)
- 设计/保留策略: [docs/reference/storage.md](../docs/reference/storage.md)（历史设计过程见
  [docs/plans/2026-07-06-storage-local-migration-and-backup-redesign.md](../docs/plans/2026-07-06-storage-local-migration-and-backup-redesign.md)）
- 离站备份（仍是开放项，仓库目前只有 106 一份）:
  [docs/plans/2026-08-03-offsite-backup.md](../docs/plans/2026-08-03-offsite-backup.md)
