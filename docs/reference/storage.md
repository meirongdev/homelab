# Storage & Backup — 存储与备份

> Last updated: 2026-08-03
> Status: 生效事实
>
> 双集群存储布局（全部 `local-path`）、NFS 退役事实、PVC 迁移程序，以及 restic 备份体系。
> 运维 SOP 在 [../runbooks/backup-recovery.md](../runbooks/backup-recovery.md)；
> 目录说明在 [`backup/README.md`](../../backup/README.md)。

## 存储主机 storage-106

- `192.168.50.106` / Tailscale `100.110.27.111`（hostname `storage`，`tag:homelab`，2026-07-06 入网）。
  PVE 节点，`proxmox/ansible/inventory.yaml` 的 `storage` 组。
- 数据在 **ZFS pool `mrstorage`，挂载 `/storage`**（与 OS 盘分离），由
  `proxmox/ansible/storage-playbook.yaml` 预配。ARC 读缓存 4GB + **sanoid** hourly/daily 快照
  （见 [../plans/storage/2026-07-04-storage-106-utilization-and-backup-simplification.md](../plans/storage/2026-07-04-storage-106-utilization-and-backup-simplification.md)）。
- **重建 106 是数据安全的，且不再影响集群**: OS 在 boot 盘、数据全在 `mrstorage`。
  重装后重跑 `storage-playbook.yaml` 即 `zpool import -f mrstorage` + 重建 `/etc/exports`。
  2026-07-11 起**没有任何 pod 挂载 106**，宕机只暂停备份窗口。

## NFS 已退役（2026-07-11，运行时零依赖）

- 起因：106 宕机 3 天（07-08→07-11：calibre-web/trivy/nfs-provisioner 全 Error、pvestatd D-state
  堆积、零告警送达），**全部** PVC 迁到 `local-path`，`nfs-client` provisioner 卸载、
  `values/nfs-values.yaml` 删除。106 只剩**冷备份目标**双角色：restic 夜备（sftp `/storage/restic`）
  + PVE 每周 vzdump（NFS storage `backups`）。
- 两个 NFS export（`/storage`、`/storage/calibre`）仍在（Ansible 管理）但运行时无人挂载；
  106 上的旧数据（`/storage/calibre`、`/storage/nfs/k8s/`）原地保留作迁移前快照。
- **未来任何 NFS 重新引入的故障签名**（2026-06-13 重装时实测验证）：NFS 服务端挂起时
  节点 load 飙到数千、containerd 报 `failed to reserve container name` —— 修 NFS，不是修 containerd。

## sqlite 应用必须用 `local-path`，绝不能回 NFS

sqlite 依赖 POSIX 字节区间锁（`fcntl`）+ 同步小写入；NFS 的 NLM 锁让单次 DB 写/锁可以阻塞分钟级。

- **Grafana 实例教训**: sqlite 在 NFS PVC 上，启动卡 "Loading plugins"（插件状态写 DB）超过
  160s liveness → **CrashLoop 8 天**（2026-07-04 修复：`grafana.persistence.storageClassName:
  local-path` + 放宽 liveness + 禁用启动期 grafana.com 插件调用）。同样的 migration 本地盘
  毫秒级完成（NFS 上每条 3m48s）。
- **Prometheus TSDB 同日迁离**: `nfs-client` 上重启时 head/WAL 读在僵死 NFS client 上挂住
  （线程 `D` state 零进展），和 operator ~900s startup probe 竞态 → CrashLoop。历史数据放弃
  （P2 可弃）。operator 管的 StatefulSet 改 SC = `volumeClaimTemplate` 不可变，流程：
  Prometheus CR `spec.paused: true` → 强删卡住的 pod → 删 STS + 旧 PVC → unpause →
  operator 用新 SC 重建。`maximumStartupDurationSeconds: 1800` 留作无害兜底。
- 大顺序写（Loki chunk 类）对 NFS 耐受度高得多——死的是 lock+fsync 模式。

## 当前 PVC 清单（全部 `local-path`）

2026-08-03 对**两个 live 集群**重新生成（上一版 07-31 已含两处过期）。
**集群里没有 `nfs-client` StorageClass** —— 引用它的 PVC 会永久 Pending。

- **homelab（11 个）**: `data-vault-0`、`audit-vault-0`、`bifrost-data-local`、`data-trivy-server-0`、
  `alertmanager-…-db`、`prometheus-…-db`、`kube-prometheus-stack-grafana`、`opencost-pvc`、
  `open-notebook-data-local`、`open-notebook-surreal-local`、`jobs-sg-data`（2026-08-03 新增）
- **oracle-k3s（14 个）**: `storage-loki-0`、`storage-tempo-0`、`opencost-pvc`、`calibre-books-local`、
  `calibre-web-automated-config-local`、`stirling-pdf-configs`、`timeslot-pvc`、`trends-data`、
  `uptime-kuma-data`、`karakeep-data`、`meilisearch-data`、`miniflux-db-pvc`、`data-trivy-server-0`、
  `zitadel-pg-1`

⚠️ 这份清单**天然会漂移**（docs-check 只查结构，查不出内容与集群不符——2026-07-31 那次 NFS
描述就是格式完美而内容全错）。改集群存储后重新生成：`kubectl --context <ctx> get pvc -A`。

- 「新增 PVC 却忘了纳入备份」**已由 CI 拦截**（`scripts/check-manifests.py` 的 H4，见
  [manifest-safety-checks.md](manifest-safety-checks.md)）——它上线即抓到 `trends-data`
  静默未备份约两个月。
  ⚠️ H4 只查「PVC 有没有备份归属」，**查不出「归属了但文件名模式对不上」**：
  `jobs-sg-data` 的 `raw/<date>/NNN.jsonl.gz` 归档匹配不上白名单那组 `*.db` / `*.json`
  模式，得靠第 3 步 `JOBS_ARCHIVE_DIR` 整目录纳入才保得住（见
  [jobs-sg.md](jobs-sg.md)）。这类只能实测（`restic ls` 确认文件真在快照里）。
- ⚠️ **`local-path` 无冗余、无 ZFS 快照** —— restic 备份是上面每一个卷的**唯一安全网**。
- 有状态服务的 PVC 带 `argocd.argoproj.io/sync-options: Prune=false` 防误删。

## PVC 迁移程序（改 claim 指向）

历史背景：2026-07-06 的分层设计（sqlite/PG 迁 local-path、追加日志型留 NFS）已不存在——
07-08 宕机后全量迁移（[当时的计划](../plans/storage/2026-07-06-storage-local-migration-and-backup-redesign.md)里的分层理由当历史读）。

要再迁一个 claim（StatefulSet 模板与 Deployment claim 都适用）：

1. 停应用 → 数据拷进新 `-local` PVC
2. `kubectl patch … volumes/<idx>/persistentVolumeClaim/claimName`（**json-patch 按下标**——
   strategic-merge 不动 volumes 列表）
3. 验证 → ArgoCD 管的应用 **push git + `refresh=hard` 之后再开回 auto-sync**
   （否则它同步旧 revision 把 claim 改回去）
4. Vault（STS，baseline PSA 禁 hostPath）：经两个本地 PVC 拷贝；需要 `injector.affinity: ""`，
   否则 injector rollout 在单节点上死锁。

跨集群搬家（两遍 rsync、域名两步切换）另见
[../runbooks/stateful-service-cross-cluster-migration.md](../runbooks/stateful-service-cross-cluster-migration.md)。

## 备份（restic）

- **状态**: 🟢 2026-07-06 上线，双集群每夜 → 106 ZFS 加密仓库 `881fb124bf`，恢复演练通过
  （2026-07-06：Vault raft + 2 PG + sqlite）。**离站副本仍待做**
  （[../plans/storage/2026-08-03-offsite-backup.md](../plans/storage/2026-08-03-offsite-backup.md)）。
  Kopia 已于 2026-07-05 移除。
- **设计**: 无 server；**每集群一个 CronJob 直推** 106 的单一加密仓库 `mrstorage/restic`
  （`sftp:root@…:/storage/restic`；homelab 走 LAN `192.168.50.106`，oracle 走 Tailscale
  `100.110.27.111`）。逻辑 dump 保一致性：Vault=`raft snapshot save`、PG=`pg_dump`、
  sqlite=特权 CronJob hostPath 读 `local-path` 根 + `sqlite3 ".backup"`（RWO 卷旁路 Pod
  挂不上，故 hostPath）。保留 `--keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune`。
  凭据 Vault `secret/homelab/restic`（含 base64 SSH key + 周期 Vault token）→ ESO。
- **部署**: 双集群共用 kustomize base+overlay（`backup/`，2026-07-07 合并）；homelab 走 ArgoCD
  `backup` App（`backup/overlays/homelab`），oracle 随 `oracle-k3s` App（`backup/overlays/oracle`）。
  手动触发 `just backup-run`（`k8s/helm/`）。
  ⚠️ 两个 overlay 的备份脚本都是**显式白名单**（`for pat in …`）——新增有状态应用必须往里加，
  否则静默不备份（CI H4 兜底）。
- **书库归属**: Calibre 书库在 restic 内；**2026-08-03 起随服务在 oracle overlay** 发现
  （`/localpath/*calibre-books-local*`，缺失时日志打 `[warn] books NOT in this backup`），
  homelab 侧逻辑已移除。
- **为何弃 Kopia**: 其复杂度几乎全来自 server 模式（TLS/gRPC/NodePort/524），只为让无 NFS 的
  oracle 推备份；restic 无 server、oracle 经 Tailscale 直连仓库。
- **保护层次**: ZFS raidz1（容 1 盘）→ sanoid 快照（秒级回滚，含 restic dataset）→ restic 仓库
  （护 local-path 关键数据）→ **离站 later**（`restic copy` → 云桶，待人工开通）。
  PVE 每周 vzdump（VM 100 → 106，keep-last=3）不变。
- **告警**: `BackupTargetNodeDown`（106 失联 >15m，severity=**warning**）——2026-07-12 由
  `NFSStorageNodeDown`(critical/2m) 改名降级：106 已无运行时依赖，宕机只影响备份窗口。
  规则在 `manifests/monitoring/alerts/prometheus-rules.yaml`。
