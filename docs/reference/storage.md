# Storage & Backup — 存储与备份

> Last updated: 2026-08-17
> Status: 生效事实
>
> 双集群存储布局（全部 `local-path`）、NFS 退役事实、PVC 迁移程序，以及 restic 备份体系。
> 运维 SOP 在 [../runbooks/backup-recovery.md](../runbooks/backup-recovery.md)；
> 目录说明在 [`backup/README.md`](../../backup/README.md)。

## 存储主机 storage-106

- `192.168.50.106` / Tailscale `100.110.27.111`（hostname `storage`，`tag:homelab`，2026-07-06 入网）。
  PVE 节点，`proxmox/ansible/inventory.yaml` 的 `storage` 组。
- 数据在 **ZFS pool `mrstorage`，挂载 `/storage`**（与 OS 盘分离），由
  `proxmox/ansible/storage-playbook.yaml` 预配。**ARC 读缓存上限 2GiB** + **sanoid** hourly/daily 快照
  （见 [../plans/storage/2026-07-04-storage-106-utilization-and-backup-simplification.md](../plans/storage/2026-07-04-storage-106-utilization-and-backup-simplification.md)）。
  ⚠️ ARC 于 **2026-08-13 由 4G 降到 2G**、**2026-08-16 再降到 1G**，给同机那台 VM 腾内存
  （106 只有 8G，现在的三方分配 = ARC 1G / 宿主 ~2.6G / VM **4G**）—— 106 是备份**目标**，
  写入是顺序 pack 文件，ARC 主要服务夜间 restic prune/check 的元数据；媒体只读 NFS 是大文件
  顺序流，ARC 命中率接近零，这部分几乎无损。代价是备份窗口变长。
  ☠️ **这台机器的内存到此为止**：`StorageNodeMemoryLow`（已把可回收 ARC 算回去）的实测值
  已从 2026-08-02 的 66% 掉到 **16%**，阈值是 10%。再要内存只能加物理条。
  判据见 [decisions/cluster-placement-for-new-services.md](../decisions/cluster-placement-for-new-services.md)。
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

⚠️ **2026-08-13 起 homelab 是双节点**，`local-path` 因此有了**两个物理落点**：
`k8s-node`（绝大多数 PVC）和 worker `k8s-worker-106`（106 上那台 VM 的本地盘）。
**worker 上现有 3 个 PVC**（2026-08-16 迁入）：`navidrome-data-local`、`jellyfin-config-local`
（媒体服务跟着数据走 —— 视频/音乐本体就在 106 的 ZFS 上）、`opencost-pvc`（空的，见其 values 注释）。
⚠️ **local-path 卷不跟随调度**：给已有 PVC 的服务加 `nodeSelector` 只会让 Pod 因卷节点亲和冲突
永远 Pending。搬迁要按 [runbooks/stateful-service-cross-cluster-migration.md](../runbooks/stateful-service-cross-cluster-migration.md)
的节点内变体走（停服 → tar → 删 PVC → 目标节点重建 → 灌回；灌回可以用一个挂着新 PVC 的
临时 busybox Pod 触发 local-path 建目录，省掉"先起一次空库再覆盖"的来回）。

备份边界原本 = control-plane 节点，**2026-08-16 起 worker 也被覆盖**：

1. backup CronJob 钉 `nodeSelector: node-role.kubernetes.io/control-plane`
   （`backup/base/cronjob.yaml`）。不钉的话它可能被排到 worker——那里的 hostPath
   几乎为空，白名单循环对空目录静默 `continue`，产出**「近空快照 + rc=0」的假阴性
   备份**，比"漏备一个 PVC"更糟。
2. worker 侧有**自己的**夜备 Job（`backup/overlays/homelab/worker-{cronjob,backup-script}.yaml`，
   02:00 CST，`--host homelab-worker`）——同一个 106 仓库、独立保留策略、只 `forget`
   不 `prune`（prune 交给 03:00 控制面那次，两个 prune 抢独占锁只会互相失败）。
   它**不筛 PVC 名**，整个 `/localpath` 目录扫：worker 就是用来接住漂过来的负载的，
   谁落上来都该被备到。⚠️ 但 CI 的 H4 仍只解析控制面那份的 `for pat in …`——
   新 PVC 照样要写进那份白名单才过 CI（在控制面上匹配不到目录、是无害 no-op）。
3. 告警 `PVCOnUnbackedNode`（`k8s/helm/manifests/monitoring/alerts/prometheus-rules.yaml`
   backups 组）：homelab 任何**既非 control-plane、又不在排除名单**的节点上出现被
   kubelet 统计的 PVC 即 warning——H4 只保证"进白名单"，这条保证"落对节点"。
   `k8s-worker-106` 已按节点名从中排除（它有了自己的备份路径）；**再加节点仍会被抓到**。
   已知局限：负载缩到 0 后 kubelet_volume_stats 消失、告警自行恢复，但数据还躺在
   节点盘上，处置别只看告警消没消。

☠️ **worker 上的 PVC 只有 restic 这一层保护，且比控制面少一层**：VM 200 的盘在 106 的
`local-lvm`（LVM-thin，与 PVE 的 `local` 同在一块 238G 启动盘 sdd），**不在 `mrstorage`
池里** —— sanoid 的 `[mrstorage] recursive=yes` 快照对它完全无效。2026-08-16 补了
整机周备兜底：`just vzdump-worker`（`proxmox/ansible/playbooks/vzdump-worker-vm.yaml`）
建的 `vzdump-worker106` 作业，周日 05:00 → ZFS 上的 `vmbackup` 存储（`mrstorage/vzdump`），
keep-last=2。**dump 必须落 ZFS，不能用默认的 `local`**：那和 VM 盘同一块物理盘，等于没备。
→ [decisions/storage106-as-homelab-worker.md](../decisions/storage106-as-homelab-worker.md)


**集群里没有 `nfs-client` StorageClass** —— 引用它的 PVC 会永久 Pending。

- **homelab（18 个，其中 5 个是只读 NFS）**:
  - 落 `k8s-node`（12 个）: `data-vault-0`、`audit-vault-0`、`data-trivy-server-0`、
    `alertmanager-…-db`、`prometheus-…-db`、`kube-prometheus-stack-grafana`、
    `open-notebook-data-local`、`open-notebook-surreal-local`、`jobs-sg-data`（2026-08-03 新增）、
    `litellm-pg-data-local`（2026-08-16 新增）
  - 落 `k8s-worker-106`（3 个，2026-08-16 迁入）: `navidrome-data-local`、`jellyfin-config-local`、
    `opencost-pvc` —— 由 worker 侧夜备覆盖，见上文第 2 条
  - `media` ns 的 **5 个只读 NFS PV**（`media-movie/tv/anime/music/podcast`，2026-08-16 新增）
    **不是 local-path**：真身在 106 的 ZFS（raidz1+sanoid），刻意不进 restic
    （H4 的 `BACKUP_EXEMPT` 里逐条写了理由）
- **oracle-k3s（12 个）**: `storage-loki-0`、`storage-tempo-0`、`opencost-pvc`、`calibre-books-local`、
  `calibre-web-automated-config-local`、`timeslot-pvc`、`trends-data`、
  `uptime-kuma-data-v2`、`data-trivy-server-0`、
  `zitadel-pg-1`、`readlist-data`（2026-08-05 新增，已进夜备白名单）、
  `apps-pg-1`（2026-08-06 新增，CNPG 共享库；同日 `miniflux-db-pvc` 随 `rss-postgres`
  退役删除，见 [decisions/shared-postgres-platform.md](../decisions/shared-postgres-platform.md)）

> `karakeep-data` / `meilisearch-data` 已于 2026-08-14 随 karakeep 整体退役并删除
> （SQLite 仅 564K / meili 308K，用户确认无需备份）。

⚠️ **CNPG 的 PVC（`apps-pg-1`、`zitadel-pg-1`）由 operator 动态创建，不在任何清单里
声明 → CI 的 H4 规则看不见它们。** 这两个库的备份归属靠
`backup/overlays/oracle/backup-script.yaml` 里的逐库 `pg_dump` 行保证，
**加新租户必须手工加一行**，没有任何检查会提醒你。

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

**2026-08-17 对两个 live 集群重新生成**（上一版 08-06 已漏 media/litellm 那 7 个，
也没反映 3 个 PVC 迁到 worker）。oracle 侧 12 个自 08-06 起无变化。
⚠️ 同时修了本节的结构：PVC 列表此前**掉在「月度恢复演练」那节里面**，`## 当前 PVC 清单`
标题下是空的（08-13 插入演练小节时错位，已存在 4 天）。docs-check 只查结构不查归属，
这类错位它抓不到。

## 月度恢复演练（2026-08-13 上线）

**"备份在跑"和"备份能恢复"是两件事**，此前只有前者有监控。2026-07-06 手工演练通过过一次，
但之后备份内容变了几轮（jobs-sg、open-notebook 都是后来加的），那次结论早已不覆盖现状。

现有 `restic-restore-drill` CronJob（每月 1 日 04:00 CST，`backup/overlays/homelab/`）
真恢复一遍并跑 **8 条判据**：仓库结构（`restic check`）· 两集群快照新鲜度 ·
Vault raft 快照 · jobs.db integrity · 两个 pg dump 的收尾标记 · raw 归档实解压。
只恢复 `/work`（两集群各几百 MB）——oracle 快照里挂着 23.5G 书库，全量恢复毫无必要。
告警三条一套：`RestoreDrillFailed` / `RestoreDrillStale` / `RestoreDrillNeverRan`。

☠️ **判据要能真的判失败**，否则演练只是每月一次的自我安慰。上线当天用**损坏数据**逐条
验过敏感度（7 种坏法全部判出、零漏报），其中两条最说明问题：

- **截断的 `vault.snap` 依然非空** → 只验 `-s` 会放过；判据必须是 `tar tzf` 里有 `state.bin`。
- **合法空库的 `PRAGMA integrity_check` 返回 `ok`** → 只验它会放过；靠"表数 > 0"才抓住。
- 半截的 `pg_dump` 大小看着完全正常 → 判据是**收尾标记** `PostgreSQL database dump complete`。

⚠️ **只验"latest 能恢复"是假信心**：夜备三个月前停了，`latest` 照样能恢复、判据照样全绿。
故演练第 0 步先卡快照新鲜度（>3 天即失败）。这也是 `BackupNotRunning` 覆盖不到的
——它只看 CronJob 有没有被调度，看不出"调度了但仓库里没有新快照"。

### ☠️ restic 在 K8s 下的锁陷阱（会咬夜备，不只咬演练）

restic 判定"锁已陈旧"靠 **hostname + PID**。而每个 Job 的 Pod hostname 都不同，
所以**跨 Pod 泄漏的锁在 30 分钟内一律不被认为陈旧**，`restic unlock`（只删陈旧锁）
对它无效——夜备脚本里那句 `restic unlock` 也一样清不掉。

泄漏是怎么产生的：任何被 `activeDeadlineSeconds` 杀掉的运行，或**管道被提前关闭**的
restic（`restic ls … | head` 会 SIGPIPE 杀掉 restic，2026-08-13 实测踩到两次）。

- 演练脚本靠 `--retry-lock 10m` 等（也顺带覆盖与夜备 `forget --prune` 的短暂重叠）。
- 真卡住时手工处置：`restic unlock --remove-all`
  ☠️ **只在确认没有任何备份/prune 在跑时**才能用——它会连活锁一起删。
- 写脚本时别用 `restic … | head`：整份落盘再挑。
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
- **容量**: dataset 配额 **100G**（2026-08-16 由 50G 抬起，当时已用 26.2G；抬后 26%）。
  由 `proxmox/ansible/storage-playbook.yaml --tags quota` 收敛（此前只存在于 07-06 那份 plan 的
  命令里，重建 106 会静默丢失）。⚠️ 配额是 `MetalNodeFilesystemLow/Critical` 对这个仓库的**分母** ——
  去掉配额那两条告警就永远不会响；而它报警时池子通常还很空，处置是抬配额不是删备份。
- **部署**: 双集群共用 kustomize base+overlay（`backup/`，2026-07-07 合并）；homelab 走 ArgoCD
  `backup` App（`backup/overlays/homelab`），oracle 随 `oracle-k3s` App（`backup/overlays/oracle`）。
  手动触发 `just backup-run`（`k8s/helm/`）。
  ⚠️ 两个 overlay 的备份脚本都是**显式白名单**（`for pat in …`）——新增有状态应用必须往里加，
  否则静默不备份（CI H4 兜底）。
- **夜备有三个 Job，不是两个**（2026-08-16 起）：homelab 控制面 03:00（`--host homelab`）、
  homelab worker 02:00（`--host homelab-worker`，见上「当前 PVC 清单」第 2 条）、
  oracle 03:30（`--host oracle-k3s`）。恢复时**按 host 过滤**，别默认 `latest` 就是要的那份：
  `restic snapshots --host homelab-worker`。worker 那份只 `forget` 不 `prune`，
  空间由控制面那次的全仓库 prune 统一回收。
- **书库归属**: Calibre 书库在 restic 内；**2026-08-03 起随服务在 oracle overlay** 发现
  （`/localpath/*calibre-books-local*`，缺失时日志打 `[warn] books NOT in this backup`），
  homelab 侧逻辑已移除。
- **为何弃 Kopia**: 其复杂度几乎全来自 server 模式（TLS/gRPC/NodePort/524），只为让无 NFS 的
  oracle 推备份；restic 无 server、oracle 经 Tailscale 直连仓库。
- **保护层次**: ZFS raidz1（容 1 盘）→ sanoid 快照（秒级回滚，含 restic dataset）→ restic 仓库
  （护 local-path 关键数据）→ **离站 later**（`restic copy` → 云桶，待人工开通）。
  PVE 每周 vzdump：pve-1 的 VM 100 → 106（keep-last=3）不变；**106 自己的 VM 200
  （worker）2026-08-16 新增** → `mrstorage/vzdump`（keep-last=2）。
  ⚠️ worker VM 的盘不在 `mrstorage` 里，sanoid 那层对它是**缺的**，只有 restic + vzdump 两层。
- **告警**: `BackupTargetNodeDown`（106 失联 >15m，severity=**warning**）——2026-07-12 由
  `NFSStorageNodeDown`(critical/2m) 改名降级：106 已无运行时依赖，宕机只影响备份窗口。
  规则在 `manifests/monitoring/alerts/prometheus-rules.yaml`。
