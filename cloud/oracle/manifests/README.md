# `cloud/oracle/manifests/` 所有权地图

> Last updated: 2026-09-08
> Status: 生效事实
> 本文只回答一件事：**这棵目录树里，哪个子目录由哪个 ArgoCD App 同步**。
> 拆分的手法、实测数字与回滚见
> [../../../docs/runbooks/oracle-manifests-split-to-apps.md](../../../docs/runbooks/oracle-manifests-split-to-apps.md)。

2026-09-08 之前这里是一棵 141 个对象的单体 kustomize 树，由**一个** `oracle-k3s` App
同步（任一文件坏掉整个集群停同步）。现在按目录拆开：

| 目录 | 归哪个 App | 源类型 | 备注 |
|---|---|---|---|
| `base/` | `oracle-k3s` | kustomize（根树） | 集群级地基：Gateway、cloudflared、ClusterSecretStore、CoreDNS 扩展、PriorityClass。**内嵌两个 Namespace** |
| `databases/` | `oracle-k3s` | 同上 | CNPG `apps-pg` |
| `homepage/` | `oracle-k3s` | 同上 | |
| `falco/` | `oracle-k3s` | 同上 | 只有 ns + falcosidekick 凭据；Falco 本体是独立 Helm App |
| `opencost/` | `oracle-k3s` | 同上 | 只有 ns |
| `argocd/` | `oracle-k3s` | 同上 | ns + 两个 ESO 凭据 + argocd 路由。**ArgoCD 本体是 manual-helm，刻意不自管** |
| `rss-system/` | **`oracle-rss`** | 目录源 | ⚠️ 它的 HTTPRoute/ReferenceGrant 在 `base/gateway.yaml`，不在本目录 |
| `uptime-kuma/` | **`oracle-uptime-kuma`** | 目录源 | ⚠️ 目标 ns 是 `personal-services`，与目录不同名 |
| `personal-services/` | **`oracle-personal-services`** | 目录源 | 最大一组；含 5 个 PVC（均 `Prune=false`） |
| `monitoring/` | **`oracle-monitoring`** | **kustomize**（本目录有 `kustomization.yaml`） | ☠️ 不能改成目录源，见下 |
| `zitadel/` | **`oracle-zitadel`** | 目录源 | 全舰队 SSO |
| `calibre-metadata/` | `calibre-metadata` | 目录源 | 早就是独立 App（一次性 Job 需要专门的 `ignoreDifferences`） |

## ☠️ 三条改这棵树前必须知道的

**1. 全部 `namespace.yaml` 留在 `oracle-k3s`，五个新 App 用
`directory.exclude: namespace.yaml` 排除它们。** Namespace 被 prune 会**级联删光该 ns
下的一切**，`Prune=false` 拦不住（被 prune 的是 ns 本身）——
2026-08-03 真这样删过一次。别"顺手"把 ns 挪进对应的 App 里显得整齐。

⚠️ 尤其是 `uptime-kuma/namespace.yaml`：它声明的是 **`personal-services`**，
而且是那个 ns 的**唯一来源**（`personal-services/` 目录里没有 namespace.yaml）——
calibre-web / readlist / excalidraw 和 5 个 PVC 全在那个 ns 里。

**2. `monitoring/` 必须保留 `kustomization.yaml`，不能退化成目录源。**
otel-collector 的配置走 `configMapGenerator`（生成名带内容哈希 → 配置一变 DaemonSet
自动滚动）。改成目录源就退回「ConfigMap 变了 pod 根本不重启」那个坑（2026-08-02 实测：
ConfigMap 已更新、DaemonSet spec 未变、pod age 2d5h / 0 restart，配置静默不生效）。
⚠️ 而且 `otel-collector-config.yaml` 是**裸 OTel 配置、没有 apiVersion/kind**，
目录源会把它当清单去 apply 并失败。

**3. 从这棵树再往外拆 App 时，先把 `oracle-k3s` 的 `prune` 临时改成 `false`。**
ArgoCD **不会**把已被 `oracle-k3s` 拥有的对象让给新 App（新 App 只报
`SharedResourceWarning` 并永久 OutOfSync）。交接只发生在旧 App 不再渲染那些对象的
一刻，而那一刻若 prune 开着，对象会先被删再重建。关掉 prune 则原地交接：
2026-09-08 拆五组实测 **74 个 pod 零重启**。拆完立刻改回 `true`。

## 加一个新服务

放进对应子目录即可 —— 那五个目录源 App 是「目录即清单」，**不需要**再登记到
任何 `resources:` 列表。只有 `base/`、`databases/`、`homepage/`、`falco/`、`argocd/`
这几个还归根 `kustomization.yaml` 的目录需要显式登记（漏登记会静默不生效）。
`monitoring/` 需要登记进 `monitoring/kustomization.yaml`。

完整新增服务流程走 [runbooks/add-service.md](../../../docs/runbooks/add-service.md)。
