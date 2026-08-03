# 清单安全规则 (Manifest Safety Checks)

> Last updated: 2026-08-03
> Status: 生效事实
> Scope: `scripts/check-manifests.py` 强制的 H1-H4 —— source of truth。
> 每条规则都对应一次**真实发生过的事故或静默失效**，不是风格偏好。
> 检查器由 [static-checks.yml](../../.github/workflows/static-checks.yml) 在 PR 与 main 上运行。

## 为什么有这份文档

repo 里已经有大量「⚠️ 别踩这个坑」的注释和复盘。问题是**注释不拦人**：
2026-08-03 那次级联删除，`calibre-web.yaml` 顶部并没有写「这里内嵌了 Namespace」，
而即便写了，删文件的人也未必会去读被删文件的注释。

所以这里的规则都满足两个条件：

1. **已经发生过**（或已经在静默发生），不是假想风险
2. **能被静态检查抓住** —— 写进 CI，而不是写进注释指望下次有人记得

> ⚠️ 与 [docs/README.md](../README.md) 的 R1-R7 关系：那套管**文档组织**（由
> `scripts/check-docs.py` 强制），这套管**清单结构**。两者同一哲学：
> 规则没有强制手段就会腐化。

**设计原则：本文档写的规则，和 `scripts/check-manifests.py` 能查的必须一一对应。**
文档比检查器严，规则就是摆设；检查器比文档严，就会误伤。改任何一边都要同步另一边。

## 规则

### H1 —— `Namespace` / `CustomResourceDefinition` 必须独占文件

ArgoCD 按目录整体同步，**删掉一个文件 = prune 掉文件里的全部对象**。当文件里内嵌了
作用域大于本应用的资源，删除的爆炸半径就远超预期：

| 内嵌的资源 | 删文件时连带删掉 |
|---|---|
| `Namespace` | 该 ns 下**其它应用**的全部对象，含它们的 PVC |
| `CustomResourceDefinition` | 集群内该类型的**全部** CR |

☠️ **PVC 上的 `Prune=false` 拦不住这个** —— 被 prune 的是 Namespace，不是 PVC。
2026-08-03 就是这样：`git rm` 掉 `calibre-web.yaml`（Namespace 内嵌在它顶部）→
prune 掉整个 `personal-services` ns → 级联删光同 ns 的 open-notebook 数据。
完整复盘见 [../records/2026-08-03-namespace-prune-cascade.md](../records/2026-08-03-namespace-prune-cascade.md)。

**做法**：Namespace 单独放 `namespace.yaml`（或 `namespace-<name>.yaml`）。
仓库已按此整改（commit `983ce90`，当时全仓有 4 处内嵌）。

**刻意不管 `ClusterRole` / `ClusterRoleBinding`**：它们通常就是本应用自己的 RBAC，
与应用同生共死是正确的。把它们列进来会在 5 个文件上制造误报，而**误报会让整个检查被无视**，
那比没有检查更糟。

### H2 —— Application 的 `source.path` 与 `destination` 必须指向同一个集群

2026-08-02 起 ArgoCD 控制面在 oracle-k3s，于是 `destination.server` 的
`https://kubernetes.default.svc` **指的是 oracle**。homelab 的负载必须显式写
`https://100.94.186.7:6443`。

| `source.path` 前缀 | 必须的 `destination.server` |
|---|---|
| `k8s/helm/manifests/…` | `https://100.94.186.7:6443`（homelab） |
| `backup/overlays/homelab` | `https://100.94.186.7:6443`（homelab） |
| `cloud/oracle/manifests/…` | `https://kubernetes.default.svc`（oracle） |
| `backup/overlays/oracle` | `https://kubernetes.default.svc`（oracle） |
| `argocd/applications` | `https://kubernetes.default.svc`（oracle） |

☠️ 写错的后果不是「一个应用装错地方」，而是**把 homelab 全套负载装到 oracle**
（`AGENTS.md` 里那条 ☠️ 说的就是这个）。迁移期的正确顺序见
[../runbooks/argocd-control-plane-on-oracle.md](../runbooks/argocd-control-plane-on-oracle.md)。

**chart 型 source（`sources[]` 里只有 chart + `$values` 引用）跳过检查** ——
它们没有 `path`，而 values 文件一律放在 `k8s/helm/values/` 下、与目标集群无关
（`k8s/helm/values/loki.yaml` 对应的是 oracle 上的 Loki），静态上无从判断，
强行猜只会误报。这类 App 改 destination 时**没有网可兜**，要格外小心。

### H3 —— `ReferenceGrant` 必须声明 `v1beta1`

Gateway API 的 ReferenceGrant 至今**未晋升到 `v1`**。声明 `v1` 不会只让这一个对象失败，
而是整个 App 报 `ComparisonError: unable to resolve parseableType` —— App 级不可用。

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1   # ← 不是 v1
kind: ReferenceGrant
```

> 相关但**不由 CI 检查**的一条：本仓库的 ReferenceGrant 的 `to[]` 都不限定 `name`，
> 即「授权网关访问该 ns 下全部 Service」。这是刻意的简化，不是缺陷 —— 见下方
> 「查不出来的那些」里的 ReferenceGrant 寄生条目。

### H4 —— 清单里声明的每个 PVC 都必须有备份归属

两个 overlay 的备份脚本都是**显式白名单**（`for pat in …`），新增有状态应用
不往里加就**静默地不备份** —— 没有告警，没有报错，只有需要恢复时才会发现。

检查逻辑：清单树里每个 `PersistentVolumeClaim`，必须满足其一

1. 名字被对应 overlay 的白名单模式**子串命中**（脚本用 `/localpath/*"$pat"*` 匹配目录名）
2. 或在 `check-manifests.py` 的 `BACKUP_EXEMPT` 里写明**它靠什么保住**

| 清单树 | 备份脚本 |
|---|---|
| `k8s/helm/manifests/…` | `backup/overlays/homelab/backup-script.yaml` |
| `cloud/oracle/manifests/…` | `backup/overlays/oracle/backup-script.yaml` |

当前豁免（每条都必须说清替代保护手段，这是数据合法地不进 restic 的唯一出口）：

| PVC | 靠什么保住 |
|---|---|
| `miniflux-db-pvc` | PostgreSQL 数据目录，由 `pg_dumpall` 逻辑导出覆盖 |
| `open-notebook-surreal-local` | SurrealDB，由 HTTP `/export` 逻辑导出覆盖 |
| `calibre-books-local` | 23G 书库，由 `BOOKS_DIR` 整目录纳入 restic，不走 sqlite 白名单 |
| `meilisearch-data` | 搜索索引，可由 karakeep 全量重建，**刻意不备份** |

**这条规则上线即抓到一个真实缺口**：`trends-data`（45MB SQLite，且 PVC 带
`Prune=false`，本就是当作要紧数据对待的）自 2026-06-05 起静默未备份约两个月，
2026-08-03 补入白名单。

白名单直接从脚本正则解析，**不维护副本** —— 副本会漂移，而漂移的检查器比没有更糟。
解析不到就报错，宁可吵也不静默放行。

## 查不出来的那些（仍需人判断）

写下来是为了不让「CI 绿了」被误当成「安全了」。

| 失效模式 | 为什么静态查不了 | 真实案例 |
|---|---|---|
| 配置值写错嵌套层级 | 语法完全合法，多余的键静默忽略 | Tempo 的 `persistence` 是 chart 顶层键，写在 `tempo.` 之下 → 一直跑在 emptyDir，每次重启丢光 trace，而 values 里宣称保留 7 天 |
| 改了配置但 Pod 不重启 | 清单本身没错，错在下发机制 | oracle otel-collector 是裸 manifest，ConfigMap 更新不改 DaemonSet spec → Pod 不重启，而 Collector 只在启动时读一次配置。**此前对该配置的任何修改都是静默无效的**。已改用 kustomize `configMapGenerator` |
| ReferenceGrant 寄生在别人的文件里 | 语法与作用都正确，问题是**位置** | `allow-gateway-to-calibre` 没限定 Service 名（作用于整个 ns），却住在 `route-calibre-web.yaml` 里 → 删 calibre 路由会连带断掉 `notebook.meirong.dev`。现改为每个 route 文件各带一条自己的 grant（Gateway API 是累加式授权），删任一文件都不影响另一个 |
| 文档与集群漂移 | 文档格式可以完美而内容全错 | 2026-07-31 那次 NFS 描述格式合规、内容过期，是 `kubectl` 照出来的 |

**删任何清单文件前**，先 `grep '^kind:' <file>`，确认没有作用域大于该文件的资源
（H1 覆盖了 Namespace/CRD，但 ReferenceGrant 这类「语法对、位置错」的仍要靠眼睛）。

## 运行

```bash
# 仓库根目录
uv run --with pyyaml python scripts/check-manifests.py          # 检查
uv run --with pyyaml python scripts/check-manifests.py --list   # 只看规则与出处
```

CI 里由 `.github/workflows/static-checks.yml` 在改动 `*.yaml` 时自动运行。
