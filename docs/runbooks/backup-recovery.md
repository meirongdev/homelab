# Backup & Recovery Runbook

> Last updated: 2026-03-07

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
#    NFS path: 192.168.50.106:/export/vault-*
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

详见 [架构优化方案 - 备份策略](../plans/2026-03-07-homelab-oracle-architecture-optimization.md#2-应用数据分类与备份策略)
