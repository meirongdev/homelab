# storage-106 充分利用 + 备份简化 — 完整执行计划（Agent 可执行）

> 日期: 2026-07-04
> 状态: 📋 待执行（Planned）
> 执行方式: **供后续 agent 按 Task 顺序执行**。每个 Task 自带 前置条件 / 精确命令 / 预期结果 / 验证 / 回滚 / 风险等级 / 是否需人工门。
> 关联: `../../architecture-optimization-2026-07-04.md`（战略母文档）、`../runbooks/backup-recovery.md`（现有 Kopia 备份运维）
> 结论: 把 106 从"单点裸盘"升级为**带 ARC 读缓存 + ZFS 快照 + 云端离站**的三层受保护存储；**不加计算**。备份层默认**保留 Kopia + 用 rclone 只做离站**（最小改动）；若要根治 Kopia server 复杂度则迁 **restic**（需用户确认）。

---

## 0. 执行者须知（Handoff Preamble）

### 0.1 环境与访问
| 目标 | 访问方式 |
|------|----------|
| storage-106（本计划主体） | `ssh -i ~/.ssh/vgio root@192.168.50.106`（root，Proxmox VE 9.0.3 / Debian 13）|
| homelab k8s | `kubectl --context k3s-homelab`（节点 `k8s-node` 10.10.10.10）|
| oracle-k3s（仅 Option A 用到） | `kubectl --context oracle-k3s` |
| Vault（取/存离站凭据） | `kubectl --context k3s-homelab -n vault exec …`；root token 见记忆 `vault-pod-token-empty` / `docs/runbooks/backup-recovery.md`（**切勿把明文密钥写进本文档或 git**）|

### 0.2 全局护栏（MUST — 违反会打断整个集群）
1. **106 是全 homelab 集群所有 PVC 的 NFS 后端**。任何 **重启 / NFS 服务中断** 都会让集群 Pod 短暂 hang（`containerd failed to reserve container name`），NFS 恢复后自愈。→ **只有明确标注"需维护窗口"的 Task 可重启**；其余必须在线、零中断。
2. **绝不对卡在 `Terminating` 的 NFS 有状态 Pod 用 `kubectl delete --force`**（遗留孤儿进程占锁 → 重建 Pod CrashLoop）。
3. **不把 106 并入 k8s 集群、不在其上跑集群计算、不划 VM 做 k3s 节点**（前置分析已否决，见母文档附录）。
4. **不用裸 rclone 全量替换 Kopia**（同步≠备份，会丢失时间点回滚）。
5. 改 ZFS/NFS 前后各存一次关键状态（`zpool status`、`zfs get all mrstorage`、`cat /etc/exports`），便于回滚比对。

### 0.3 需要人工介入的门（STOP gates — 到此暂停并向用户确认）
- **G1 — 维护窗口**: Task 3（ARC 落盘 + 重启 106）会中断 NFS，须用户批准时间窗。
- **G2 — 备份路线**: Task 4 默认走 **Option C（保留 Kopia）**。若用户想走 **Option A（迁 restic）**，那是一次独立的较大迁移，**须用户显式确认后**才执行（见 §附录 Option A）。
- **G3 — 云账号与凭据**: Task 5（离站）依赖一个云对象存储桶（OCI 永久免费 20GB 或 B2）及其访问密钥。**账号开通与密钥获取须人工完成**，agent 不得代为注册云账号。密钥就绪后存入 Vault，再由 agent 消费。

### 0.4 Task 状态清单（执行者随进度勾选）
| Task | 名称 | 自动/人工门 | 需维护窗口 | 状态 |
|------|------|-------------|-----------|------|
| 1 | A1a 在线抬 ARC | 自动 | 否 | ⬜ |
| 2 | A2 sanoid ZFS 快照 | 自动 | 否 | ⬜ |
| 3 | A1b ARC 落盘 + 重启 | 门 G1 | **是** | ⬜ |
| 4 | Part B 备份路线落地（默认 C）| 门 G2 | 否 | ⬜ |
| 5 | A3 离站推送（Option C 路径）| 门 G3 | 否 | ⬜ |
| 6 | 恢复演练（DoD）| 自动 | 否 | ⬜ |

---

## 1. 现状快照（实测 2026-07-04，执行前应复核仍成立）
- 106: Celeron J4105 4c@1.5GHz，7.6GB RAM（已用 ~2.5GB，**~5GB 闲置**），load ~0.00。
- `mrstorage`: raidz1 3× 4TB WD Red Plus **机械盘**，单数据集挂 `/storage`，396G/6.75T（6%）。
- **ARC 硬封顶 0.76GB**（`/etc/modprobe.d/zfs.conf` → `zfs_arc_max=812646400`）。
- **ZFS 快照 = 0**；sanoid/zfs-auto-snapshot 未装。
- **离站 = 0**；主机侧无 rclone/restic/kopia，无云配置。
- **Kopia 仓库 ~20GB 在 mrstorage 上**（`/storage/nfs/k8s/kopia-kopia-repository-pvc-*`，与主数据同池）。⚠️ 磁盘上有**多个** repository PVC 目录（13G / 6.9G / 50M / 190K），执行 Task 5 时**必须动态识别当前活跃仓库**，不得硬编码。
- ✅ ZFS scrub 已定时（`zfsutils-linux` timer）；raidz1 已容 1 盘（不替代离站）。

**执行前复核命令**（在 106 上跑，确认现状未变）:
```bash
free -h; awk '/^c_max/{printf "arc_c_max=%.2fGB\n",$3/1073741824}' /proc/spl/kstat/zfs/arcstats
zpool status mrstorage; zfs list -t snapshot | wc -l; command -v sanoid rclone restic kopia
```

---

## 2. 执行任务

### Task 1 — A1a：在线抬高 ARC（自动，零中断）
- **目标**: 让闲置 RAM 变成 NFS 读缓存，提升全集群 PVC 读性能。
- **风险**: 低。**无需重启，不中断 NFS**。ARC 是可回收软上限。
- **前置**: 复核 106 空闲内存 ≥ 4.5GB（`free -h` 的 available）。
- **步骤**（106 上）:
  ```bash
  # 目标 4GiB = 4294967296 bytes
  echo 4294967296 > /sys/module/zfs/parameters/zfs_arc_max
  cat /sys/module/zfs/parameters/zfs_arc_max     # 期望: 4294967296
  ```
- **预期结果**: `zfs_arc_max` = 4294967296；ARC `size` 会随后续读流量逐步增长至上限。
- **验证**（跑数小时后）:
  ```bash
  awk '/^size /{printf "arc_size=%.2fGB\n",$3/1073741824} /^hits /{h=$3}/^misses /{m=$3} END{printf "hit_ratio=%.1f%%\n",h/(h+m)*100}' /proc/spl/kstat/zfs/arcstats
  free -h    # 确认宿主机仍有 ≥1.5GB available
  ```
- **回滚**: `echo 812646400 > /sys/module/zfs/parameters/zfs_arc_max`
- **幂等**: 是（重复设同值无副作用）。

### Task 2 — A2：启用 sanoid ZFS 自动快照（自动，无需重启）
- **目标**: 提供全数据集、秒级、写时复制的时间点回滚（防误删/损坏/勒索），补 Kopia 之外的一层。也是 Task 5 一致性副本的来源。
- **风险**: 低。快照 CoW，空闲盘充裕，开销可忽略。
- **前置**: 无。
- **步骤**（106 上）:
  ```bash
  apt-cache policy sanoid    # 确认 trixie 源有 sanoid；若无则用官方 .deb 或 github.com/jimsalterjrs/sanoid（106 可访问外网确认）
  apt install -y sanoid
  install -d /etc/sanoid
  cat > /etc/sanoid/sanoid.conf <<'EOF'
  [mrstorage]
      use_template = production
      recursive = yes
  [template_production]
      hourly = 24
      daily = 14
      weekly = 4
      monthly = 3
      autosnap = yes
      autoprune = yes
  EOF
  systemctl enable --now sanoid.timer
  ```
- **预期结果**: `sanoid.timer` active；在下一个时间边界后开始生成 `mrstorage@autosnap_*` 快照并按策略 prune。
- **验证**:
  ```bash
  systemctl status sanoid.timer --no-pager
  zfs list -t snapshot | head          # 应逐步出现快照
  # 单文件恢复演示（只读，不破坏）:
  ls /storage/.zfs/snapshot/          # 列出快照目录
  ```
- **回滚**: `systemctl disable --now sanoid.timer`；（可选）`zfs destroy mrstorage@<snap>` 清理已生成快照。
- **幂等**: 是（配置声明式；apt/systemctl 重跑安全）。

### Task 3 — A1b：ARC 落盘持久化 + 重启（门 G1，需维护窗口）
- **目标**: 让 Task 1 的 ARC 上限在重启后仍生效。
- **风险**: 中。**重启 106 → NFS 中断 → 集群 Pod 短暂 hang（自愈）**。→ **必须先过 G1（用户批准维护窗口）**。
- **前置**: G1 已批准；已通知/确认此刻可短暂中断 homelab 存储。
- **步骤**（106 上）:
  ```bash
  # 编辑为 4GiB（若文件已有该行则替换）
  sed -i 's/^options zfs zfs_arc_max=.*/options zfs zfs_arc_max=4294967296/' /etc/modprobe.d/zfs.conf
  grep zfs_arc_max /etc/modprobe.d/zfs.conf     # 确认已改
  update-initramfs -u
  # —— 维护窗口内 ——
  reboot
  ```
- **预期结果**: 重启后 `cat /sys/module/zfs/parameters/zfs_arc_max` = 4294967296。
- **验证**（重启后）:
  ```bash
  cat /sys/module/zfs/parameters/zfs_arc_max        # 4294967296
  zpool status mrstorage                            # ONLINE 无错误
  exportfs -v                                        # NFS 导出恢复
  kubectl --context k3s-homelab get pods -A | grep -v -E 'Running|Completed'   # 集群 Pod 已回稳
  ```
- **回滚**: 还原 `/etc/modprobe.d/zfs.conf` 原值 `812646400` + `update-initramfs -u` + 下个窗口重启。
- **幂等**: 是（sed 替换固定行）。
- **备注**: 若长期不便安排重启，可无限期只保留 Task 1 的在线设置——功能等价，只是重启后需再跑一次 Task 1。

### Task 4 — Part B：备份路线落地（门 G2，默认 Option C）
- **目标**: 定下离站用哪套工具。**默认执行 Option C**（保留 Kopia + rclone 只做离站，最小改动、零迁移风险）。
- **决策**:
  - **Option C（默认，直接进 Task 5）**: 不动现有 Kopia 备份工作流；rclone 仅把已加密的 ~20GB 仓库搬到云端。
  - **Option A（须过 G2）**: 迁 restic（无 server，各集群直连云 repo，根治 gRPC 复杂度）。**仅在用户显式选择后**执行，按 §附录 Option A 展开，且它**替代** Task 5。
- **动作**: 记录选择结果于本 Task 状态；未获 G2 明确改选则默认 C。

### Task 5 — A3：离站推送（Option C 路径，门 G3）
- **目标**: 把 Kopia 仓库异地备份到云对象存储，补掉唯一不可逆风险。
- **风险**: 中（涉及外发数据 + 凭据）。仓库本身已 AES 加密，故**明文不出域**。
- **前置**:
  - **G3 已完成**: 人工开通 OCI Object Storage（永久免费 20GB，首选）或 B2 桶，并取得访问密钥；密钥存入 Vault（建议路径 `secret/homelab/rclone-offsite`，键含 endpoint/bucket/access_key/secret_key）。
  - **Task 2 已生效**（用 ZFS 快照取一致性副本）。
- **步骤**（106 上）:
  ```bash
  # 1) 安装 rclone
  apt install -y rclone      # 或官方脚本；确认版本支持所选后端

  # 2) 配置 remote（凭据从 Vault 取，写入 /root/.config/rclone/rclone.conf，chmod 600；勿入 git）
  #    OCI 用 S3 兼容/oracleobjectstorage 后端；B2 用原生 b2 后端——按 G3 实际开通的选。
  install -d -m 700 /root/.config/rclone
  #  （交互式）rclone config    或直接写 conf 文件；示例（B2）:
  #    [offsite]
  #    type = b2
  #    account = <从 Vault>
  #    key = <从 Vault>
  rclone lsd offsite:            # 验证连通与桶可见

  # 3) 识别当前活跃 Kopia 仓库目录（勿硬编码 hash！）
  #    从运行中的 kopia 负载反查其 repository PVC，再映射到 NFS 子目录
  PVC=$(kubectl --context k3s-homelab -n kopia get deploy kopia \
        -o jsonpath='{range .spec.template.spec.volumes[*]}{.persistentVolumeClaim.claimName}{"\n"}{end}' | grep -i repos)
  echo "active repo PVC = $PVC"   # 期望类似 kopia-repository / repository-pvc
  #    在 106 上找到对应的 NFS 子目录（名字含该 PVC + uid）:
  REPO_DIR=$(ls -d /storage/nfs/k8s/*${PVC}* 2>/dev/null | head -1); echo "REPO_DIR=$REPO_DIR"
  #    交叉核对: du -sh "$REPO_DIR"（应与活跃仓库体量一致，当前 ~13G）

  # 4) 从最新 ZFS 快照取一致性副本并推送
  SNAP=$(zfs list -H -t snapshot -o name -s creation mrstorage | tail -1 | cut -d@ -f2)
  SNAP_REPO="/storage/.zfs/snapshot/${SNAP}${REPO_DIR#/storage}"
  rclone sync "$SNAP_REPO" offsite:homelab-kopia --transfers 4 --fast-list --stats 30s
  ```
  > 替代法（不依赖识别目录）: 在 106 装 kopia CLI，`kopia repository connect …` 后 `kopia repository sync-to`（走仓库逻辑层，天然选中活跃仓库）。二选一即可，rclone 法更轻。
  ```bash
  # 5) 定时化: systemd service + timer（每周），复用上面 3)+4) 的脚本
  cat > /usr/local/sbin/offsite-kopia-sync.sh <<'EOF'
  #!/usr/bin/env bash
  set -euo pipefail
  # …把 3)+4) 的逻辑固化于此（含快照选取与 REPO_DIR 识别）…
  EOF
  chmod 700 /usr/local/sbin/offsite-kopia-sync.sh
  # /etc/systemd/system/offsite-kopia-sync.{service,timer}（OnCalendar=weekly），systemctl enable --now …timer
  ```
- **预期结果**: 云端对象数/字节与本地活跃仓库一致；weekly timer 就绪。
- **验证**:
  ```bash
  rclone size offsite:homelab-kopia          # 与 du -sh "$REPO_DIR" 量级一致
  systemctl list-timers offsite-kopia-sync.timer --no-pager
  ```
  更强验证并入 **Task 6**（从离站副本真恢复）。
- **回滚**: `systemctl disable --now offsite-kopia-sync.timer`；删脚本/conf；（可选）删云端对象。
- **幂等**: 是（`rclone sync` 收敛到一致；重跑安全）。
- ⚠️ **凭据纪律**: rclone.conf 权限 600、仅 root；Vault 为真源；本文档与 git 不含任何明文密钥。

### Task 6 — 恢复演练（Definition of Done；把 TODO 里未做的做掉）
- **目标**: 证明离站副本"真的能恢复",而非薛定谔备份。
- **风险**: 低（在临时目录/临时实例操作，不动生产）。
- **步骤**:
  ```bash
  # 从离站副本拉回一个临时仓库，验证 Vault 与一个 PG 快照可读
  # (Option C) 在临时机/容器: rclone copy offsite:homelab-kopia /tmp/repo-restore
  #            kopia repository connect filesystem --path /tmp/repo-restore …
  #            kopia snapshot list | grep -E 'vault|zitadel|postgres'
  #            kopia restore <snapshot-id> /tmp/verify/    # 校验文件/pg_dump 可解析
  ```
- **验证/DoD**: 至少一次成功从**离站副本**恢复 Vault 数据 + 一个 PG dump（`pg_restore --list` 可解析）。
- **产出**: 把演练结果与命令回写 `docs/runbooks/backup-recovery.md`，并勾掉 `docs/architecture/TODO.md` 的"恢复演练"。

---

## 3. 依赖与执行顺序
```
Task 1 (在线抬 ARC) ──────────────► 可立即、独立执行
Task 2 (sanoid 快照) ─────────────► 可立即、独立执行
        │
        └──(提供一致性快照)──► Task 5
Task 4 (定路线, 默认 C) ──(G2)──► Task 5 (Option C)  |  或 → 附录 Option A(替代 Task 5)
Task 5 (离站) ──(需 G3 云凭据)──► Task 6 (恢复演练 = DoD)
Task 3 (ARC 落盘+重启) ──(G1 维护窗口)──► 可与其他需重启项合并, 时机独立
```
建议顺序: **1 → 2 →（定 G2）→（备 G3）→ 5 → 6**；**3** 择维护窗口补做。

## 4. 完成定义（DoD）
- [ ] ARC 命中率上升、宿主机内存健康（Task 1/3）。
- [ ] sanoid 按策略持续产快照、可单文件恢复（Task 2）。
- [ ] Kopia 仓库每周自动离站、量级一致（Task 5）。
- [ ] **从离站副本成功恢复 Vault + PG 各一次**（Task 6）。
- [ ] 结论回写 backup-recovery runbook & TODO。

## 5. 备份工具决策依据（rationale，精简）
- **同步≠备份**: `rclone sync` 镜像当前状态,误删/损坏/勒索会传播到副本且无法回滚 → 不能替代 Kopia。
- **Kopia 复杂度来源是 server 模式**(TLS/gRPC/NodePort/524),而它存在**几乎只为** oracle-k3s 无 NFS、经 gRPC 推备份。
- 故: 想少折腾 → **C**(Kopia + rclone 离站); 想根治 server → **A**(restic,各集群直连云,见附录); **都不选裸 rclone 全替换**。

## 附录 — Option A：迁移到 restic（仅 G2 确认后执行，替代 Task 5）
> 这是一次独立的较大迁移,**非默认路径**。仅当用户在 G2 明确选择时展开为独立子计划。要点:
1. 云端建 restic repo(B2/S3/OCI),`restic init`;repo 密码 + 云密钥入 Vault。
2. homelab: 把现有 P0/P1 快照源(pg_dump 产物 + 文件目录)改由 `restic backup` 直推云 repo(替换 Kopia CronJob 的备份步骤)。
3. **oracle-k3s: 直接 `restic backup` 到同一云 repo(经公网),不再经 homelab gRPC** —— 这是简化的核心收益。
4. 保留策略 `restic forget --keep-daily 14 --keep-weekly 8 --prune`。
5. 并行期: 新旧并跑一个保留周期,`restic restore` 演练通过后再退役 Kopia server(删 `manifests/kopia*.yaml`、NodePort、cert)。
6. 更新 `backup-recovery.md`、CLAUDE.md(Backup & Recovery、Services 表移除 Kopia 行)、`argocd/applications`。
7. 回滚: 并行期内直接切回 Kopia(未删除前零风险)。

## 6. 关联文档
- 战略母文档: `../../architecture-optimization-2026-07-04.md`
- 现有备份运维: `../runbooks/backup-recovery.md`
- 存储/NFS 约定: `CLAUDE.md` › Storage / Backup & Recovery
- 相关经验: 记忆 `storage-106-host-specs` / `nfs-hang-wedges-node` / `force-delete-nfs-pod-orphans-lock` / `vault-pod-token-empty`
