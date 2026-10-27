# Storage & Backup — 存储与备份

> Last updated: 2026-10-28
> Status: 生效事实
>
> 双集群存储布局（可写卷全 `local-path` + 媒体只读 NFS）、NFS 退役的确切范围、
> PVC 清单与迁移程序，以及 restic 备份体系。
> 运维 SOP 在 [../runbooks/backup-recovery.md](../runbooks/backup-recovery.md)；
> 目录说明在 [`backup/README.md`](../../backup/README.md)。

## 存储主机 storage-106

- `192.168.50.106` / Tailscale `100.110.27.111`（hostname `storage`，`tag:homelab`），PVE 节点，
  `proxmox/ansible/inventory.yaml` 的 `storage` 组。
- 数据在 ZFS pool `mrstorage`（raidz1，挂载 `/storage`，与 OS 盘分离），由
  `proxmox/ansible/storage-playbook.yaml` 预配；sanoid hourly/daily 快照。
- ARC 上限 1GiB（`cd proxmox/ansible && just storage-arc-limit`），给同机的 worker VM 让内存；
  备份是顺序 pack 写、媒体是大文件顺序流，ARC 在这台机上本来收益就低。
  ☠️ 内存到此为止（8G = ARC 1G + VM 4G + 宿主约 2.6G）：往 VM 加内存或在 106 上多跑东西之前，
  先看 `StorageNodeMemoryLow`（已把可回收 ARC 算回去，阈值 10%）表达式的当前值；再要只能加物理条。
  判据见 [decisions/cluster-placement-for-new-services.md](../decisions/cluster-placement-for-new-services.md)。
- 重建 106 对数据是安全的：OS 在 boot 盘、数据全在 `mrstorage`，重装后重跑
  `storage-playbook.yaml` 即 `zpool import -f mrstorage` + 重建 `/etc/exports`。
  ☠️ 但 106 宕机会同时拿走三样东西：

  | 角色 | 106 宕机的后果 |
  |---|---|
  | restic 备份目标 + PVE vzdump 目标 | 备份窗口暂停（可等） |
  | worker `k8s-worker-106` 的宿主（VM 200） | homelab 少一个节点，该节点上的 local-path PVC 一并不可达 |
  | 媒体只读 NFS 源（`/storage/{movie,tv,anime,music,podcast}`） | Jellyfin/Navidrome/podcast 三个服务有进程无数据 |

  重建前先 `kubectl --context k3s-homelab drain k8s-worker-106`，并预期 `media` ns 全程不可用。

## NFS 退役的确切范围（2026-07-11 起：读写型 PVC 不用 NFS）

- 应用的可写数据一律不放 NFS：`nfs-client` provisioner 已卸载（`values/nfs-values.yaml` 已删），
  集群里没有 `nfs-client` StorageClass，引用它的 PVC 会永久 Pending。起因是 106 宕机 3 天
  （07-08→07-11），挂 NFS 的服务全部 Error、PVE 的 pvestatd 堆积 D-state。
- ☠️ 例外：`media` ns 的 5 个静态只读 NFS PV（`media-{movie,tv,anime,music,podcast}`，手写 PV/PVC，
  不经 provisioner、无 StorageClass）挂 106 的 ZFS，所以别写「运行时零依赖」。成立条件与边界 →
  [decisions/multimedia-repository-nfs-readonly.md](../decisions/multimedia-repository-nfs-readonly.md)（唯一解释处）。
- NFS export 共 7 个，全由 `storage-playbook.yaml` 的 `nfs_exports` 管：`/storage`、`/storage/calibre`
  是迁移前遗留、无人挂载；`/storage/{movie,tv,anime,music,podcast}` 是媒体的只读 export
  （`ro` + `all_squash`）。旧数据（`/storage/calibre`、`/storage/nfs/k8s/`）原地保留作迁移前快照。
  ⚠️ 只读靠服务端 export 的 `ro` 保证，PV 上的 `readOnly: true` 只是给 kubelet 的提示。
- 将来再引入 NFS 时的故障签名：服务端挂起时节点 load 飙到数千、containerd 报
  `failed to reserve container name`。修 NFS，不是修 containerd。

## sqlite 应用必须用 `local-path`，绝不能回 NFS

sqlite 依赖 POSIX 字节区间锁（`fcntl`）+ 同步小写入，NFS 的 NLM 锁让单次 DB 写/锁能阻塞分钟级
（同一条 migration 在 NFS 上 3m48s，本地盘毫秒级）。PG 同理。大顺序读写（Loki chunk、媒体流）
对 NFS 耐受度高得多：死的是 lock+fsync 模式。实例：Grafana 的 sqlite 在 NFS 上 CrashLoop 8 天，
Prometheus TSDB 重启时挂在僵死的 NFS client 上 →
[records/2026-07-04-grafana-prometheus-nfs-crashloop.md](../records/2026-07-04-grafana-prometheus-nfs-crashloop.md)。

## 当前 PVC 清单（可写卷全部 `local-path`）

改了集群存储就对照集群核一遍（docs-check 查不出清单与集群不符）：
`kubectl --context k3s-homelab get pvc -A` · `kubectl --context oracle-k3s get pvc -A`。

| 集群 · 落点 | PVC |
|---|---|
| homelab · `k8s-node`（11） | `data-vault-0`、`audit-vault-0`、`data-trivy-server-0`、`alertmanager-…-db`、`prometheus-…-db`、`kube-prometheus-stack-grafana`、`open-notebook-data-local`、`open-notebook-surreal-local`、`jobs-sg-data`、`apps-pg-data-local`（共享 Postgres）、`multica-backend-uploads` |
| homelab · `k8s-worker-106`（3） | `navidrome-data-local`、`jellyfin-config-local`（媒体服务跟着数据走）、`xiaogpt-data`（清单 `nodeSelector` 钉 worker），由 worker 侧夜备覆盖 |
| homelab · `media` ns 只读 NFS（5） | `media-movie/tv/anime/music/podcast`：真身在 106 的 ZFS（raidz1+sanoid），刻意不进 restic（理由逐条写在 H4 的 `BACKUP_EXEMPT`） |
| oracle-k3s（11） | `storage-loki-0`、`storage-tempo-0`、`calibre-books-local`、`calibre-web-automated-config-local`、`timeslot-pvc`、`trends-data`、`uptime-kuma-data-v2`、`data-trivy-server-0`、`readlist-data`、`zitadel-pg-1`、`apps-pg-1`（CNPG 共享库，见 [shared-postgres-platform.md](../decisions/shared-postgres-platform.md)） |

⚠️ homelab 还有两个待删的孤儿卷 `litellm-pg-data-local`、`multica-postgres-data`（旧 postgres 实例的
数据目录，库已并入 `apps-pg`），因 `Prune=false` 没被回收。它们让 `multica` App 一直 OutOfSync
（`requiresPruning=True` 但被注解拦住），会掩盖真实漂移。确认新库无恙后手工删：

```bash
kubectl --context k3s-homelab -n litellm delete pvc litellm-pg-data-local
kubectl --context k3s-homelab -n personal-services delete pvc multica-postgres-data
```

- ⚠️ `local-path` 无冗余、无 ZFS 快照：restic 是上面每个卷的唯一安全网（worker 上的另有整机 vzdump）。
- 有状态服务的 PVC 带 `argocd.argoproj.io/sync-options: Prune=false` 防误删；反过来退役服务时 PVC
  不会被删，要手工清。
- ⚠️ local-path 卷不跟随调度：给已有 PVC 的服务加 `nodeSelector` 只会让 Pod 因卷节点亲和冲突永远
  Pending。搬迁按 [runbooks/stateful-service-cross-cluster-migration.md](../runbooks/stateful-service-cross-cluster-migration.md)
  的节点内变体走（停服 → tar → 删 PVC → 目标节点重建 → 灌回；灌回可用一个挂着新 PVC 的临时
  busybox Pod 触发 local-path 建目录）。

### 备份归属：H4 管什么，剩下的靠什么

CI 的 H4（`scripts/check-manifests.py`，见 [manifest-safety-checks.md](manifest-safety-checks.md)）拦
「清单里新增 PVC 却没有备份归属」。其余几层：

1. 控制面夜备钉 `nodeSelector: node-role.kubernetes.io/control-plane`（`backup/base/cronjob.yaml`）。
   ☠️ 不钉的话它可能被排到 worker，那里 hostPath 几乎为空，白名单循环对空目录静默 `continue`，
   产出「近空快照 + rc=0」的假阴性备份。
2. worker 有自己的夜备：不筛 PVC 名、整个 `/localpath` 扫（文件名模式同控制面）。⚠️ 但 H4 只解析
   控制面那份的 `for pat in …`，新 PVC 照样要写进那份白名单才过 CI（在控制面上是无害 no-op）。
3. 告警 `PVCOnUnbackedNode`（`k8s/helm/manifests/monitoring/alerts/prometheus-rules.yaml` backups 组）：
   homelab 上既非控制面、又不在排除名单（按节点名排除了 `k8s-worker-106`）的节点出现 PVC 即 warning。
   H4 保证「进白名单」，这条保证「落对节点」。⚠️ 负载缩到 0 后 `kubelet_volume_stats` 消失、告警
   自行恢复，但数据还在节点盘上。
4. ⚠️ H4 查不出「有归属但文件名模式对不上」：白名单只捞 `*.db*` / `*.sqlite*` / 小 `*.json`。
   `jobs-sg-data` 的 `raw/<date>/NNN.jsonl.gz` 归档靠脚本第 3 步的 `JOBS_ARCHIVE_DIR` 整目录纳入
   （见 [jobs-sg.md](jobs-sg.md)）。只能实测：`restic ls` 确认文件真在快照里。

☠️ H4 只解析清单里的 `kind: PersistentVolumeClaim`，下面这些它看不见，也没有别的检查会提醒，
加这类应用时必须手工确认备份归属：

| 数据 | 来源 | 备份归属靠什么 |
|---|---|---|
| `apps-pg-1` · `zitadel-pg-1` | CNPG operator 按 `Cluster` CR 生成 | `backup/overlays/oracle/backup-script.yaml` 的逐库 `pg_dump`，加租户必须手工加一行 |
| `multica-backend-uploads` | 上游 OCI chart `multica` 生成 | `backup/overlays/homelab/backup-script.yaml` 整目录纳入；失败只 warn 不中断夜备，要定期核 `restic ls` 里真有它 |
| homelab `apps-pg` 的 `litellm`/`multica`/`nakama`/`blogstats` 四个库 | 清单里的 `apps-pg-data-local`（走 `BACKUP_EXEMPT`） | 同一脚本 2c)–2f) 逐库 `pg_dump`，加库必须手工加一行。`nakama`、`blogstats` 没有 PVC，那两行是唯一备份；`blogstats` 丢了不能重算（上游 Cloudflare 按 path 只留 8 天） |
| `aiven/terraform` 的 free-tier PostgreSQL | 外部托管，不在任何集群 | 无，默认可丢弃；真要存东西之前先在本表登记归属 → [aiven/README.md](../../aiven/README.md) |

☠️ worker 上的 PVC 比控制面少一层：VM 200 的盘在 106 的 `local-lvm`（LVM-thin，与 PVE 的 `local`
同在 238G 启动盘），不在 `mrstorage` 里，sanoid 对它无效。兜底是整机周备
`cd proxmox/ansible && just vzdump-worker`（`playbooks/vzdump-worker-vm.yaml`，作业 `vzdump-worker106`，
周日 05:00 → `vmbackup` 存储即 `mrstorage/vzdump`，keep-last=2）。dump 必须落 ZFS，不能用默认的
`local`：那和 VM 盘同一块物理盘。→ [decisions/storage106-as-homelab-worker.md](../decisions/storage106-as-homelab-worker.md)

## PVC 迁移程序（改 claim 指向）

StatefulSet 模板与 Deployment 的 claim 都适用：

1. 停应用 → 数据拷进新 `-local` PVC
2. `kubectl patch … volumes/<idx>/persistentVolumeClaim/claimName`（json-patch 按下标，
   strategic-merge 不动 volumes 列表）
3. 验证 → ArgoCD 管的应用先 push git + `refresh=hard`，再开回 auto-sync（否则它同步旧 revision
   把 claim 改回去）
4. Vault（STS，baseline PSA 禁 hostPath）：经两个本地 PVC 拷贝；需要 `injector.affinity: ""`，
   否则 injector rollout 在单节点上死锁。

operator 管的 StatefulSet 改 SC（`volumeClaimTemplate` 不可变），以 Prometheus 为例：CR
`spec.paused: true` → 强删卡住的 pod → 删 STS + 旧 PVC → unpause → operator 用新 SC 重建，旧数据丢弃。
跨集群搬家（两遍 rsync、域名两步切换）见
[../runbooks/stateful-service-cross-cluster-migration.md](../runbooks/stateful-service-cross-cluster-migration.md)。

## 备份（restic）

- 状态：🟢 双集群每夜 → 106 ZFS 加密仓库 `881fb124bf`，每月自动恢复演练（下节）。⚠️ 离站副本仍
  待做（[ROADMAP](../ROADMAP.md) #1 · [方案](../plans/2026-08-03-offsite-backup.md)），屋内灾难即全损。
- 设计：无 server，每个 Job 直推单一加密仓库 `mrstorage/restic`（`sftp:root@…:/storage/restic`；
  homelab 走 LAN `192.168.50.106`，oracle 走 Tailscale `100.110.27.111`）。为什么不是 Kopia →
  [decisions/restic-serverless-backup.md](../decisions/restic-serverless-backup.md)。
- 一致性靠逻辑 dump：Vault = raft snapshot，PG = `pg_dump`，SurrealDB = HTTP `/export`；sqlite =
  特权 CronJob 用 hostPath 读 `local-path` 根、按文件名模式原样拷贝（RWO 卷旁路 Pod 挂不上；
  restore 时由 WAL/journal 自恢复）。
- 保留 `--keep-daily 7 --keep-weekly 4 --keep-monthly 6`。凭据 Vault `secret/homelab/restic`
  （repo 密码 + base64 SSH key + 周期 Vault token）→ ESO。
- 夜备是三个 Job，不是两个。恢复时按 host 过滤，别默认 `latest` 就是要的那份
  （`restic snapshots --host homelab-worker`）：

  | Job | 时间（CST） | `--host` | 清单 | 保留 |
  |---|---|---|---|---|
  | homelab 控制面 | 03:00 | `homelab` | `backup/base` + `backup/overlays/homelab` | `forget --prune` |
  | homelab worker | 02:00 | `homelab-worker` | `backup/overlays/homelab/worker-{cronjob,backup-script}.yaml` | 只 `forget`（两个 prune 抢独占锁会互相失败，由 03:00 那次统一回收） |
  | oracle | 03:30 | `oracle-k3s` | `backup/overlays/oracle` | `forget --prune` |

- 部署：homelab 走 ArgoCD `backup` App，oracle 随 `oracle-k3s` App。手动触发
  `cd k8s/helm && just backup-run`。⚠️ 两个 overlay 的脚本都是显式白名单（`for pat in …`），
  新增有状态应用不加进去就静默不备份（H4 兜底，盲区见上节）。
- 书库：Calibre 书库由 oracle overlay 按目录发现（`/localpath/*calibre-books-local*`），缺失时日志打
  `[warn] books NOT in this backup`。
- 容量：dataset 配额 100G，由 `cd proxmox/ansible && ansible-playbook storage-playbook.yaml --tags quota`
  收敛。⚠️ 配额是 `MetalNodeFilesystemLow/Critical` 对这个仓库的分母：去掉配额，那两条告警就永远
  不会响；它报警时池子通常还很空，处置是抬配额，不是删备份。
- 保护层次：ZFS raidz1（容 1 盘）→ sanoid 快照（含 restic dataset）→ restic 仓库 → 离站（待做）。
  PVE 每周 vzdump 是另一路：pve 的 VM 100 → 106 的 `/storage/backups`（keep-last=3），106 的
  VM 200 → `mrstorage/vzdump`（keep-last=2）。
  - ⚠️ `/storage/backups` 在 `mrstorage` 根数据集，被 sanoid 递归快照一起拍，快照里钉着的归档远多于
    keep-last 的 3 份（2026-09-09 实测 9 份）。是否单独建数据集并从 sanoid 排除是策略决定，开放项在
    [ROADMAP](../ROADMAP.md) #16 ③。
  - ⚠️ 两台 VM 的盘在 terraform 里已是 `discard=on`（此前 `discard=ignore`，客户机 fstrim 全被 QEMU
    丢弃，thin LV 和周备归档一起虚胖），要等 VM 下次重启才落地（宿主上 `qm pending <vmid>` 可查），
    重启后客户机跑一次 `sudo fstrim -av`。provider 0.85.1 送不出既有盘改动的坑见
    `proxmox/terraform/main.tf` 文件头。
- 告警（homelab Prometheus）：`prometheus-rules.yaml` 的 `BackupTargetNodeDown`（106 失联 >15m，
  warning）· `BackupNotRunning`（CronJob 32h 未调度）· `BackupJobFailed` · `PVCOnUnbackedNode`；
  恢复演练三条见下节。vzdump 周备靠两台宿主的 `vzdump-textfile` 采集器（`cd proxmox/ansible &&
  just node-exporter` 部署）写 `vzdump_*` 指标，`storage-alerts.yaml` 的 `vzdump-backups` 组四条
  （Overdue >8 天 / Failed / NeverSucceeded / CollectorFailed）。PVE 自身没有通知出口
  （无 `notifications.cfg`、宿主无邮件），这是 vzdump 失败唯一的监控面。

## 月度恢复演练（2026-08-13 上线）

「备份在跑」和「备份能恢复」是两件事。`restic-restore-drill` CronJob
（`backup/overlays/homelab/restore-drill-{cronjob,script}.yaml`，每月 1 日 04:00 CST）真恢复一遍并跑
判据：`restic check` · `homelab` 与 `oracle-k3s` 的快照新鲜度 · Vault raft 快照 · jobs.db integrity ·
`open-notebook.surql` · oracle 的 `miniflux.sql`/`zitadel.sql` 收尾标记 · raw 归档抽一个实解压。
只恢复 `/work`（书库没必要全量恢复）。告警 `RestoreDrillFailed` / `RestoreDrillStale` /
`RestoreDrillNeverRan`，失败处置见 [runbook](../runbooks/backup-recovery.md) 的「演练失败怎么办」。
⚠️ 不在判据里：`homelab-worker` 的快照新鲜度，homelab `apps-pg` 那四个 `pg_dump -Fc` 的产物。

☠️ 判据要能真的判失败（上线时用损坏数据逐条验过，7 种坏法全部判出）。改判据时守住：

- 截断的 `vault.snap` 依然非空：判据是 `tar tzf` 里有 `state.bin`，不是 `-s`。
- 合法空库的 `PRAGMA integrity_check` 也返回 `ok`：还要「表数 > 0」。
- 半截的 `pg_dump` 大小看着正常：判据是收尾标记 `PostgreSQL database dump complete`。
- 只验「latest 能恢复」是假信心：夜备停了三个月，`latest` 照样能恢复。所以第 0 步先卡快照新鲜度
  （>3 天即失败）。`BackupNotRunning` 只看 CronJob 有没有被调度，看不出调度了但没有新快照。

### ☠️ restic 在 K8s 下的锁陷阱（会咬夜备，不只咬演练）

restic 判定锁陈旧靠 hostname + PID，而每个 Job 的 Pod hostname 都不同，所以跨 Pod 泄漏的锁在
30 分钟内不算陈旧，`restic unlock`（只删陈旧锁）清不掉。泄漏来自被 `activeDeadlineSeconds` 杀掉的
运行，或管道被提前关闭的 restic（`restic ls … | head` 会 SIGPIPE 杀掉它）。

- 脚本里靠 `--retry-lock 10m` 等（演练与 worker 夜备已这样做）；别写 `restic … | head`，整份落盘再挑。
- 真卡住时 `restic unlock --remove-all`。☠️ 只在确认没有任何备份/prune 在跑时才能用，它会连活锁一起删。
  步骤见 [runbook](../runbooks/backup-recovery.md) 的「仓库锁卡住」。
