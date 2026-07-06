# 存储本地化迁移 + 备份体系重建 — 完整执行计划（Agent 可执行）

> 日期: 2026-07-06
> 状态: 🟢 **Phase 0-2 + Phase 3a(Gotify) 已完成（2026-07-06）**；Phase 3b(ZITADEL) + Phase 4-5 待执行。
> - ✅ Phase 0-1: serverless restic 备份**双集群上线**，恢复演练通过（详见 §Phase 1 末与 §DoD）。仓库 `881fb124bf` @ 106 `mrstorage/restic`。
> - ✅ Phase 2: homelab sqlite/fsync PVC（**Vault raft / bifrost / calibre-config**）迁 local-path；alertmanager/audit/trivy 按设计留 NFS。详见 §Phase 2 表。
> - ✅ Phase 3a: **Gotify → oracle-k3s**（数据迁移 + `notify.meirong.dev` DNS 切换完成，homelab gotify 已删）。ZITADEL(3b) 待专门做（发现前置：oracle Cilium `enable-gateway-api-app-protocol=false` 需开、Bitnami PG chart 12.10.0 可能已下架）。
> - ✅ Phase 3b: **ZITADEL → oracle-k3s 完成**（数据迁移 + masterkey 同源 + `auth.meirong.dev` 切换 + console gRPC 修复 + **homelab 退役**，全验证）。homelab NFS 现仅剩 alertmanager/audit/trivy（设计）+ calibre-books。
> - ✅ Phase 4 Task 10: **SMART + zpool 健康告警**（PrometheusRule 已加载）。Task 9（dead-man's switch）待做——需扩展 uptime-kuma provisioner 支持 push monitor + 通知渠道。
> 结论: 把 homelab 上所有 **fsync/sqlite/PG 类** 有状态 PVC 从 `nfs-client` 迁到 `local-path`（性能 + 脱离 NFS 启动依赖），大件顺序数据（Calibre 书库）留在 NFS/ZFS。因 `local-path` 无冗余无快照，**先重建一套 serverless restic 备份**（逻辑 dump → 106 ZFS 上的加密仓库）再做迁移。同步把 **Gotify + ZITADEL 迁到 oracle-k3s**（脱离 homelab 故障域），并补上 **dead-man's switch** 与 **zpool/SMART 告警**。
> 关联: `../../architecture-optimization-2026-07-04.md`（战略母文档）、`2026-07-04-storage-106-utilization-and-backup-simplification.md`（本计划取代其 Task 4-6 备份部分）、`2026-07-04-zitadel-to-oracle-k3s.md`（本计划纳入并执行）、`../runbooks/backup-recovery.md`（运维手册，随本计划回写）

---

## 0. 执行者须知（Handoff Preamble）

### 0.1 用户已定决策（2026-07-06）
| 议题 | 决策 |
|------|------|
| 备份离站目标 | **先本地仓库（106 ZFS），离站 later**（后续 rclone/`restic copy` → 云） |
| 服务重定位 | **Gotify + ZITADEL 都迁 oracle-k3s**（脱离 homelab 故障域） |
| 书库（100Gi）保护 | **仅 ZFS raidz1 + sanoid 快照**（不离站，书可再下载） |

### 0.2 环境与访问
| 目标 | 访问方式 |
|------|----------|
| storage-106（备份仓库宿主 / NFS 后端） | `ssh -i ~/.ssh/vgio root@192.168.50.106`（Proxmox VE 9.0.3 / Debian 13）|
| homelab k8s | `kubectl --context k3s-homelab`（节点 `k8s-node` 10.10.10.10 / Tailscale 100.94.186.7）|
| oracle-k3s | `kubectl --context oracle-k3s`（100.107.166.37）|
| Vault（存取凭据） | `-n vault exec`；root token 见记忆 `vault-pod-token-empty` / `vault-values/vault-keys.json`（**明文密钥绝不入本文档或 git**）|

### 0.3 全局护栏（MUST）
1. **备份必须先于迁移**：任何 PVC 从 NFS 迁 `local-path` 前，该数据必须已进 restic 仓库并**验证可恢复**。`local-path` 无 raidz1、无 ZFS 快照——迁移即失去底层冗余，备份是唯一安全网。
2. **106 是全 homelab 集群 PVC 的 NFS 后端**：重启/NFS 中断会让 Pod 短暂 hang（`containerd failed to reserve container name`），恢复后自愈。仅标注"需维护窗口"的步骤可重启。
3. **绝不对卡 `Terminating` 的 NFS 有状态 Pod 用 `kubectl delete --force`**（孤儿进程占锁 → 重建 CrashLoop，见记忆 `force-delete-nfs-pod-orphans-lock`）。
4. **Vault 迁移前必须持有 unseal keys**（`vault-keys.json` / `vault-backup-keys` secret），否则迁移后无法解封。
5. **106 保持 boring**：本计划对 106 的唯一新增是「装 tailscaled + 建一个 ZFS dataset + 装 restic」——不进集群、不跑集群计算。
6. 每次改 ZFS/NFS/存储前后各存关键状态（`zpool status`、`zfs list`、`cat /etc/exports`、`kubectl get pvc -A`）备回滚比对。

### 0.4 STOP gates（到此暂停向用户确认）
- **G1 — Vault SC 迁移**：属最高风险单步（密钥库停机+搬盘）。执行前确认持有 unseal keys、restic Vault snapshot 已验证。建议单独维护窗口。
- **G2 — DNS 切换（ZITADEL / Gotify → oracle）**：`auth.meirong.dev` / `notify.meirong.dev` CNAME 改指 oracle tunnel，须确认 oracle tunnel ingress 已就绪再切。
- **G3 — 离站（Phase 5）**：需人工开通云对象存储桶+密钥（agent 不代注册云账号）；密钥入 Vault 后再消费。

### 0.5 现状核实（2026-07-06 实测，执行前复核）
- ✅ **storage-106 T1/T2 已完成**：`arc_c_max=4.00GB`（在线已抬，重启持久化 = 待核 `/etc/modprobe.d/zfs.conf`），sanoid 已装且运行（31 快照）。→ 见 §Task 1。
- ✅ **106 已加入 Tailscale**（2026-07-06）：hostname `storage` / **`100.110.27.111`** / `tag:homelab`（MagicDNS `storage.taild162e5.ts.net`）→ oracle 可直连收备份。
- ❌ **无任何备份**：Kopia 已于 2026-07-05 移除；106 上无 restic/rclone、无 `mrstorage/restic` dataset；全系统零备份。
- ❌ **dead-man's switch 缺失**：Alertmanager Watchdog `receiver: "null"`（`kube-prometheus-stack.yaml:350`）。
- ❌ **无 zpool/SMART 告警**：只有看板 `storage-106-dashboard.yaml`，无 PrometheusRule。
- **待迁 PVC（homelab `nfs-client`）**：`data-vault-0`(10Gi/raft)、`data-zitadel-db-postgresql-0`(8Gi/PG)、`bifrost-data`(2Gi/sqlite)、`gotify-data`(1Gi/sqlite)、`calibre-web-automated-config`(1Gi/sqlite)、`alertmanager-…-db`(1Gi)、`audit-vault-0`(10Gi)、`data-trivy-server-0`(2Gi/cache)。
- **留 NFS**：`calibre-books`(100Gi RWX 静态 PV)。**已在 local-path**（勿动）：grafana / prometheus / loki（2026-07-04 已迁）。

---

## 1. 存储分层设计（迁移目标态）

| 层 | 存储 | 冗余/快照 | 承载 | 备份 |
|----|------|-----------|------|------|
| **A：热有状态（本地盘）** | `local-path`（k8s-node ext4） | ❌ 无 | Vault(raft)、各 PG、所有 sqlite/config | **restic 逻辑 dump（必需）** |
| **B：大件顺序（NFS/ZFS）** | `nfs-client` + 静态 PV（106 raidz1） | ✅ raidz1 + sanoid | Calibre 书库(100Gi) | ZFS 快照（不离站） |
| **C：备份仓库（ZFS）** | 106 `/storage/restic` 专用 dataset | ✅ raidz1 + sanoid | A 层的加密备份 | 后续 rclone/`restic copy` 离站 |

**为什么 A 层迁 local-path**（已有硬证据，非臆测）：
- sqlite/PG 依赖 POSIX byte-range 锁 + 同步小写，NFS 的 NLM 锁在本环境**病态慢/hang**——Grafana 曾 8 天 CrashLoop、Prometheus wedge（见 CLAUDE.md › Storage）。
- Vault 自己的 values 就带 *"NFS-backed Raft can take >60s to bind"* 的 240s 重试补丁——说明 raft on NFS 也踩同一坑。
- NFS 经 Tailscale 子网路由被 mbpm5 劫持时，sqlite Pod 会 CrashLoop（记忆 `nfs-tailscale-route-hijack`）。迁 local-path 后这些 Pod 启动不再依赖 NFS/Tailscale 链路。

**代价与对策**：local-path 单盘无冗余无快照 → 每个迁走的 PVC **必须有可验证的 restic 备份**（本计划 Phase 1 先建、Phase 2 才迁）。三层互补保护：
- ZFS raidz1（106）→ 容 1 盘，护书库；
- sanoid 快照（106，含 restic dataset）→ 秒级回滚、防误删/勒索；
- restic → 106 加密仓库 → 护 local-path 关键数据；后续离站 → 抗屋内灾难。

---

## 2. 备份架构（serverless restic，取代 Kopia）

**设计原则**：无常驻 server（不重蹈 Kopia 的 TLS/gRPC/NodePort/524 复杂度）；每集群一个 CronJob 直推；单一加密仓库落在最耐久的 106 ZFS 上；CPU 受限、错峰。

```
homelab CronJob 03:00 ┐
  ├ Vault  : vault operator raft snapshot save   (network, 一致)
  ├ sqlite : hostPath 读 local-path + sqlite3 ".backup"  (bifrost/calibre-config)
  └ (迁移后 ZITADEL/Gotify 不在此)                        ┐  homelab→LAN 192.168.50.106
                                                          ├─► restic -r sftp:root@<106>:/storage/restic
oracle-k3s CronJob 03:30 ┐                                │  oracle→Tailscale 100.110.27.111
  ├ PG     : pg_dump miniflux / zitadel          (network)│        （106 ZFS 专用 dataset，AES 加密）
  ├ PG     : pg_dump miniflux / zitadel          (network)│
  ├ sqlite : hostPath 读 local-path + ".backup" (karakeep/uptime-kuma/timeslot/gotify)
  └ meili  : dump / tar                                   ┘
                                     restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
                                     (后续) 106: rclone sync /storage/restic → cloud   ← 离站 later
```

**关键实现要点**：
1. **单仓库、双集群**：`sftp:root@<106>:/storage/restic`。homelab 走 LAN IP `192.168.50.106`（<1ms）；oracle 走 106 的 **Tailscale IP `100.110.27.111`**（或 MagicDNS `storage`）。restic 仓库锁天然支持多主机错峰写。SSH 用**专用受限 restic key**（理想 chroot 到 `/storage/restic`），私钥入 Vault → ESO → 挂进 CronJob。
2. **PG / Vault 走网络逻辑 dump**（一致性）：`pg_dump`、`vault operator raft snapshot save`——不做文件级拷贝。
3. **sqlite / 文件数据走 hostPath + `.backup`**：local-path 卷是 RWO，被 app 占用，另一 Pod 无法挂载。改用**特权 CronJob 以 hostPath 读节点上的 local-path 根**（`/var/lib/rancher/k3s/storage/`），对每个 sqlite 用 `sqlite3 <db> ".backup <tmp>"`（在线备份 API，读活库安全），非 sqlite 目录 `tar`。单节点场景最省事、无需改任何 app。放特权 ns（`backup` ns 打 PSA privileged，或复用 kube-system）。
4. **备份镜像**：一个含 `restic + postgresql-client + sqlite3 + vault` 的小镜像（或 alpine 内 `apk add`）。
5. **保留策略**：`--keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune`。
6. **凭据**：restic repo 密码 + SSH key 存 Vault（`secret/homelab/restic`），ESO 物化到各集群 `backup` ns。

---

## 3. 执行任务

### Phase 0 — storage-106 存储层收尾

#### Task 1 — 核实/持久化 ARC + sanoid（多为复核）
- **现状**：ARC 在线已 4GB、sanoid 已跑（31 快照）。仅需**复核持久化**：
  ```bash
  grep zfs_arc_max /etc/modprobe.d/zfs.conf     # 期望含 4294967296；若无 → 抬到 4GiB 并 update-initramfs -u（重启才生效，可并入下次维护窗口）
  systemctl status sanoid.timer --no-pager
  ```
- **新增：给备份仓库 dataset 单独快照策略**（Task 2 建库后回来补 `sanoid.conf` 一段，或直接被 `mrstorage` 递归覆盖）。

#### Task 2 — 建 restic 仓库 dataset + 装 restic（自动）
- **目标**：建独立加密仓库。**106 已在 tailnet**（`storage` / `100.110.27.111` / `tag:homelab`，2026-07-06），oracle 可直连，无需再装 tailscale。
- **步骤**（106）:
  ```bash
  # 1) 建专用 ZFS dataset 存仓库（与主数据隔离、独立快照/配额）
  zfs create -o mountpoint=/storage/restic mrstorage/restic
  zfs set quota=50G mrstorage/restic
  # 2) 装 restic（初始化仓库放 Phase 1 由 CronJob 首次 backup 触发，或此处手动 init）
  apt install -y restic
  ```
- **验证**：`zfs list mrstorage/restic`；oracle 侧 `nc -vz 100.110.27.111 22` / `ssh -i <restic key> root@100.110.27.111 true` 通。
- **回滚**：`zfs destroy mrstorage/restic`。
- **备注**：106 有稳定 100.x（`tag:homelab`），oracle 走 Tailscale 直连收备份，不依赖 mbpm5 子网广播（见记忆 `nfs-tailscale-route-hijack`）。

### Phase 1 — 重建备份（**必须先于任何迁移**）

#### Task 3 — 凭据入 Vault + ESO
```bash
# restic 仓库密码 + 专用 SSH 私钥（chroot sftp 用户，或 root）入 Vault
vault kv put secret/homelab/restic \
  repo_password=<强随机> \
  ssh_private_key=@restic_ed25519 \
  repo_url_homelab='sftp:root@192.168.50.106:/storage/restic' \
  repo_url_oracle='sftp:root@100.110.27.111:/storage/restic'
# 106 上把对应公钥加进 authorized_keys（理想 command="internal-sftp" + chroot）
```
- ESO：在 homelab 与 oracle 各建 `backup` ns + ExternalSecret（复用 ClusterSecretStore `vault-backend`）物化为 K8s Secret。

#### Task 4 — homelab 备份 CronJob（03:00）
- `backup` ns（PSA privileged）；特权 CronJob，hostPath 挂 `/var/lib/rancher/k3s/storage`（只读）+ Secret。脚本：
  1. `vault operator raft snapshot save /tmp/vault.snap`（经 vault svc）
  2. 对 bifrost / calibre-config 的 sqlite：`sqlite3 <db> ".backup /tmp/<app>.db"`
  3. `restic backup /tmp --host homelab --tag nightly` + `restic forget --prune …`
- **首次运行即 `restic init`**（若仓库空）。

#### Task 5 — oracle-k3s 备份 CronJob（03:30）
- 同构，`backup` ns（oracle）。脚本：
  1. `pg_dump` miniflux（经 svc）→ `/tmp/miniflux.sql`
  2. sqlite `.backup`：karakeep / uptime-kuma / timeslot（+ 迁移后的 gotify / zitadel-pg）
  3. meilisearch：dump 或 tar
  4. `restic backup /tmp --host oracle-k3s --tag nightly` + forget/prune
- repo host 用 106 的 Tailscale IP。

#### Task 6 — 恢复演练（DoD 前置，把躺了 3 个月的 TODO 做掉）
```bash
restic -r <repo> snapshots                       # 两集群快照可见
restic -r <repo> restore latest --target /tmp/verify --host homelab
# 校验：pg_restore --list 可解析；vault snapshot 文件完整；sqlite `PRAGMA integrity_check`
```
- **DoD**：从仓库成功恢复 Vault snapshot + 一个 PG dump + 一个 sqlite，均校验通过。回写 `backup-recovery.md`。

---

## ✅ Phase 0-1 落地记录（2026-07-06，已上线并验证）

**Bootstrap（一次性，不入 git）**：
- 106: `zfs create mrstorage/restic`（mountpoint `/storage/restic`，quota 50G，chmod 700）+ `apt install restic`(0.18.0) + `restic init`（仓库 id `881fb124bf`）+ 专用 restic ed25519 公钥入 `/root/.ssh/authorized_keys`。
- Vault: policy `backup`（`sys/storage/raft/snapshot` read + `auth/token/renew-self` update）+ 周期 token（period 720h，nightly 自 renew）；`secret/homelab/restic` 写入 `repo_password` / `ssh_private_key_b64` / `vault_token` / `repo_url_*` / `repo_host_*`。

**GitOps 资源**：
- homelab: `k8s/helm/manifests/backup/{namespace,external-secret,backup-script,cronjob}.yaml`（`backup` ns，PSA privileged）；**手动 `just deploy-backup`**（infra 层，同 ESO/Vault，不走 ArgoCD）。
- oracle: `cloud/oracle/manifests/backup/*` 已入 kustomize 树 → **ArgoCD `oracle-k3s` App 自动同步**（push 后 3min 内纳管；本次已手动 apply 先行验证）。

**与原设计的偏差（实测驱动）**：
1. **sqlite 只取 `*.db*`/小 `*.json` 并剪 `processed_books`/`thumbnails`/`cache`/`meili_data`**，非整目录拷贝——active calibre-config PVC 有 **12G 可重建缓存**（processed_books 11G + thumbnails 488M），整目录会爆。
2. **SSH 私钥 base64 存 Vault**（`ssh_private_key_b64`）——KV 往返会吞掉私钥尾部换行 → ssh `error in libcrypto`。
3. **备份镜像 `alpine:3.20` + apk 加 `findutils`**——busybox find 不支持 prune 语义（否则 `pvc files = 0`）。
4. oracle sqlite 大小上限 512M（含 uptime-kuma `kuma.db` 371M 历史；监控项本是代码定义、历史可弃，但 dedup 后增量小，保留）。meilisearch 索引（karakeep 可重建）不备份。

**验证结果（恢复演练，DoD 通过）**：
- 仓库快照：`a4a0a3bd`(homelab) + `f86248dd`(oracle-k3s)；磁盘占用 157M。
- 从仓库恢复两快照均成功：`vault.snap` 结构完整（meta.json/state.bin/SHA256SUMS.sealed，即 `vault operator raft snapshot restore` 所需）；`zitadel.sql`(9992 行)/`pg_all.sql`(39926 行) 可解析；sqlite `PRAGMA integrity_check` = ok（kuma/app/config/db.db）。
- sanoid 已递归覆盖 `mrstorage/restic`（`[mrstorage] recursive=yes`）。

**已知后续（不阻塞 Phase 2）**：
- NFS 上有大量 orphan 已释放 PVC 目录（calibre-config orphans ~16G、多个旧 gotify）——glob 会带上其小 `*.db`（dedup 后无害）；建议单独清理回收空间。
- 备份失败告警（CronJob 末次成功时效）并入 Phase 4 告警；离站（Phase 5）待云桶。
- restic SSH 目前用 106 root key；硬化（chroot sftp 专用户 / rest-server append-only）留作后续。

### Phase 2 — homelab PVC 迁 local-path（每项须 Phase 1 备份已验证）

> 通用法（StatefulSet `volumeClaimTemplate` 的 SC 不可变，参照 CLAUDE.md 里 Prometheus 迁移先例）：
> 备份验证 → 停 workload → 删 STS（留旧 PVC）→ 新建同名 PVC on local-path → helper pod `cp -a` 旧→新（或从 restic 恢复）→ 改 values SC=local-path → 重建 → 校验 → 删旧 NFS PVC。

**范围收敛（实测后判定，2026-07-06）**：只迁 sqlite/fsync 真受害者，把纯缓存/追加日志/tolerant 的留 NFS（churn > 收益）。

| PVC | 决策 | 状态 | 备注 |
|-----|------|------|------|
| `bifrost-data`(sqlite) | ✅ 迁 | **✅ 已完成 2026-07-06** | Deployment；停 Pod→新建 `bifrost-data-local`(local-path)→`cp -a`→patch claim→起→验证→删旧。⚠️ 重启 ArgoCD auto-sync 前须先 push+`refresh=hard`，否则会 sync 到旧 revision 把 claim 还原成 NFS（本次踩到，已修）。json-patch by index 改 volume claim（strategic-merge 对 volumes 列表没生效）。 |
| `data-vault-0`(raft) | ✅ 迁 | **✅ 已完成 2026-07-06** | STS 停→双 local PVC 中转拷贝(vault ns baseline PSA 无 hostPath)→删旧 PVC+STS→helm 重建 STS 纳管 populated local `data-vault-0`→postStart auto-unseal 自动解封。审计留 NFS。验证: raft leader、12 secret、ESO Ready。**踩坑**: ①旧 NFS PVC 删除卡 Terminating(NFS reclaim)→清 finalizer；②helm upgrade 拉新 chart(0.33.0)滚动 injector，其硬 podAntiAffinity 单节点死锁→`injector.affinity:""`+scale 0/1；③ESO 在 Vault 重启窗口短暂 `EPERM`(Cilium 端点重编程)→重启 ESO controller 恢复。restic 快照 `fd32aa48` 兜底(未用上)。 |
| `calibre-web-automated-config` | ✅ 迁(除 thumbnails) | **✅ 已完成 2026-07-06** | Deployment；停→拷贝(除 thumbnails)→patch config claim→起→验证→删旧。⚠️ **thumbnails 12252 个小文件(488M)未迁**：NFS 逐文件延迟使整目录拷贝 ~2MB/s(90min);它可由 calibre 按需重建,故排除,只迁 processed_books(133 大文件,11G)+ DB/config → ~2-3min。books(100Gi NFS)不动。 |
| `alertmanager-…-db` | ❌ 留 NFS | — | operator 管的 bolt db，非 sqlite 锁敏感；silence 可再生。收益低。 |
| `audit-vault-0` | ❌ 留 NFS | — | 追加型审计日志，NFS 顺序写无碍。 |
| `data-trivy-server-0` | ❌ 留 NFS | — | 漏洞 DB 缓存可重建。 |

- **✅ Phase 2 完成后实测 homelab nfs-client 仅剩**：`alertmanager-db`/`audit-vault-0`/`data-trivy-server-0`(设计保留) + `gotify-data`/`data-zitadel-db-postgresql-0`(待 Phase 3 迁 oracle) + `calibre-books`(100Gi RWX 静态,留)。所有 sqlite/fsync 受害者(Vault/bifrost/calibre-config)已在 local-path。
- **通用迁移法(已跑通 3 次)**：停 workload → 建 `<pvc>-local`(local-path) → helper `cp -a`(大量小文件改按需排除) → `kubectl patch ... volumes/<idx>/persistentVolumeClaim/claimName`(**json-patch by index**,strategic-merge 对 volumes 列表不生效) → 起→验证 → **push git + `refresh=hard` 再开 auto-sync**(否则 ArgoCD sync 到旧 revision 把 claim 还原) → 删旧 PVC(NFS reclaim 慢/卡 Terminating 时清 finalizer)。

### Phase 3 — 服务重定位到 oracle-k3s

#### Task 7 — Gotify → oracle（门 G2）— ✅ 已完成 2026-07-06
- `cloud/oracle/manifests/gotify/gotify.yaml`（Deployment + Service + **local-path** PVC `Prune=false` + ExternalSecret 读 `secret/homelab/gotify`）；`base/gateway.yaml` 加 HTTPRoute `notify.meirong.dev`；加进 oracle 备份 CronJob。
- **数据**：`kubectl exec cat` 抓 homelab 活库 gotify.db(5.8M，2 apps) → transfer pod `kubectl cp` 进 oracle PVC（先于 gotify 起，避免空库初始化）→ 验证 2 apps + DB green。
- **告警桥**：`alertmanager-gotify-bridge` 留 homelab（monitoring），其 `GOTIFY_ENDPOINT` 本就是 `https://notify.meirong.dev/message` → **零改动**（DNS 切 oracle 后自动打到新 gotify；app token 在迁移的 DB 里，天然匹配）。
- **DNS/tunnel 切换（G2）**：`notify` 从 homelab tfvars 移到 oracle tfvars → `just apply` 两侧（先 homelab 删、后 oracle 建，避免 CNAME 冲突；短暂 NXDOMAIN）。验证 `curl notify.meirong.dev/health`=green。删 homelab gotify（ArgoCD prune）+ PVC。
- **⚠️ CF token 陷阱**：CF terraform 的 `terraform.tfvars` 里 `cloudflare_api_token` 是 **cloudflared tunnel token**（JWT），provider 5.19 **拒绝**。真实 API token 在各 CF 目录的 **`.env`**（gitignore），`just apply`（`set dotenv-load` + `-var`）用它覆盖 tfvars。**必须用 `just`，不能裸 `terraform apply`**。

#### Task 8 — ZITADEL → oracle（门 G2）— ✅ 完成 2026-07-06（含 homelab 退役）
- oracle 建 `cloud/oracle/manifests/zitadel/zitadel.yaml`（镜像 homelab，PG→local-path，ExternalSecrets 读 `secret/homelab/zitadel` 同源 masterkey）。分阶段: 先起 PG(空) → 恢复 homelab `pg_dump`(作为 **zitadel 用户**，因 `--no-privileges` 剥了 grant，靠 ownership) → 再起 ZITADEL HelmChart。
- **Login V2 坑**: `login-client` Secret（Login UI 的 PAT）——setup job 在**已恢复的 DB** 上跳过创建它 → login pod `FailedMount` 卡 Init。修复: 从 homelab 拷贝该 Secret（同 DB → PAT 有效）。**是 oracle 的 bootstrap 依赖（不入 git）**。
- **console gRPC**: 需 oracle Cilium `enable-gateway-api-app-protocol=true`（否则 admin.v1 404）。**外科式**开启: patch `cilium-config` CM + `rollout restart deploy/cilium-operator`（重生成 Gateway Envoy 配置）——**零数据面中断**（仅 operator 重启；实测 rss/notify/auth 全程 200）。values 已回写 `cloud/oracle/values/cilium-values.yaml`。
- **验证**: healthz 200 / OIDC discovery+JWKS(2 keys, masterkey 正确解密) / grafana authorize→302 login / Login V2 UI / 全 OIDC app 保留(argocd/grafana/karakeep/miniflux/stirling/bifrost) / console gRPC 200。`auth.meirong.dev` 已切 oracle tunnel（CF `just apply` 两侧）。ZITADEL PG 已入 oracle 备份。
- **✅ homelab 退役完成**（用户确认真实登录后）: 删 `argocd/applications/zitadel.yaml` → root prune 触发 App finalizer 级联删除（HelmChart CR → helm uninstall → PG+zitadel/login 工作负载 + zitadel ns），删 `manifests/zitadel.yaml`，`gateway.yaml` 移除 auth + 悬空 notify 路由。zitadel ns/PVC 干净删除（NFS reclaim 未卡）。oracle SSO 全程 200。homelab nfs-client 现仅剩 alertmanager/audit-vault/trivy（设计保留）+ calibre-books。
- 按该计划：oracle 建 `zitadel/`（PG on **local-path** 8Gi、ZITADEL、ESO→homelab Vault、HTTPRoute），`secret/oracle-k3s/zitadel` 同值 masterkey/db-password。
- **数据**：homelab `pg_dump` → oracle 导入；确认 masterkey 一致（签发 key 不变，已登录用户不掉线）。
- DNS：`auth.meirong.dev` CNAME 切 oracle tunnel（G2，先加 ingress 再切）。
- 清理 homelab：删 `manifests/zitadel.yaml` + PG PVC、`argocd/applications/zitadel.yaml`、`gateway.yaml` 的 auth 路由。
- ZITADEL PG 备份从 homelab CronJob 移到 oracle CronJob。

> 迁完后 **homelab 有状态仅剩**：Vault、Bifrost、Calibre-Web(+books)、LGTM(Prometheus/Loki/Grafana/Alertmanager)。身份与告警喇叭均在 oracle。

### Phase 4 — 韧性补齐

#### Task 9 — dead-man's switch（Watchdog → 外部心跳）
- oracle Uptime Kuma 建 **Push monitor**，取 push URL。
- homelab Alertmanager 把 `Watchdog` 从 `receiver:"null"` 改为 webhook 每分钟打该 push URL（`kube-prometheus-stack.yaml` route）；5 分钟无心跳 → Uptime Kuma 触发。
- Uptime Kuma 通知渠道 → **Gotify(oracle)→Telegram**（Gotify 已迁 oracle，homelab 全灭时该链路不依赖 homelab）。⚠️ 先在 Uptime Kuma 配好该通知渠道（当前 provisioner 只建 monitor，无通知渠道）。
- **效果**：homelab 整机死 → Prometheus/Alertmanager 停跳 → oracle 侧 5 分钟内知道并经 Telegram 报警（补掉唯一的"静默死亡"缺口）。

#### Task 10 — zpool + SMART 告警（PrometheusRule）— ✅ 已完成 2026-07-06
- `k8s/helm/manifests/storage-alerts.yaml`（label `release: kube-prometheus-stack`，并入 `monitoring-dashboards` App include）：
  - SMART: `smartctl_device_smart_status==0`→critical、`media_errors>0`→warning、NVMe `percentage_used>90`/`available_spare<10`→warning。
  - ZFS: `node_zfs_zpool_state{state="online"}==0`→critical（node_exporter 已导出 zpool state，无需 106 textfile collector）。
  - 5 条规则已实测被 Prometheus operator 加载。经现有 Alertmanager→Gotify 路由。

### Phase 5 — 离站（later，门 G3）
- 人工开通云对象存储（OCI always-free 20GB 或 B2），密钥入 Vault `secret/homelab/restic-offsite`。
- 106 上 weekly systemd timer：`rclone sync /storage/restic <cloud>:homelab-restic`（仓库已加密，明文不出域）**或** `restic copy` 到云 repo。
- 从**离站副本**再跑一次恢复演练（真·异地可恢复）。

### Phase 6 — 恢复演练自动化（P2）
- 月度 CronJob：`restic restore latest` → `pg_restore --list` / sqlite `integrity_check` / 校验和 → 失败 Gotify 告警。把一次性演练变持续验证。

---

## 4. 依赖与执行顺序
```
Phase 0(106: tailscale+dataset) ─► Phase 1(建备份+恢复演练 DoD) ─► Phase 2(迁 homelab PVC)
                                                              └─► Phase 3(Gotify/ZITADEL→oracle)
Phase 1 完成后可并行 Phase 4(dead-man's + 告警)
Phase 5(离站) / Phase 6(演练自动化) 随后，Phase 5 需 G3 云凭据
```
**硬顺序**：Phase 1（备份+验证）**必须**在 Phase 2/3 任何迁移之前完成。Vault SC 迁移（Phase 2 首行，门 G1）单列维护窗口。

## 5. 完成定义（DoD）
- [x] restic 仓库在 106 ZFS，两集群每夜自动备份、`restic snapshots` 可见。✅ 2026-07-06
- [x] **从仓库成功恢复 Vault snapshot + 1 个 PG + 1 个 sqlite**（Phase 1 Task 6）。✅ 2026-07-06
- [x] homelab sqlite/fsync PVC（Vault/bifrost/calibre-config）在 local-path、启动不再依赖 NFS ✅ 2026-07-06；alertmanager/audit/trivy 按设计留 NFS；gotify/zitadel-PG 待 Phase 3 迁 oracle；calibre-books 静态 RWX 留 NFS。
- [ ] Gotify + ZITADEL 在 oracle-k3s，`notify/auth.meirong.dev` 正常，OIDC 登录通。
- [ ] Watchdog → oracle Uptime Kuma push；模拟 homelab 停跳能经 Telegram 收到。
- [ ] zpool/SMART PrometheusRule 生效。
- [ ] 结论回写 `backup-recovery.md`、`TODO.md`、CLAUDE.md。

## 6. 关联文档
- 战略母文档: `../../architecture-optimization-2026-07-04.md`
- 被取代/纳入: `2026-07-04-storage-106-utilization-and-backup-simplification.md`（T4-6）、`2026-07-04-zitadel-to-oracle-k3s.md`
- 运维手册: `../runbooks/backup-recovery.md`（随本计划回写为 restic 版）
- 相关记忆: `nfs-hang-wedges-node` / `force-delete-nfs-pod-orphans-lock` / `nfs-tailscale-route-hijack` / `vault-pod-token-empty` / `storage-106-host-specs`
