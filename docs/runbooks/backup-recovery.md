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

**关键认知（2026-06-20 实测纠正）**：kopia 客户端 `repository connect server` **强制要求 `https://`**——
`http://` 被直接拒绝（`invalid server address, must be 'https://host:port' or 'unix+https://'`）。
所以一个 `--insecure`（纯 HTTP、无 TLS）的 kopia 服务器 **根本无法被 kopia CLI/备份客户端连接**
（`https://`→TLS 握手失败；`http://`→客户端拒绝）。`--insecure` 只够 **web UI**（浏览器经 gateway，
TLS 在 Cloudflare 边缘终结）。**oracle 备份（CLI 客户端）要恢复，kopia 服务器必须提供 TLS。**
（注：曾误试"把 server_url 改 http"——无效，已回退为 https。）

**修复（= 给 kopia 服务器恢复 TLS；多步、待实施，见加固路线图 #0）**：
1. `manifests/kopia.yaml`：`--insecure` → `--tls-generate-cert`（自签；cert 须落在 kopia 的持久化
   config 目录/PVC，否则每次重启 fingerprint 变）或挂载固定 cert（`--tls-cert-file/--tls-key-file`）。
2. 取新 cert SHA256 fingerprint，更新 Vault（ESO→`kopia-backup-secret`）：
   ```bash
   ROOT=$(jq -r .root_token k8s/helm/vault-keys.json)
   kubectl --context k3s-homelab -n vault exec -i vault-0 -- env VAULT_TOKEN="$ROOT" \
     vault kv patch secret/homelab/kopia server_url=https://100.94.186.7:31515 server_fingerprint=<新sha256>
   # ⚠️ key 用下划线 server_url / server_fingerprint（ESO remoteRef.property 实名；另有 repo-password）。
   ```
3. **web UI 的 gateway HTTPRoute 后端改 HTTPS/h2c**：给 kopia Service 加 `appProtocol`（同 ZITADEL 套路，
   见 `zitadel-console-grpc-404.md`），否则 kopia 转 TLS 后浏览器访问 `backup.meirong.dev` 会断。
4. 连接脚本已是 scheme 自适应（仅 https 传 fingerprint）——恢复 TLS 后**无需再改 oracle 清单**。
5. 验证：oracle 跑 debug job → `https://…` 带 fingerprint 连上 → `Snapshot status` 成功。

## 加固路线图 (Roadmap)

按优先级：

0. **🔴 恢复 kopia 服务器 TLS（解除 oracle 备份阻塞，最高优先）**：见上方故障排查"修复"。`--insecure`
   服务器无法被 kopia CLI 连接 → oracle 的 Miniflux PG / KaraKeep / Uptime Kuma / Timeslot **当前未在备份**。
   步骤：kopia 加 TLS(`--tls-generate-cert`，cert 持久化) → 更新 Vault server_url(https)+server_fingerprint →
   gateway 后端改 h2c/appProtocol。**这是目前唯一的真实数据风险，应尽快做。**
1. **备份成功监控**（高）：当前只有弱信号的 `KubeJobFailed`（且混在历史失败/误报里——oracle 失败多日才被发现）。增设"**备份新鲜度**"告警——基于 kopia 最近成功快照时间（或 CronJob `last successful` > 26h 告警），经现有 Alertmanager→Gotify。
2. **离站副本**（高）：所有快照在同一 NFS 主机（`192.168.50.106`），主机/盘损即全失。规划一份异地副本（Kopia 支持多 repo / rclone 到对象存储 B2/R2/S3）。
3. **完整恢复演练**（中）：至少演练一次 Vault + 一个 PG 的端到端恢复，验证 RTO/RPO 与本 runbook 步骤。
