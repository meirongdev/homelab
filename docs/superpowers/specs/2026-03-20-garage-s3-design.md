# Garage S3 部署设计文档

**日期**: 2026-03-20
**状态**: 已批准
**目标**: 在 homelab K3s 集群部署 Garage S3 兼容对象存储，为 Loki、Tempo、Kopia 及未来服务提供 S3 后端

---

## 背景与动机

当前所有存储均为文件系统模式：

| 服务 | 当前存储 | 问题 |
|------|----------|------|
| Loki | NFS PVC (filesystem) | NFS 单点故障，扩展性差 |
| Tempo | NFS PVC (local) | 同上 |
| Kopia | NFS PVC (1Ti) | 无离站副本，所有备份在同一 NFS 主机 |
| 未来服务 | — | 无 S3 接口可用 |

引入 Garage 后，上层服务统一通过 S3 API 访问对象存储，NFS 仍作为 Garage 的底层持久化介质。

---

## 架构设计

### 部署位置

- **集群**: homelab（K3s @ 10.10.10.10）
- **namespace**: `garage`
- **方式**: 原生 YAML StatefulSet（与 calibre-web/gotify/kopia 约定一致）

### K8s 资源

| 资源 | 名称 | 说明 |
|------|------|------|
| Namespace | `garage` | 独立命名空间 |
| ConfigMap | `garage-config` | 存放 `garage.toml`（不含 secret 字段，见下文） |
| Secret | `garage-rpc-secret` | 由 ESO 从 Vault 同步，含 `rpc_secret` |
| StatefulSet | `garage` | 1 副本，`dxflrs/garage:v1.0` |
| PVC | `garage-data` | 100Gi，`nfs-client` StorageClass，`accessModes: ReadWriteMany` |
| Service | `garage-s3` | ClusterIP :3900，S3 API（集群内 + 外部） |
| Service | `garage-rpc` | ClusterIP :3901，内部 RPC |

> **garage-admin Service 暂不创建**：所有 bootstrap 和管理操作通过 `kubectl exec -n garage garage-0 -- garage ...` 完成，ClusterIP :3903 无消费方，避免不必要的暴露。如需 Prometheus 抓取管理指标，届时再添加。

### Garage 配置（garage.toml — ConfigMap）

```toml
replication_mode = "none"   # 单节点，无需复制
metadata_dir = "/data/meta"
data_dir = "/data/objects"

[s3_api]
s3_region = "homelab"
api_bind_addr = "0.0.0.0:3900"
```

> **`rpc_secret` 处理**：这是一个必填的 32 字节 hex secret，**不能放在 ConfigMap 中**。存入 Vault `secret/homelab/garage/rpc` (key: `rpc_secret`)，通过 ESO ExternalSecret 同步为 K8s Secret `garage-rpc-secret`，以环境变量 `GARAGE_RPC_SECRET` 注入 StatefulSet（Garage 支持从环境变量读取配置字段覆盖）。

### 外部访问（HTTPRoute）

HTTPRoute **放在 `garage` namespace**（与 calibre-web 在 `personal-services`、grafana 在 `monitoring` 的约定一致），不加入 `gateway.yaml`。

ReferenceGrant 放在 `garage` namespace，语义为：允许来自 `garage` namespace 的 HTTPRoute 引用本 namespace 的 Service：

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-gateway-to-garage
  namespace: garage
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: garage
  to:
    - group: ""
      kind: Service
```

- Cloudflare `terraform.tfvars`：新增 `s3.meirong.dev`
- Uptime Kuma `MONITORS`：新增 `{"name": "Garage S3", "url": "https://s3.meirong.dev"}`

---

## Bootstrap 流程

**性质**：一次性手动操作（类似 Vault init/unseal），**不由 ArgoCD 管理**。
**位置**：`k8s/helm/justfile` 新增 `bootstrap-garage` target。

### Justfile Target 结构（遵循项目风格，Chinese 注释）

```just
# 初始化 Garage：分配 layout、创建 bucket 和 key，写入 Vault
bootstrap-garage:
    #!/usr/bin/env bash
    set -euo pipefail
    # 1. 获取节点 ID
    NODE_ID=$(kubectl exec -n garage garage-0 -- garage node id -q)
    echo "Node ID: $NODE_ID"

    # 2. 分配 layout（单节点 zone=dc1，capacity token=1）
    kubectl exec -n garage garage-0 -- garage layout assign -z dc1 -c 1 "$NODE_ID"
    kubectl exec -n garage garage-0 -- garage layout apply --version 1

    # 3. 创建 bucket
    for BUCKET in loki-chunks loki-ruler tempo-traces kopia-backup; do
        kubectl exec -n garage garage-0 -- garage bucket create "$BUCKET" || true
    done

    # 4. 创建 per-service key 并授权（最小权限）
    for SVC in loki tempo kopia; do
        kubectl exec -n garage garage-0 -- garage key create "$SVC" || true
    done

    # loki → loki-chunks + loki-ruler (读写)
    kubectl exec -n garage garage-0 -- garage bucket allow --read --write --bucket loki-chunks --key loki
    kubectl exec -n garage garage-0 -- garage bucket allow --read --write --bucket loki-ruler --key loki

    # tempo → tempo-traces (读写)
    kubectl exec -n garage garage-0 -- garage bucket allow --read --write --bucket tempo-traces --key tempo

    # kopia → kopia-backup (读写)
    kubectl exec -n garage garage-0 -- garage bucket allow --read --write --bucket kopia-backup --key kopia

    # 5. 导出凭证（手动复制到 Vault）
    echo "=== 请将以下凭证写入 Vault ==="
    for SVC in loki tempo kopia; do
        echo "--- $SVC ---"
        kubectl exec -n garage garage-0 -- garage key info "$SVC" --show-secret
    done
    echo "Vault 路径: secret/homelab/garage/{loki,tempo,kopia}"
    echo "Keys: access_key_id, secret_access_key"
```

### Bucket 与 Key 权限矩阵

| Key | loki-chunks | loki-ruler | tempo-traces | kopia-backup |
|-----|-------------|------------|--------------|--------------|
| loki | RW | RW | — | — |
| tempo | — | — | RW | — |
| kopia | — | — | — | RW |

---

## Secrets 管理

### Vault 路径约定

> **说明**：本服务使用三级路径 `secret/homelab/garage/<sub-key>`，是对 `secret/homelab/<service>` 扁平约定的有意扩展，原因是 Garage 需要为多个子服务分别存储凭证，共享一个前缀有利于权限管理和可读性。

```
secret/homelab/garage/rpc    → rpc_secret
secret/homelab/garage/loki   → access_key_id, secret_access_key
secret/homelab/garage/tempo  → access_key_id, secret_access_key
secret/homelab/garage/kopia  → access_key_id, secret_access_key
```

### ExternalSecret 分发

ExternalSecret **必须创建在消费服务所在的 namespace**（ESO 不支持跨 namespace 同步到目标 namespace）。因此拆分为独立文件：

| 文件 | Namespace | 同步的 Secret |
|------|-----------|---------------|
| `k8s/helm/manifests/garage-external-secret.yaml` | `garage` | `garage-rpc-secret`（StatefulSet 用） |
| `k8s/helm/manifests/garage-loki-secret.yaml` | `monitoring` | `garage-loki-credentials` |
| `k8s/helm/manifests/garage-tempo-secret.yaml` | `monitoring` | `garage-tempo-credentials` |
| `k8s/helm/manifests/garage-kopia-secret.yaml` | `kopia` | `garage-kopia-credentials` |

所有文件加入 `argocd/applications/vault-eso.yaml` include 列表，ArgoCD 自动同步。

---

## ArgoCD 集成

新建 `argocd/applications/garage.yaml`：
- source: `k8s/helm/manifests/garage.yaml`（含 Namespace、ConfigMap、StatefulSet、Services、HTTPRoute、ReferenceGrant）
- `destination.namespace: garage`
- `syncPolicy: automated + selfHeal + CreateNamespace=true`
- PVC 加 `argocd.argoproj.io/sync-options: Prune=false`
- 加入标准 `ignoreDifferences` 块（完全照抄 `argocd/applications/kopia.yaml` 中的块，针对 ESO 在 `ExternalSecret` CR 上注入的默认字段：`conversionStrategy`、`decodingStrategy`、`metadataPolicy`、`deletionPolicy`）

---

## 服务迁移计划（部署后分阶段执行）

### Phase 1：Loki 迁移到 S3

更新 `k8s/helm/values/loki.yaml`：
- `loki.storage.type: s3`
- `loki.schemaConfig.configs[].object_store: s3`
- 配置 S3 endpoint（`http://garage-s3.garage.svc.cluster.local:3900`）、bucket、credentials（引用 `garage-loki-credentials` Secret）
- **Loki compactor 注意**：切换后端时需同步更新 `compactor.shared_store: s3` 和 `compactor.working_directory`（当前 compactor 已启用，filesystem 配置需改为 s3）
- **数据连续性**：历史日志无法自动迁移，S3 backend 从迁移日期起重新开始存储，接受历史数据留在旧 NFS PVC 直至 TTL 过期

### Phase 2：Tempo 迁移到 S3

更新 `k8s/helm/values/tempo.yaml`：
- `tempo.storage.trace.backend: s3`
- 配置 endpoint、bucket（`tempo-traces`）、credentials
- 同 Loki，历史 trace 不迁移

### Phase 3：Kopia S3 Repository（可选，解决无离站副本问题）

- **不替换**现有 NFS repo，而是在 Kopia 中新增一个 S3 repository
- `kopia repository connect s3 --endpoint=s3.meirong.dev --bucket=kopia-backup ...`
- 逐步将备份 policy 切换到 S3 repo
- 长期目标：配置 Kopia 同时写入 NFS（本地快速访问）+ S3（可通过 Cloudflare 访问，作为离站副本）

---

## Trade-off 记录

### S3 on NFS vs 直接 NFS

| 维度 | 直接 NFS | Garage S3 on NFS |
|------|----------|-----------------|
| 性能 | 较高（原生文件 IO） | 略低（多一层 HTTP API） |
| 可移植性 | 低（绑定 NFS 路径） | 高（换后端不改应用） |
| 访问方式 | PVC 挂载，应用需 NFS 感知 | 标准 S3 API，应用无需关心后端 |
| 管理复杂度 | 简单 | 略高（需维护 Garage） |
| 扩展性 | 受 NFS 限制 | 未来可将 data_dir 改为本地盘而不改上层服务 |

**决策**：接受略低性能，换取 S3 接口标准化。

### 单 Key vs 多 Key

| 维度 | 单 Key | 多 Key（选择方案） |
|------|--------|-------------------|
| 管理复杂度 | 低 | 略高（Vault 多条记录） |
| 爆炸半径 | 高（一 Key 泄漏影响所有服务） | 低（每 Key 只能访问自己的 Bucket） |

**决策**：每服务独立 Key，最小权限原则。

### Helm Chart vs 原生 YAML

| 维度 | Helm Chart | 原生 YAML（选择方案） |
|------|------------|----------------------|
| 升级便利性 | 高 | 需手动更新 image tag |
| 与现有约定一致性 | 低 | 高（基础服务用 YAML） |

**决策**：原生 YAML，与基础服务保持一致。

---

## 文件变更清单

```
新增:
  k8s/helm/manifests/garage.yaml                  # Namespace, ConfigMap, StatefulSet, Services, HTTPRoute, ReferenceGrant
  k8s/helm/manifests/garage-external-secret.yaml  # garage namespace: rpc-secret ExternalSecret
  k8s/helm/manifests/garage-loki-secret.yaml      # monitoring namespace: loki credentials ExternalSecret
  k8s/helm/manifests/garage-tempo-secret.yaml     # monitoring namespace: tempo credentials ExternalSecret
  k8s/helm/manifests/garage-kopia-secret.yaml     # kopia namespace: kopia credentials ExternalSecret
  argocd/applications/garage.yaml                  # ArgoCD Application

修改:
  argocd/applications/vault-eso.yaml               # 新增 4 个 garage *-secret.yaml 到 include 列表
  cloudflare/terraform/terraform.tfvars            # 新增 s3.meirong.dev
  cloud/oracle/manifests/uptime-kuma/provisioner.yaml         # 新增 Garage S3 monitor（MONITORS 列表）
  k8s/helm/justfile                                # 新增 bootstrap-garage target

后续（迁移阶段，Phase 1-3）:
  k8s/helm/values/loki.yaml                        # 切换到 S3 backend（含 compactor 配置）
  k8s/helm/values/tempo.yaml                       # 切换到 S3 backend
```
