# 离站备份（restic copy → 云）— 执行计划

> 日期: 2026-08-03
> 状态: 📐 设计（未执行，等开云桶）
> 结论: 在现有 106 本地 restic 仓库之上，用 `restic copy` 把每晚快照增量复刻到一块云仓库
>       （OCI always-free 对象存储 或 Backblaze B2），火灾/失窃不再全损。
> 关联: [ROADMAP 开放项 #1](../../ROADMAP.md)（母文档 P0-1）、[2026-07-06 计划 Phase 5](2026-07-06-storage-local-migration-and-backup-redesign.md)、[runbooks/backup-recovery.md](../../runbooks/backup-recovery.md)

---

## 背景

现网 restic 仓库只有一份：`sftp:root@192.168.50.106:/storage/restic`（106 ZFS）。
它和 homelab 在同一物理地点 —— 火灾/失窃/106 整机故障 = 备份全灭，真数据全丢。
本计划不换主仓库（106 仍是主副本，恢复快），只加一块**异地只读副本**。

## 前置（需人工完成）

| 项 | 说明 |
|----|------|
| 开云桶 | OCI always-free 对象存储 **或** Backblaze B2（二选一，规模很小选 OCI 免费即可）。建桶 + 拿到访问凭据 |
| 凭据入 Vault | 写 `secret/homelab/offsite-restic`，与现有 `secret/homelab/restic` 平级（见下方 ExternalSecret） |

> ⚠️ 云桶能存的东西受服务商保留/删除规则约束，**不要用它替代 106 主副本**：它是兜底，不是主。
> 恢复读写资格、以及异地仓库的保留窗口，都要在有新桶后实测验证（见「验收」）。

## 方案

**`restic copy`**（官方子命令，跨仓库忠拷贝快照，连密码不同都行）在 homelab 每晚备份**之后**跑一趟，
把 homelab 今天的快照增量复刻到云仓库。oracle 侧同理（oracle 已有一份 106 仓库的操作，但 offsite 先只做 homelab，
避免一次铺两套云成本）。

- 保持 `restic forget --prune` 只作用于本地 106 仓库；`restic copy` 只读源、只写目标，互不干扰。
- 云仓库保留策略单独设宽松些（每天快照本来就小，几十 MB 级别）：`--keep-daily 14 --keep-weekly 8 --keep-monthly 12`。

## 实施步骤

### 1) 云桶 + restic/SSH 凭据

```bash
# 选 OCI：
oci os bucket create --name homelab-restic-offsite --namespace <ns>   # 用 -c (compartment) 指定
# 或 B2：在网页建 private bucket，生成 application key（读写 bucket）

# 云仓库凭据 + restic 主密码继续复用现有 secret/homelab/restic 的 repo_password。
# 新建 offsite 专用凭据（云 key + 可选 rclone.conf）写进 Vault：
vault write secret/homelab/offsite-restic \
    restic_password="$(cat /path/to/local-restic-password)" \
    rclone_conf_b64="$(base64 -w0 rclone.conf)"
```

### 2) ExternalSecret（接 ESO）

在 `backup/overlays/homelab/` 加 `offsite-external-secret.yaml`，模式照抄现有 `external-secret.yaml`
（owner refs 一致、`secretKey` 映射到 `RCLONE_CONF_B64` / `RESTIC_PASSWORD`），指向
`secret/homelab/offsite-restic`。**不要**塞进现有 restic-backup Secret（那条链路栽过同类跟头，
见 `open-notebook-external-secret.yaml` 头部注释：一个 path 失败会拖垮整夜备）。

### 3) backup-script.yaml 追加 offsite 段

在现有 `restic forget/prune` 之后、`snapshots` 之前插入（源仓库不变，目标走 rclone 后端）：

```bash
# --- 3b) offsite copy（云仓库，失败只 warn 不影响本地夜备）---
export RCLONE_CONF="$(base64 -d /creds-offsite/RCLONE_CONF_B64 2>/dev/null || true)"
export RESTIC_REPOSITORY="rclone:offsite:homelab-offsite"
if [ -z "$RCLONE_CONF" ]; then
  echo "[warn] offsite restic creds absent — skipping offsite copy (local backup intact)"
else
  restic snapshots >/dev/null 2>&1 || restic init   # 首次建云仓库
  restic copy --from-repo "sftp:root@192.168.50.106:/storage/restic" \
      --host homelab --tag nightly \
      --keep-daily 14 --keep-weekly 8 --keep-monthly 12
fi
```

> 注意 `RESTIC_REPOSITORY` 在脚本里是导出变量，上面会临时切换到 rclone 目标；**跑完置回 sftp 源**，
> 避免后续 `snapshots` 打到云仓库。具体落地时把 `restic copy` 的源/目标用 `--from-repo` + 当前 `RESTIC_REPOSITORY`
> 显式写清，不依赖导出变量隐式切换。

### 4) cronjob-patch.yaml 挂载

在 `cronjob-patch.yaml` 现有卷/挂载基础上，给 backup Pod 加：
- `rclone.conf` 的 secret 卷（来自上面 ExternalSecret，optional）
- 环境 `RCLONE_CONF_MOUNT` 路径调整成脚本能读到的位置

## 验收（云桶开好后）

```bash
# 首次成功 → 云仓库有快照
kubectl --context k3s-homelab -n backup logs -l app=restic-backup --tail=50
# 异地可恢复性抽查（从工作机直连云仓库，非经集群）：
restic -r rclone:offsite:homelab-offsite -p <repo_password> snapshots --host homelab --latest 1
restic -r rclone:offsite:homelab-offsite -p <repo_password> restore latest:/ --target /tmp/offsite-restore-test
```

通过判定：云仓库 `snapshots --latest` 能看到今天 homelab 快照；restore 出来 `/tmp/offsite-restore-test` 有 `vault.snap` 等文件。
再在 Vault 里配一条 restic 云目标不可达的告警（复用现有 `storage-alerts.yaml` 模式，或 dead-man's switch 链路）。

## 回滚

offsite 段整体是「失败只 warn」——出事直接删掉第 3 步那段即可，本地备份不受影响。
云桶不再需要时可 `oci os object bulk-delete`/B2 删桶，删的是副本不是主仓库。
