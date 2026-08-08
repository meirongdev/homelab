# Backup — restic 备份（双集群）

restic 无 server 架构：**每个集群一个 CronJob 直推**到 106 ZFS 上的单一加密仓库
（homelab 走 LAN `192.168.50.106`，oracle 走 Tailscale `100.110.27.111`），每夜自动跑。
NFS 已退役，106 只做**冷备份目标**，不再是运行时依赖。

## 目录

```
backup/
├── base/                    # 共享：CronJob + namespace（kustomize base）
└── overlays/
    ├── homelab/             # Vault raft snapshot + open-notebook 的 sqlite/json
    │                        #   + Open Notebook 的 SurrealDB 逻辑导出(/export)
    └── oracle/              # PG pg_dumpall + 各 sqlite/config PVC + calibre 书库(BOOKS_DIR)
```

⚠️ 两个 overlay 的 `backup-script.yaml` 里那圈 `for pat in ...` 是**显式白名单**——
新增有状态应用不往里加就静默不备份。该失效模式由 CI 的 H4 规则拦截
（见 [manifest-safety-checks.md](../docs/reference/manifest-safety-checks.md)）。
calibre 书库 2026-08-03 随服务迁 oracle，已不在 homelab overlay 里。

部署:
- homelab → 由 ArgoCD `backup` App 同步（`argocd/applications/backup.yaml`）
- oracle → 随 `oracle-k3s` App 同步

## 快速上手

```bash
just backup-run     # 手动触发一次（cd k8s/helm）
```

## 详见

- 运维 SOP: [docs/runbooks/backup-recovery.md](../docs/runbooks/backup-recovery.md)
- 设计/保留策略: [docs/reference/storage.md](../docs/reference/storage.md)（历史设计过程见
  [docs/plans/storage/2026-07-06-storage-local-migration-and-backup-redesign.md](../docs/plans/storage/2026-07-06-storage-local-migration-and-backup-redesign.md)）
- 离站备份（仍是开放项，仓库目前只有 106 一份）:
  [docs/plans/storage/2026-08-03-offsite-backup.md](../docs/plans/storage/2026-08-03-offsite-backup.md)
