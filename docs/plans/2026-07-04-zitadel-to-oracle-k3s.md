# ZITADEL 迁移至 oracle-k3s 计划

> 日期: 2026-07-04
> 状态: ✅ 已迁移并验证（2026-07-06）——oracle ZITADEL serving `auth.meirong.dev`（OIDC + console 全通）。**仅剩 homelab 退役**（保留作回滚，待真实浏览器登录确认后删）。执行记录见 [2026-07-06 计划](2026-07-06-storage-local-migration-and-backup-redesign.md) §Phase 3b Task 8。
> 动机已从"106 不可用"升级为**故障域分离**：SSO 可用性 > 家里笔记本，homelab 整机故障时 OIDC 仍在线。ZITADEL PG 落 oracle **local-path**（比 NFS 更适合 PG 同步写）。
> 背景: homelab NFS 单点依赖 + 单故障域集中（Vault/身份/GitOps/告警同住一台笔记本）

## 🔎 执行前发现（2026-07-06，做前必读）

实测当前部署，比原计划复杂，**前置条件**如下（这也是它值得单独专门做的原因）：
- **ZITADEL v4.10.1 + Login V2**：`zitadel` + `zitadel-login` 两个 Deployment + init/setup Job，经 **k3s HelmChart CRD**（`helm.cattle.io/v1`，chart `zitadel` 9.24.0）部署。auth 路由分流：`/ui/v2/login`→`zitadel-login:3000`，`/`→`zitadel:8080`（见 homelab `gateway.yaml`）。
- **⚠️ 前置1 — oracle Cilium**：`enable-gateway-api-app-protocol=false`（homelab=true）。不开则 ZITADEL **console v1 gRPC 404**（OIDC 登录不受影响，仅管理台）。需 helm upgrade oracle cilium 开启（`gatewayAPI.enableAppProtocol=true`）+ 重启 Cilium——**集群级变更**。可在 OIDC 验证通过后再做（console 非关键路径）。
- **⚠️ 前置2 — PG chart**：homelab PG 用 **Bitnami `postgresql` 12.10.0**（`bitnamilegacy/postgresql:15.4` 镜像）。Bitnami 在清退旧 chart，oracle 可能拉不到 12.10.0 → 建议 oracle 改用**纯 `postgres:15` Deployment**（复刻 rss-postgres 模式）承接 pg_dump，避开 chart 依赖。
- **masterkey 完整性（关键）**：oracle 的 ExternalSecrets 直接读 **`secret/homelab/zitadel`**（同源，masterkey/db-password 字节一致）——**切勿复制**（masterkey 差一字节则 DB 内所有加密密钥不可解 → 全 SSO 崩）。同源读零风险。
- **数据**：homelab zitadel DB = 16MB / 147 表 / 8 schema（adminapi/auth/cache/eventstore/logstore/projections/queue/system）；`pg_dump --no-owner --no-privileges` = 807KB / 9642 行（已实测可导）。PG 现在 NFS 上 **OOM/liveness 反复重启（exitCode 137，22 次）**——迁 local-path + 加内存即修复，也是迁移动机。
- **去风险顺序**：oracle 部署 PG(纯 Deployment)+ZITADEL(dormant) → 恢复 pg_dump → 内部验证(health + OIDC discovery, port-forward) → CF `auth` 切 oracle（同 Gotify 模式，`just apply` 两侧）→ **验证真实 OIDC 登录**(ArgoCD/Grafana) → 开 oracle Cilium app-protocol(console) → 退役 homelab。homelab 全程保留作回滚（DNS 切回）。CF token 见记忆 [[cloudflare-terraform-token-in-env]]。

## 1. 迁移动机

- 消除 ZITADEL 对 106 NFS 的单点依赖（当前 PostgreSQL 8Gi PVC 使用 `nfs-client` StorageClass）
- 利用 oracle-k3s 的 `local-path` 存储（比 NFS 更适合 PG 的同步写入模式）
- 双集群冗余：即使 homelab 整体不可用，OIDC 认证仍正常

## 2. 当前依赖关系

```
ZITADEL (homelab)
├── PostgreSQL 8Gi (nfs-client PVC → 106 NFS)
├── Vault secret/homelab/zitadel (masterkey, db-password)
│   └── Vault PVC 也在 106 NFS 上 (连锁依赖)
└── auth.meirong.dev
    ├── Cloudflare DNS CNAME → homelab tunnel
    ├── Cloudflare Tunnel ingress → homelab Gateway
    └── HTTPRoute → ZITADEL Service (homelab)
```

下游 OIDC 客户端（配 `https://auth.meirong.dev`，域名不变则无需改动）:
- Miniflux (oracle-k3s)
- Bifrost oauth2-proxy (homelab)
- ArgoCD (homelab)

## 3. 前置条件

- [ ] 106 服务器恢复，NFS 可用
- [ ] Vault 恢复，ZITADEL 对应 secret 可读
- [ ] 从 homelab ZITADEL PostgreSQL 成功 pg_dump

## 4. 迁移步骤

### Phase 1 — 在 oracle-k3s 上部署 ZITADEL

#### 4.1 密钥准备

在 Vault 中创建 Oracle 专用路径:
```
secret/oracle-k3s/zitadel
├── master-key: <同值>
└── db-password: <同值>
```

#### 4.2 创建 manifests

在 `cloud/oracle/manifests/` 下新增:
```
zitadel/
├── namespace.yaml
├── zitadel-db.yaml          # PostgreSQL HelmChart, storageClass: local-path, 8Gi
├── zitadel.yaml             # ZITADEL HelmChart
├── external-secrets.yaml    # ExternalSecrets for masterkey + postgres auth
├── gateway-route.yaml       # HTTPRoute: auth.meirong.dev → ZITADEL
└── kustomization.yaml       # 加入 kustomize 树
```

关键配置变更（vs homelab 版）:

| 项目 | homelab | oracle-k3s |
|------|---------|------------|
| StorageClass | `nfs-client` | `local-path` |
| Vault key path | `secret/homelab/zitadel` | `secret/oracle-k3s/zitadel` |
| ESO ClusterSecretStore | 同集群 Vault | `vault-backend` (Tailscale → homelab Vault) |
| ExternalDomain | `auth.meirong.dev` | 不变 |
| Gateway parentRef | `homelab-gateway` | `oracle-gateway` |

#### 4.3 部署 + 数据导入

```bash
# 1. 在 homelab 上导出数据
kubectl exec -n zitadel deploy/zitadel-db-postgresql -- \
  pg_dump -U zitadel zitadel > zitadel-dump.sql

# 2. 在 oracle-k3s 上部署
kubectl apply -k cloud/oracle/manifests/

# 3. 等待 PostgreSQL 就绪后导入数据
kubectl exec -n zitadel deploy/zitadel-db-postgresql -- \
  psql -U zitadel -d zitadel < zitadel-dump.sql
```

### Phase 2 — DNS 切换

#### 2.1 流量切换方案

```mermaid
flowchart LR
    subgraph 迁移前
        CF[Cloudflare Edge] -->|auth.meirong.dev| T1[homelab tunnel]
        T1 --> GW1[homelab Gateway]
        GW1 --> Z1[ZITADEL homelab]
    end
    subgraph 迁移后
        CF2[Cloudflare Edge] -->|auth.meirong.dev| T2[oracle-k3s tunnel]
        T2 --> GW2[oracle Gateway]
        GW2 --> Z2[ZITADEL oracle-k3s]
    end
```

#### 2.2 操作步骤

1. **在 Cloudflare Dashboard 中**：
   - oracle-k3s tunnel ingress 添加 `auth.meirong.dev` → `http://cilium-gateway-oracle-gateway.kube-system.svc:80`
   - homelab tunnel ingress 暂时保留 `auth.meirong.dev`

2. **切换 DNS**：
   - `auth.meirong.dev` 的 CNAME 从 `homelab-tunnel.cfargotunnel.com` 改为 `oracle-tunnel.cfargotunnel.com`
   - TTL 1 分钟（已配），等待传播

3. **验证**：
   - `curl -sI https://auth.meirong.dev` 返回 200
   - OIDC discovery endpoint (`/.well-known/openid-configuration`) 正常
   - 任一 OIDC client 能完成登录（Miniflux 或 Bifrost）

4. **清理**：
   - 从 homelab tunnel ingress 移除 `auth.meirong.dev`
   - 验证 homelab 上的 ZITADEL 不再收到流量

### Phase 3 — 清理 homelab ZITADEL

- 删除 `k8s/helm/manifests/zitadel.yaml`
- 删除 homelab 的 ZITADEL PostgreSQL PVC（数据已迁移）
- 从 `argocd/applications/zitadel.yaml` 中移除或标注为已弃用
- 从 `k8s/helm/manifests/gateway.yaml` 移除 `auth.meirong.dev` 的 HTTPRoute

## 5. 风险与缓解

| 风险 | 影响 | 缓解 |
|------|------|------|
| pg_dump 后到 DNS 切换间的增量数据丢失 | 用户/应用配置变更丢失 | ZITADEL 非高频写入；可在切换前暂停外部登录，或将 DNS TTL 临时设低后再做最终 pg_dump |
| Vault 在 106 恢复后仍不可用 | ESO 无法同步 secret | 手动创建 K8s Secret（bootstrap 模式） |
| OIDC 签发 key 变更 | 现有 JWT token 失效，所有已登录用户需要重新认证 | 迁移时确认 ZITADEL masterkey 一致（同值），PG 数据库一致（含加密 key），则签发 key 不变 |
| oracle-k3s Cloudflare Tunnel 不含 `auth.meirong.dev` ingress | 流量到了 tunnel 但返回 404 | 在 Cloudflare Dashboard 手动添加后再切 DNS |

## 6. 参考文档

- ZITADEL 当前部署: `k8s/helm/manifests/zitadel.yaml`
- ZITADEL Helm values: `k8s/helm/values/postgresql-values.yaml`
- oracle-k3s 已有模式参考: `cloud/oracle/manifests/rss-system/miniflux.yaml` (PG + app 部署)
- oracle-k3s Cloudflare Tunnel: `cloud/oracle/manifests/base/cloudflare-tunnel.yaml`
- homelab Cloudflare Tunnel 配置: `cloudflare/terraform/variables.tf` (`ingress_rules`)
- 架构总览: `docs/README.md`
