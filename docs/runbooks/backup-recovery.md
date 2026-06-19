# Backup & Recovery Runbook

> Last updated: 2026-06-19

## Overview

备份体系基于 Kopia，运行于 homelab `kopia` namespace。

### 数据优先级

| Priority | 服务 | 集群 | 存储类型 | 备份方式 |
|----------|------|------|----------|---------|
| 🔴 P0 | Vault | homelab | NFS PVC | 文件级快照 |
| 🔴 P0 | ZITADEL PostgreSQL | homelab | NFS PVC | pg_dump + 快照 |
| 🟡 P1 | Calibre-Web | homelab | NFS PVC | 文件级快照 |
| 🟡 P1 | Miniflux PostgreSQL | oracle-k3s | NFS PVC | pg_dump + 快照 |
| 🟡 P1 | KaraKeep | oracle-k3s | local-path | 文件级快照 |
| 🟡 P1 | Gotify | homelab | NFS PVC | 文件级快照 |
| 🟢 P2 | Uptime Kuma | oracle-k3s | NFS PVC | SQLite 文件快照 |
| 🟢 P2 | Timeslot | oracle-k3s | local-path | SQLite 文件快照 |

## Kopia 访问

### Web UI

```
https://backup.meirong.dev
```

SSO 保护。用于浏览快照、管理策略。

### CLI

```bash
kopia repository connect server \
  --url=https://10.10.10.10:31515 \
  --server-cert-fingerprint=<fingerprint> \
  --override-username=admin
```

> 密码在 Vault `secret/homelab/kopia` → `password`

获取 TLS 指纹:
```bash
# From k8s/helm/
just kopia-fingerprint
```

## 恢复流程

### Vault 恢复 (P0)

```bash
# 1. 列出快照
kopia snapshot list --all | grep vault

# 2. 恢复到临时目录
kopia restore <snapshot-id> /tmp/vault-restore/

# 3. 停止 Vault
kubectl --context k3s-homelab -n vault scale deploy vault --replicas=0

# 4. 将恢复数据拷贝到 NFS mount
#    NFS path: 192.168.50.106:/storage/nfs/k8s/vault-*  (provisioner 子目录, 见 kopia-backup.yaml)
#    确认 PVC 对应的 NFS 子目录

# 5. 重启 Vault
kubectl --context k3s-homelab -n vault scale deploy vault --replicas=1

# 6. 手动 unseal
cd k8s/helm && just vault-unseal

# 7. 验证
kubectl --context k3s-homelab -n vault exec deploy/vault -- vault status
```

### PostgreSQL 恢复 (ZITADEL / Miniflux)

```bash
# 1. 列出快照
kopia snapshot list --all | grep postgres

# 2. 恢复 dump 文件
kopia restore <snapshot-id> /tmp/pg-restore/

# 3. 恢复 ZITADEL DB
kubectl --context k3s-homelab -n zitadel exec -i <postgres-pod> -- \
  psql -U zitadel -d zitadel < /tmp/pg-restore/zitadel.sql

# 4. 恢复 Miniflux DB (oracle-k3s)
kubectl --context oracle-k3s -n rss-system exec -i <postgres-pod> -- \
  psql -U miniflux -d miniflux < /tmp/pg-restore/miniflux.sql

# 5. 重启相关应用
kubectl --context k3s-homelab -n zitadel rollout restart deploy/zitadel
kubectl --context oracle-k3s -n rss-system rollout restart deploy/miniflux
```

### SQLite 应用恢复 (Calibre-Web / Uptime Kuma / Timeslot)

```bash
# 1. 停止应用
kubectl --context <context> -n <namespace> scale deploy <app> --replicas=0

# 2. 恢复数据文件
kopia restore <snapshot-id> <target-path>/

# 3. 重启
kubectl --context <context> -n <namespace> scale deploy <app> --replicas=1

# 4. 验证
kubectl --context <context> -n <namespace> get pods
```

## 灾难恢复检查清单

完整集群恢复顺序:

1. ✅ Proxmox VM 重建 (`proxmox/terraform/`)
2. ✅ K3s 安装 (`k8s/ansible/`)
3. ✅ NFS Provisioner (`just setup-nfs-provisioner`)
4. ✅ Vault 恢复 + unseal
5. ✅ ESO 安装 → Vault secrets 同步
6. ✅ ArgoCD 安装 (`just deploy-argocd`)
7. ✅ ArgoCD 同步所有 Application
8. ✅ ZITADEL PostgreSQL 恢复
9. ✅ 验证 SSO 链路 (auth.meirong.dev)
10. ✅ 验证所有服务可达性

## 自动备份调度

### homelab 集群 (CronJob: `kopia` namespace)

每天 02:00 UTC 自动执行，备份内容:

| 服务 | 方式 | 标签 |
|------|------|------|
| Vault (data + audit) | 文件级 cp → Kopia snapshot | `service:vault`, `priority:P0` |
| ZITADEL PostgreSQL | pg_dump → Kopia snapshot | `service:zitadel-postgresql`, `priority:P0` |
| Calibre-Web config | 文件级 cp → Kopia snapshot | `service:calibre-web`, `priority:P1` |
| Gotify | 文件级 cp → Kopia snapshot | `service:gotify`, `priority:P1` |

清单文件: `k8s/helm/manifests/kopia-backup.yaml`

```bash
# 查看 CronJob 状态
kubectl --context k3s-homelab -n kopia get cronjob kopia-backup

# 手动触发
kubectl --context k3s-homelab -n kopia create job --from=cronjob/kopia-backup kopia-backup-manual

# 查看最近 Job 日志
kubectl --context k3s-homelab -n kopia logs job/kopia-backup-manual -c kopia-snapshot
```

### oracle-k3s 集群 (CronJob: `rss-system` + `personal-services`)

**rss-system** — 每天 03:00 UTC:

| 服务 | 方式 |
|------|------|
| Miniflux PostgreSQL | pg_dump → Kopia snapshot |
| KaraKeep (SQLite) | 文件级 cp → Kopia snapshot |

**personal-services** — 每天 03:30 UTC:

| 服务 | 方式 |
|------|------|
| Uptime Kuma (SQLite) | 文件级 cp → Kopia snapshot |
| Timeslot (SQLite) | 文件级 cp → Kopia snapshot |

```bash
# 查看 CronJob 状态
kubectl --context oracle-k3s -n rss-system get cronjob kopia-backup
kubectl --context oracle-k3s -n personal-services get cronjob kopia-backup
```

## 当前限制

- ⚠️ 无离站副本 (所有备份在 NFS 后端同一主机)
- ⚠️ 未做过完整恢复演练
- ⚠️ ZITADEL pg_dump 需要 Vault 中有 `secret/homelab/zitadel` → `db-password`
- ⚠️ **备份失败监控薄弱**：oracle 备份曾连续失败多日才被发现（见下方故障排查）。`KubeJobFailed` 告警虽会触发，但混在历史失败 Job/误报里、信号弱 → 需专门的"备份成功"信号（见加固路线图）。

详见 [架构优化方案 - 备份策略](../plans/2026-03-07-homelab-oracle-architecture-optimization.md#2-应用数据分类与备份策略)

## 故障排查 (Troubleshooting)

### oracle 备份持续失败：`tls: first record does not look like a TLS handshake` (2026-06-19)

**现象**：oracle-k3s 的 `rss-system` / `personal-services` kopia 备份 CronJob 每次 `Failed`（Miniflux PG / KaraKeep / Uptime Kuma / Timeslot 多日未成功备份）；homelab 备份正常。

**根因**：
- homelab 备份走 `kopia repository connect from-config`（挂载的 `repository.config` **直连 NFS 仓库**），不经服务器 gRPC → 不受影响。
- oracle 是远程集群、无 NFS，**只能经 kopia 服务器 gRPC**（`$KOPIA_SERVER_URL`，NodePort `100.94.186.7:31515` → 容器 `51515`）。
- kopia 服务器实际跑在 **`--insecure --address=0.0.0.0:51515`（明文，无 TLS、无 cert 挂载）**（为 web UI 经 Cloudflare Tunnel 走 HTTP gateway 后端）。
- 而 oracle 的 `KOPIA_SERVER_URL` 仍是 **`https://…:31515`** + 传 `--server-cert-fingerprint` → 客户端发 TLS、服务器回明文 → 握手失败。

**定位命令**：
```bash
kubectl --context oracle-k3s -n rss-system create job --from=cronjob/kopia-backup kopia-debug
kubectl --context oracle-k3s -n rss-system logs job/kopia-debug -c kopia-snapshot   # 看 TLS 报错
kubectl --context k3s-homelab -n kopia get deploy kopia -o jsonpath='{.spec.template.spec.containers[0].args}'  # 确认 --insecure
kubectl --context k3s-homelab -n kopia get svc kopia                                # 51515:31515/TCP
```

**修复**（已实施）：
1. 连接命令改为 **scheme 自适应**——仅当 `KOPIA_SERVER_URL` 以 `https://` 开头才传 `--server-cert-fingerprint`（`cloud/oracle/manifests/{rss-system,personal-services}/backup-cronjob.yaml`）。
2. Vault `secret/homelab/kopia` 的 `server-url` 由 `https://` 改为 **`http://100.94.186.7:31515`**（ESO → `kopia-backup-secret`）：
   ```bash
   ROOT=$(jq -r .root_token k8s/helm/vault-keys.json)
   kubectl --context k3s-homelab -n vault exec -i vault-0 -- \
     env VAULT_TOKEN="$ROOT" vault kv patch secret/homelab/kopia server_url=http://100.94.186.7:31515
     # ⚠️ Vault key 是 server_url（下划线），不是 server-url —— ESO remoteRef.property 用的就是下划线名
     #    （另两个：server_fingerprint、repo-password）。确认：kubectl get externalsecret kopia-backup-secret -o jsonpath='{.spec.data[*].remoteRef.property}'
   ```
3. 安全性：oracle→homelab 全程经 **Tailscale（WireGuard 加密）**，明文 kopia 流量在隧道内已加密。
4. 验证：`git push`（ArgoCD 同步 cronjob）+ ESO 刷新 secret 后，手动跑 debug job 应成功；之后每日 CronJob 转 `Complete`。

> 切回 TLS（更"正"的做法）只需把 Vault `server-url` 改回 `https://` —— 连接脚本会自动重新带上 fingerprint（无需改清单）。但需同时给 kopia 服务器配 TLS（且 web UI 经 gateway 那条 HTTP 后端要改 h2c/HTTPS），见加固路线图。

## 加固路线图 (Roadmap)

按优先级：

1. **备份成功监控**（高）：当前只有弱信号的 `KubeJobFailed`。增设"**备份新鲜度**"告警——基于 kopia 最近成功快照时间（或 CronJob `last successful` > 26h 告警），经现有 Alertmanager→Gotify。让"连续失败多日"无法再被忽略。
2. **离站副本**（高）：所有快照在同一 NFS 主机（`192.168.50.106`），主机/盘损即全失。规划一份异地副本（Kopia 支持多 repo / rclone 到对象存储 B2/R2/S3）。
3. **kopia 服务器恢复 TLS**（中）：现 `--insecure` 把明文 gRPC 暴露在 NodePort 31515（LAN 可达，仅 Tailscale 内才加密）。恢复 TLS 后 NodePort 直接走 TLS；代价是 web UI 经 gateway 的 HTTP 后端要改 h2c/HTTPS。
4. **完整恢复演练**（中）：至少演练一次 Vault + 一个 PG 的端到端恢复，验证 RTO/RPO 与本 runbook 步骤。
