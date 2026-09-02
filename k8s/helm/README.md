# k8s/helm/ — homelab 应用部署

> 本目录管 **homelab 集群**的应用层：Helm values、原生清单、以及部署配方。
> 集群装机在 [`../ansible/`](../ansible/README.md)，CNI values 在 [`../cilium/`](../cilium/)，
> oracle-k3s 的对应物在 [`cloud/oracle/`](../../cloud/oracle/README.md)。
>
> 架构事实不在这里：服务清单看 [reference/services.md](../../docs/reference/services.md)，
> GitOps 形态看 [reference/argocd-app-patterns.md](../../docs/reference/argocd-app-patterns.md)，
> 存储与备份看 [reference/storage.md](../../docs/reference/storage.md)。

## 目录

```
k8s/helm/
├── values/     # Helm values，一个应用一份 <app>.yaml（oracle 变体 <app>-oracle.yaml）
├── manifests/  # 原生清单，**一个子目录 ↔ 一个 ArgoCD Application**（所有权地图见 manifests/README.md）
└── justfile    # 部署配方；共享版本变量从仓库根的 versions.just import
```

## 部署方式

**日常一律 GitOps**：改 `values/` 或 `manifests/` → `git push` → ArgoCD 3 分钟内同步。
已纳管资源**不要** `kubectl apply` 覆盖，selfHeal 会拉回。

⚠️ **manual-helm 的例外**（改 values 必须手动 `helm upgrade`，**提交 ≠ 部署**）：
Cilium（`just deploy-cilium`）· Vault（`just deploy-vault`）· ESO（`just deploy-eso`）·
ArgoCD 本体（`just deploy-argocd`，装到 oracle-k3s）。
判断某个东西归谁管：`kubectl -n <ns> get secret -l owner=helm`，有 Helm release 存档的就是 manual-helm。

## 常用命令

完整清单 `just --list`（或在仓库根 `just helm --list`）。带坑的那几条：

| 命令 | 坑 |
|------|-----|
| `just deploy-argocd-apps` | ☠️ destination 未重写时会把 homelab 全套装到 oracle（2026-09-02 起 AppProject 也会拦，见 [ADR](../../docs/decisions/argocd-project-per-cluster.md)）|
| `just deploy-gateway-api-crds` | ⚠️ 升 Cilium 必跑；验收判据是**新建路由能拿到 `.status`**，不是 curl 旧域名 |
| `just deploy-cilium` | ⚠️ `--reset-values` 会冲掉 ClusterMesh 的跨集群 CA 信任，跑完要重连 |
| `just vault-unseal` | Vault pod 重启后必跑，否则 ESO 全线停摆 |
| `just homelab-recover` | 节点重建后的恢复编排 |

## Vault / ESO

Vault（KV v2）存凭据，ESO 同步成 K8s Secret。给应用加密钥 = 在应用自己的 manifest 目录
（或共享的 `manifests/vault-eso/`）写一个 `ExternalSecret`，`secretStoreRef` 指
`vault-backend` ClusterSecretStore。写法照抄目录里现有的任意一份。

- 根 token 与 unseal key 在 `k8s/helm/vault-keys.json`（**gitignored，绝不提交**）。
- Vault pod 重启后是 **sealed** 状态，ESO 会同步失败 → `just vault-unseal`。
- 备份与恢复见 [runbooks/backup-recovery.md](../../docs/runbooks/backup-recovery.md)。
- 密钥路径约定与现役清单见 [reference/security.md](../../docs/reference/security.md)。

## 存储

可写 PVC 一律 `local-path`（k3s 内置，节点本地盘）。NFS 于 2026-07-11 退出读写路径；
唯一的例外是 `media` ns 的 5 个**只读** NFS PV（106 的 ZFS，2026-08-16 起）。
⚠️ 新增 PVC 必须进备份白名单，CI 的 H4 查这个。详见
[reference/storage.md](../../docs/reference/storage.md) 与
[decisions/multimedia-repository-nfs-readonly.md](../../docs/decisions/multimedia-repository-nfs-readonly.md)。
