# Homelab + Oracle K3s 最优架构方案

> 日期: 2026-03-07
> 状态: In Progress (Milestone 3 ✅ Completed)
> 目标: 基于 Cilium 统一双集群架构，优化备份与灾难恢复，定义清晰的演进路径。

## 1. 执行摘要

### 1.1 当前状态

| 维度 | homelab | oracle-k3s |
|------|---------|------------|
| CNI | Cilium (eBPF + VXLAN) | Flannel (VXLAN) |
| Gateway | Traefik (Gateway API) | Traefik (Gateway API) |
| 跨集群 | Tailscale 子网路由 (Pod CIDR only) | ← |
| 可观测 | LGTM stack (中枢) | OTel Collector → homelab |
| SSO | ZITADEL (auth.meirong.dev) | oauth2-proxy (OIDC client) |
| 备份 | Kopia (NFS, 无自动调度, 无离站副本) | ❌ 无备份 |

### 1.2 目标架构

1. **双集群统一 Cilium** — 消除 CNI 异构，为 ClusterMesh 做好准备
2. **备份与恢复体系化** — Kopia 自动调度 + 应用数据分类 + 恢复 SOP
3. **Uptime Kuma SSO 监控修复** — 消除误报
4. **Gateway 标准化路线** — 短期保持 Traefik 稳定，中长期评估迁移
5. **Tailscale 职责收窄** — 管理通道为主，业务面依赖逐步降低

## 2. 应用数据分类与备份策略

### 2.1 数据分类

| 类别 | 服务 | 集群 | 存储 | 数据特征 | 备份优先级 |
|------|------|------|------|----------|-----------|
| **有状态-关键** | Vault | homelab | NFS PVC | 所有服务的 secrets 源头 | 🔴 P0 |
| **有状态-关键** | ZITADEL PostgreSQL | homelab | NFS PVC | SSO 身份数据 | 🔴 P0 |
| **有状态-重要** | Calibre-Web | homelab | NFS PVC (10Gi) | 电子书库 + 用户数据 | 🟡 P1 |
| **有状态-重要** | Miniflux PostgreSQL | oracle-k3s | NFS PVC (10Gi) | RSS 订阅与阅读历史 | 🟡 P1 |
| **有状态-重要** | KaraKeep | oracle-k3s | local-path (5Gi) | 书签与全文快照 | 🟡 P1 |
| **有状态-重要** | Gotify | homelab | NFS PVC (1Gi) | 通知历史 | 🟡 P1 |
| **有状态-一般** | Kopia repo | homelab | NFS PVC (1Ti) | 备份数据本身 | 🟢 P2 |
| **有状态-一般** | Uptime Kuma | oracle-k3s | NFS PVC (1Gi) | 监控历史 (SQLite) | 🟢 P2 |
| **有状态-一般** | Timeslot | oracle-k3s | local-path (100Mi) | 日历数据 (SQLite) | 🟢 P2 |
| **有状态-一般** | Grafana | homelab | NFS PVC (1Gi) | Dashboard (已 GitOps 管理) | 🟢 P2 |
| **有状态-一般** | Prometheus | homelab | NFS PVC (50Gi) | 指标数据 (可重建) | 🟢 P2 |
| **有状态-一般** | Loki | homelab | NFS PVC (50Gi) | 日志数据 (可重建) | 🟢 P2 |
| **无状态** | IT-Tools / PDF / Squoosh / Homepage 等 | both | 无 | 可随时重建 | ⚪ 无需备份 |

### 2.2 备份方案 — Kopia 体系

#### 当前能力

- Kopia server 运行于 homelab kopia namespace
- 仓库存储: NFS PVC 1Ti (192.168.50.106:/export)
- 访问: Web UI (backup.meirong.dev) + CLI (NodePort 31515)
- 加密: AES 仓库级加密

#### 缺失环节 (待补)

1. **自动快照调度**: 无 CronJob，全靠手动触发
2. **oracle-k3s 数据未纳入备份**: Miniflux DB / KaraKeep / Uptime Kuma / Timeslot 均未备份
3. **无离站副本**: 所有备份在同一 NFS 后端 (Proxmox 主机单点)
4. **无恢复演练**: 未验证过完整恢复流程

#### 目标状态

```
homelab NFS volumes ──→ Kopia server (定时快照) ──→ NFS repo (本地)
oracle-k3s volumes ──→ Kopia client (Tailscale) ──→ Kopia server ──→ NFS repo (本地)

(Phase 2) NFS repo ──→ Kopia 同步目标 ──→ 离站存储 (Backblaze B2 / S3)
```

#### 实施步骤

**Phase 1: 自动调度 + oracle-k3s 数据纳入**

1. 为 P0/P1 NFS volumes 配置 Kopia 快照策略:
   - Vault: 每日快照，保留 30 天
   - ZITADEL PostgreSQL: 每日快照，保留 30 天
   - Calibre-Web: 每周快照，保留 12 周
   - Gotify: 每周快照，保留 4 周
2. 在 oracle-k3s 部署 Kopia sidecar/CronJob，通过 Tailscale 连接 homelab Kopia server
3. oracle-k3s PostgreSQL (Miniflux): pg_dump CronJob → Kopia 快照
4. KaraKeep / Uptime Kuma / Timeslot (SQLite): 文件级 Kopia 快照

**Phase 2: 离站备份**

1. 在 Kopia 中添加 Backblaze B2 或 S3 兼容存储目标
2. 配置跨源同步策略 (每周完整同步)
3. 在 Vault 中管理云存储 credentials

### 2.3 恢复流程 (SOP)

#### Vault 恢复

```bash
# 1. 确认 Kopia 最新快照
kopia snapshot list --all | grep vault

# 2. 恢复到临时目录
kopia restore <snapshot-id> /tmp/vault-restore/

# 3. 替换 PVC 数据
kubectl -n vault scale deploy vault --replicas=0
# 拷贝恢复数据到 NFS mount
kubectl -n vault scale deploy vault --replicas=1

# 4. 手动 unseal
just vault-unseal
```

#### PostgreSQL (ZITADEL / Miniflux) 恢复

```bash
# 1. 获取最新 pg_dump 快照
kopia snapshot list --all | grep postgres

# 2. 恢复 dump 文件
kopia restore <snapshot-id> /tmp/pg-restore/

# 3. 恢复数据库
kubectl -n <namespace> exec -i <postgres-pod> -- \
  psql -U <user> -d <dbname> < /tmp/pg-restore/dump.sql
```

#### SQLite 应用恢复 (Calibre-Web / Uptime Kuma / Timeslot)

```bash
# 1. 停止应用
kubectl -n <namespace> scale deploy <app> --replicas=0

# 2. 恢复数据文件
kopia restore <snapshot-id> <nfs-mount-path>/

# 3. 重启
kubectl -n <namespace> scale deploy <app> --replicas=1
```

## 3. 网络架构优化

### 3.1 短期: oracle-k3s 统一到 Cilium

**目标**: 消除 CNI 异构

**步骤**:
1. 在 oracle-k3s 节点安装 Cilium (复用 homelab 配置模板)
2. 禁用 Flannel VXLAN backend
3. 验证所有 Pod 网络正常 + OTel Collector 数据流畅通
4. 验证 Traefik Gateway API 功能不受影响

**回滚**: 恢复 Flannel 配置 (K3s 内置)

### 3.2 中期: Tailscale 职责精简

当前 Tailscale 承担:
- 跨集群 Pod CIDR 路由 (10.42 ↔ 10.52)
- SSH 管理入口
- 可观测数据通道 (OTel → homelab Prometheus/Loki/Tempo)

目标:
- 保留 SSH 管理入口
- 保留可观测数据传输 (OTel → homelab 各 NodePort)
- 跨集群 Pod CIDR 路由在 ClusterMesh 上线后逐步迁移

### 3.3 长期: Cilium ClusterMesh (评估)

**前置条件**:
1. 双集群 Cilium 版本一致
2. 证书体系统一 (共享 Cilium CA)
3. Pod CIDR 无重叠 (已满足: 10.42 vs 10.52)

**收益**:
- 跨集群 Service 发现 (不需要 NodePort 暴露)
- 统一网络策略 (CiliumNetworkPolicy)
- 减少 Tailscale 子网路由依赖

**风险**: 增加控制面复杂度; homelab 单节点故障影响 ClusterMesh 可用性

## 4. Uptime Kuma SSO 监控修复

### 4.1 问题

SSO 保护域名 (book/grafana/vault/notify/backup.meirong.dev) 返回 302 → oauth2-proxy → 400。

### 4.2 修复

对 SSO 保护的监控项:
- `maxredirects: 0`
- `accepted_statuscodes: ["300-399"]`

公开域名保持 `200-299`。

### 4.3 执行

```bash
# 1. 修改 provisioner ConfigMap
vim cloud/oracle/manifests/uptime-kuma/provisioner.yaml

# 2. git push → ArgoCD PostSync 自动重建 provisioner Job

# 3. 验证
kubectl --context oracle-k3s -n personal-services exec deploy/uptime-kuma -- \
  sh -lc "sqlite3 -csv /app/data/kuma.db \"SELECT m.name,m.url,h.status,h.msg,h.time FROM monitor m LEFT JOIN heartbeat h ON h.id=(SELECT id FROM heartbeat WHERE monitor_id=m.id ORDER BY time DESC LIMIT 1) WHERE h.status != 1 ORDER BY m.name;\""
```

## 5. Gateway 标准化路线

### 5.1 决策: 短期保持 Traefik

Traefik 当前运行稳定，SSO ForwardAuth 依赖 `traefik.io/Middleware ExtensionRef`。

迁移到 Cilium Gateway 需要:
1. Envoy ext_authz 对接 oauth2-proxy (替代 ForwardAuth)
2. 逐域名灰度迁移
3. 双网关并行验证期

**当前不投入迁移，Traefik 满足所有已有需求。**

### 5.2 迁移前提 (供未来参考)

| 步骤 | 内容 |
|------|------|
| Phase A | 去 Traefik ExtensionRef 依赖，设计 ext_authz PoC |
| Phase B | 双网关并行，公开服务先行迁移 |
| Phase C | 全量切换到 Cilium Gateway，删除 Traefik |

**回滚**: DNS 层切回 Traefik Gateway，保留 Traefik manifests 至观察窗口结束。

## 6. 执行路线图

### Milestone 1: 即时修复 (本周)

- [x] 修复 Uptime Kuma SSO 域名监控误报
- [x] 确认所有服务 Cilium 迁移后运行正常
- [x] 更新项目文档 (清理过期内容)
- [x] 修复 backup.meirong.dev 无法访问 (TraefikService scheme https → 直连 HTTP Service)

### Milestone 2: 备份体系 (1-2 周)

- [x] P0 数据配置 Kopia 自动快照 (Vault / ZITADEL PostgreSQL)
- [x] P1 数据配置 Kopia 快照 (Calibre-Web / Gotify)
- [x] oracle-k3s PostgreSQL pg_dump CronJob
- [ ] 恢复演练: 验证 Vault 恢复 SOP

### Milestone 3: 统一 CNI (2-4 周)

- [x] oracle-k3s 从 Flannel 迁移到 Cilium
- [x] 验证双集群 Cilium 网络一致性
- [x] 文档更新: 双集群统一 Cilium

### Milestone 4: 增强 (4-8 周)

- [ ] 评估 Cilium ClusterMesh (PoC 先行)
- [ ] Loki 日志保留策略配置
- [ ] Alertmanager → Gotify/Telegram 告警链路

## 7. 风险矩阵

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|----------|
| NFS 后端故障 → 所有备份丢失 | 低 | 🔴 严重 | Milestone 2 离站备份 |
| oracle-k3s Cilium 迁移导致服务中断 | 中 | 🟡 中等 | 提前备份, K3s 内置 Flannel 回退 |
| ClusterMesh 控制面增加复杂度 | 中 | 🟡 中等 | PoC 验证, 不急于生产 |
| Traefik → Cilium Gateway 迁移 SSO 链路断裂 | 中 | 🔴 严重 | 短期不迁移, 保持 Traefik |

## 8. 交付物

1. ✅ 本文档: 最优架构方案
2. 📋 `docs/runbooks/backup-recovery.md`: 备份与恢复操作手册
3. 📋 `docs/architecture/TODO.md`: 更新路线图
4. 📋 项目文档全量审查与过期清理
