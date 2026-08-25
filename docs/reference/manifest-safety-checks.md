# 清单安全规则 (Manifest Safety Checks)

> Last updated: 2026-08-25
> Status: 生效事实
> Scope: CI 强制的仓库规则 —— source of truth。三个检查器：
> `scripts/check-manifests.py` 的 **H1-H5**（清单结构）、
> `scripts/check-version-pairs.py` 的 **V1-V3**（版本配对，2026-08-13 加）与
> `scripts/check-embedded-scripts.py` 的 **E1**（内嵌脚本一致性，2026-08-15 加）。
> 每条规则都对应一次**真实发生过的事故或静默失效**，不是风格偏好。
> 三者都由 [static-checks.yml](../../.github/workflows/static-checks.yml) 在 PR 与 main 上运行。

## 为什么有这份文档

repo 里已经有大量「⚠️ 别踩这个坑」的注释和复盘。问题是**注释不拦人**：
2026-08-03 那次级联删除，`calibre-web.yaml` 顶部并没有写「这里内嵌了 Namespace」，
而即便写了，删文件的人也未必会去读被删文件的注释。

所以这里的规则都满足两个条件：

1. **已经发生过**（或已经在静默发生），不是假想风险
2. **能被静态检查抓住** —— 写进 CI，而不是写进注释指望下次有人记得

> ⚠️ 与 [docs/RULES.md](../RULES.md) 的 R1-R7 关系：那套管**文档组织**（由
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

声明集群里**没有提供**的版本，不会只让这一个对象失败，而是整个 App 报
`ComparisonError: unable to resolve parseableType` —— App 级不可用。

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1   # ← 不是 v1
kind: ReferenceGrant
```

> **2026-08-11 更正理由（规则不变，原因变了）**：本节原写「ReferenceGrant 至今未晋升到
> `v1`」，这已经不成立 —— Gateway API 早已把它提升到 `v1`，而且 **Cilium 1.20 反过来
> *要求* 该 CRD 提供 `v1`**，否则 operator 的 Gateway API 控制器整个不初始化
> （两集群因此静默瘫痪 30 小时，见 [records/2026-08-11-gateway-api-crd-stall.md](../records/2026-08-11-gateway-api-crd-stall.md)）。
>
> 集群现装 Gateway API **v1.6.1**，其 referencegrants CRD **同时 served `v1` 与 `v1beta1`，
> 且 `v1beta1` 仍是 storage 版本**。所以：
> - 继续写 `v1beta1` 是对的（仍受支持、是 storage，改成 v1 是无谓的 churn）；
> - 但**别再把理由说成「v1 不存在」** —— 它存在。真正的判据永远是
>   「**集群里这个 CRD 提供哪些版本**」：
>   `kubectl get crd referencegrants.gateway.networking.k8s.io -o jsonpath='{.spec.versions[*].name}'`

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
| `open-notebook-surreal-local` | SurrealDB，由 HTTP `/export` 逻辑导出覆盖 |
| `calibre-books-local` | 23G 书库，由 `BOOKS_DIR` 整目录纳入 restic，不走 sqlite 白名单 |

**这条规则上线即抓到一个真实缺口**：`trends-data`（45MB SQLite，且 PVC 带
`Prune=false`，本就是当作要紧数据对待的）自 2026-06-05 起静默未备份约两个月，
2026-08-03 补入白名单。

白名单直接从脚本正则解析，**不维护副本** —— 副本会漂移，而漂移的检查器比没有更糟。
解析不到就报错，宁可吵也不静默放行。

### H5 —— 每个 `Namespace` 必须显式声明 PSA 等级

**没有 PSA 标签不是「没定级」，是定成了最宽的那档**：PSA 内置默认 `enforce=privileged`，
而且 `warn`/`audit` 一并为空 —— 既不拦，也不记，连事后审计的线索都没有。
这比一个写着 `privileged` 的显式豁免更危险：后者至少有人能在 review 里看见。

```yaml
metadata:
  name: <ns>
  labels:
    pod-security.kubernetes.io/enforce: baseline   # ← 三档任选，privileged 也行（显式豁免）
```

**这条规则来自一次真实的静默失效**：`zitadel` ns（oracle，装着 SSO 与身份库 `zitadel-pg`）
自 2026-07-06 迁入起清单里**一个 PSA 标签都没有**，敞了一个多月到 2026-08-10。
期间实测 `kubectl apply --dry-run=server` 一个 `hostPID + hostNetwork + privileged + hostPath:/`
的 Pod，**在该 ns 建得成，且不产生任何 warning**；同一个 Pod 打到 `databases` ns 直接 Forbidden。
`security.md` 的等级矩阵旁边一直挂着「⚠️ zitadel 没标签」的注释 —— 又一次印证注释不拦人。

三个等级都算通过（`privileged` 是显式豁免，写出来就有人能审），写错值（拼错、写成 `restrict`）
同样报错 —— PSA 对无法识别的等级值不会报错，它只是**不生效**。

> 收紧前先问准入自己，别靠读 values 猜：
> ```bash
> kubectl label ns <ns> pod-security.kubernetes.io/enforce=restricted --overwrite --dry-run=server
> ```
> 它会把现存违规 Pod 连同缺失字段一起列出来。⚠️ 只评估**当下存在的** Pod ——
> 周期性 Job（trivy 的 node-collector 要 hostPath）当时不在场，dry-run 干净 ≠ 收紧安全。

### V1 —— 同一 chart 出现在多个 Application 里必须同版本

**为什么**：三对 App 是**跨集群镜像部署**同一个 chart（`external-dns` / `opencost` /
`trivy-operator` 各两份）。升级时只改一侧，另一侧就静默留在旧版本，直到某天两集群行为
不一致才被发现。

自动发现、不需要维护名单：检查器扫 `argocd/applications/*.yaml`，把同名 `chart` 的
`targetRevision` 两两比对。**刻意的灰度**（单侧先行）写行内豁免：

```yaml
targetRevision: "2.5.27"   # version-pair-ok: 灰度先行 oracle，2026-09 对齐
```

### V2 —— 声明为「同一事实」的版本变量组必须取值一致

**为什么**：`gateway_api_version` 同一个事实写在**三处**（`k8s/helm/justfile`、
`cloud/oracle/justfile`、`cloud/oracle/ansible/playbooks/setup-k3s.yaml`）。
2026-08-13 实测：前两处已是 1.6.1，剧本里**还钉着 1.2.1**，注释却写"与 homelab 一致"
—— 而这处漏改只在**重建集群时**才爆，等于埋了一颗定时炸弹。

配对组是**人工声明**的（`DECLARED_PAIRS`），不做"同名变量一律必须相等"的推断。加组前
先问：改了一处不改另一处，会不会出事？会才加。当前两组：

| 组 | 为什么必须相等 |
|---|---|
| `gateway_api_version`（3 处）| 两集群装同一版本 CRD；oracle 的 justfile 与剧本描述的更是同一批 CRD |
| `cilium_version`（2 处）| ClusterMesh 要求两端版本一致；且各自的 Gateway API 版本由同一张兼容表推出 |

⚠️ **刻意不收** `node_exporter_version`（三套 ansible 各一份，实测 1.11.1 / 1.10.0 /
1.11.1）与 `eso_version`（两集群独立安装）：那是三个独立机队/两个独立安装，不一致是
"该升级了"而不是"配置错了"。把它算违规就会制造一条谁都不看的红灯——
这类漂移交给 Renovate 开 PR（[决策](../decisions/renovate-adoption.md)）。

### V3 —— `cilium_version` 与 `gateway_api_version` 必须符合兼容表

**为什么**：**2026-08-11 的 30 小时静默 stall**。缺 CRD 时 Cilium operator 的 Gateway API
控制器**整个不初始化**，而旧路由照常 200、无任何告警，只有新增路由静默 503
（[复盘](../records/2026-08-11-gateway-api-crd-stall.md)）。

检查器里有一张 `CILIUM_GATEWAY_API` 表（当前只有 `1.20 → 1.6.1`）。
☠️ **升 Cilium 时表里查不到对应 minor 会直接报错，这是特意的**：它强迫升级者去读一遍
上游的 Gateway API 前置条件，而不是假设旧 CRD 还能用——后者正是 08-11 的死法。

### E1 —— ConfigMap 内嵌的脚本必须与同目录的源文件一致，且 pod 模板带它的 checksum

**适用对象**：跑「通用镜像 + ConfigMap 挂脚本」的负载。目前只有
`k8s/helm/manifests/monitoring/cf-analytics-exporter/`（`exporter.py` ↔ `-cm.yaml`）。

**为什么**：这种布局天生有两份副本 —— 一份 `.py` 供编辑器/linter 当代码看，一份嵌在 YAML
里供 ArgoCD 部署。两个失效模式**都是静默的**，且长得一模一样（git 干净、ArgoCD Synced、
pod Running、行为是旧的）：

1. 改了 `.py` 忘了重新生成 ConfigMap → 部署的还是旧代码。
2. 重新生成了 ConfigMap，但 **ConfigMap 变更不会重启 pod** → 进程还跑着启动时读进内存的
   旧脚本。这条不是假想：`查不出来的那些` 表里 oracle otel-collector 那行就是同一种死法。

所以 E1 查两件事：`data[<key>]` 逐字节等于源文件，**且** pod 模板注解
`checksum/<...>` 等于源文件 sha256 的前 16 位。第二条让脚本一变 pod 模板就变，
ArgoCD 自然滚动重启。

**怎么修**：`cd k8s/helm && just gen-embedded-scripts`（= `check-embedded-scripts.py --write`），
它同时重写 ConfigMap 与 checksum 注解。**不要手改 ConfigMap 里的 Python**。

**加新目标**：在 `check-embedded-scripts.py` 的 `TARGETS` 里加一项。要求 ConfigMap 的
`data` 只有那一个 key 且位于文件末尾 —— 生成器按「`key: |` 之后到文件尾」整段替换，
以保住文件头的注释。

#### E1 的半个变体：`STAMP_ONLY`（只查 checksum，2026-08-25 加）

有些内嵌内容**压根没有、也不该有外部源文件**：LiteLLM 的路由表只存在于 ConfigMap 里，
抽成外部 `.yaml` 会落在 ArgoCD 同步目录里被当清单 apply 然后失败。这类目标进
`STAMP_ONLY`，不查 (a)「两份副本一致」，只查 (b)「hash 进 pod 模板」——
因为让它出事的是同一个机制：**subPath 挂载不接收 ConfigMap 更新，且进程只在启动时读配置**。

`STAMP_ONLY` **只读不写**，所以直接用 YAML 解析器取 `data[key]`——取到的就是
Kubernetes 实际看到的值。不像 `TARGETS` 那样按缩进硬读（那条路要求块位于文件末尾，
且对 `docker.yaml: ""` 这种空标量直接找不到，2026-08-25 踩到）。因此 ConfigMap
和消费它的 Deployment 可以留在同一个文件里，加保护不需要拆清单。

⚠️ 也因此 `check-embedded-scripts.py` **依赖 pyyaml**——
[static-checks.yml](../../.github/workflows/static-checks.yml) 里它必须用
`uv run --with pyyaml python` 跑（原来是裸 `uv run python`）。

`key` 可以写成列表：一个 ConfigMap 的多个 key 合成**一个**注解。哈希只覆盖值
（按列表顺序、`\0` 分隔），不含 key 名——重命名 key 必然同时改 pod 模板里的 `subPath`，
模板本身就变了，不需要哈希再兜一遍。

当前目标：

| 清单 | key | 注解 | 踩过的坑 |
|---|---|---|---|
| `litellm.yaml` | `config.yaml` | `checksum/config` | 2026-08-25：改完 `mac/ornith` 后 ConfigMap 同步成功、ArgoCD Synced/Healthy、pod Running、探针全绿，而网关按**旧路由表**继续跑，必须手动 `rollout restart` |
| `homepage/homepage.yaml` | 6 个（settings/bookmarks/services/widgets/kubernetes/docker）| `checksum/config` | 同款机制：改配置后仪表盘静默不变 |

**验哈希对不对**，别只看 CI 绿：拿集群里 ConfigMap 的真实 data 反算一遍，应与注解相等 ——
```bash
kubectl --context oracle-k3s -n homepage get cm homepage-config -o json \
  | python3 -c 'import sys,json,hashlib; d=json.load(sys.stdin)["data"]; \
    print(hashlib.sha256(b"\0".join(d[k].encode() for k in ["settings.yaml","bookmarks.yaml","services.yaml","widgets.yaml","kubernetes.yaml","docker.yaml"])).hexdigest()[:16])'
```

**「ConfigMap 变了 pod 不重启」目前有两种合法的解**，加新负载时挑一个：

| 手段 | 适用 | 本仓库实例 |
|---|---|---|
| kustomize `configMapGenerator`（名字带内容哈希，自动重写引用） | 该目录已走 kustomize | oracle otel-collector（`cloud/oracle/manifests/kustomization.yaml`）|
| pod 模板 `checksum/*` 注解 + `STAMP_ONLY` | 裸 manifest，不走 kustomize | litellm |

⚠️ **仍未覆盖**（subPath 挂 ConfigMap、既无哈希名也无 checksum 注解）：
`k8s/helm/manifests/media/podcast.yaml`（nginx `default.conf`）。
改它会静默不生效，加进 `STAMP_ONLY` 只需一条目 + 一个注解。

## 查不出来的那些（仍需人判断）

写下来是为了不让「CI 绿了」被误当成「安全了」。

| 失效模式 | 为什么静态查不了 | 真实案例 |
|---|---|---|
| 配置值写错嵌套层级 | 语法完全合法，多余的键静默忽略 | Tempo 的 `persistence` 是 chart 顶层键，写在 `tempo.` 之下 → 一直跑在 emptyDir，每次重启丢光 trace，而 values 里宣称保留 7 天 |
| 改了配置但 Pod 不重启 | 清单本身没错，错在下发机制 | oracle otel-collector 是裸 manifest，ConfigMap 更新不改 DaemonSet spec → Pod 不重启，而 Collector 只在启动时读一次配置。**此前对该配置的任何修改都是静默无效的**。已改用 kustomize `configMapGenerator`。2026-08-25 litellm 又踩一次同款（改完路由表网关仍按旧表跑），已由 E1 的 `STAMP_ONLY` 覆盖。⚠️ **不再是通例但仍有缺口**：podcast 一处 subPath 挂载至今无保护（homepage 已于同日纳管），见 E1 章节末尾的表 |
| ReferenceGrant 寄生在别人的文件里 | 语法与作用都正确，问题是**位置** | `allow-gateway-to-calibre` 没限定 Service 名（作用于整个 ns），却住在 `route-calibre-web.yaml` 里 → 删 calibre 路由会连带断掉 `notebook.meirong.dev`。现改为每个 route 文件各带一条自己的 grant（Gateway API 是累加式授权），删任一文件都不影响另一个 |
| 文档与集群漂移 | 文档格式可以完美而内容全错 | 2026-07-31 那次 NFS 描述格式合规、内容过期，是 `kubectl` 照出来的 |
| **operator 动态创建的 PVC 逃出 H4** | H4 只扫**清单里声明**的 PVC；CNPG 的卷由 operator 按 `Cluster` 的 `instances` 生成，仓库里没有对应的 PVC 对象 | `apps-pg-1` / `zitadel-pg-1` 两个库的备份归属完全靠 `backup/overlays/oracle/backup-script.yaml` 里的逐库 `pg_dump` 行。**apps-pg 上加一个租户就必须手工加一行**，H4 不会提醒——性质等同于 sqlite 白名单，而那份白名单曾让 `trends-data` 静默漏备两个月。见 [decisions/shared-postgres-platform.md](../decisions/shared-postgres-platform.md) |
| **清单外创建的 ns 逃出 H5** | H5 只扫**清单里声明**的 Namespace；Helm chart 自带的 ns、ArgoCD 的 `CreateNamespace=true`、operator 自建的 ns 在仓库里根本没有对象 | oracle 的 `external-secrets` / `cnpg-system` / `trivy-system` / `default` / `cilium-secrets` 至今无 PSA 标签，CI 全绿也照样查不到。**只能靠 `kubectl get ns -L pod-security.kubernetes.io/enforce` 眼看**（`just psa-status` 打的就是这条，但它固定 `k3s-homelab` 上下文，oracle 要手工加 `--context`）。⚠️ **当前没有开放项跟踪这几个 ns 的补齐**（此处原写"见 ROADMAP 开放项 #13"，而 ROADMAP 从来没有 #13——2026-08-13 更正）；PSA 逐层状态见 [security.md](security.md) |
| CRD 字段放错层级 | `kubectl apply --validate=strict` 对 CRD **照样放行**，多余的键要到 ArgoCD 用 ServerSideApply 建 typed patch 时才炸 | 2026-08-06 把 `postImportApplicationSQL` 写在 `bootstrap.initdb` 下（正确位置是 `initdb.import`）→ 客户端校验通过，同步时报 `field not declared in schema` 并进入重试（重试会钉住 revision，修复 commit 得先 terminate operation）。预检要用 `kubectl apply --server-side --dry-run=server`，字段位置以 `kubectl explain` 为准 |

**删任何清单文件前**，先 `grep '^kind:' <file>`，确认没有作用域大于该文件的资源
（H1 覆盖了 Namespace/CRD，但 ReferenceGrant 这类「语法对、位置错」的仍要靠眼睛）。

## 运行

```bash
# 仓库根目录
uv run --with pyyaml python scripts/check-manifests.py             # H1-H5
uv run --with pyyaml python scripts/check-manifests.py --list      # 只看规则与出处
uv run --with pyyaml python scripts/check-version-pairs.py         # V1-V3
uv run --with pyyaml python scripts/check-version-pairs.py --list
python3 scripts/check-embedded-scripts.py                          # E1（无第三方依赖）
python3 scripts/check-embedded-scripts.py --write                  # E1 修复 = just gen-embedded-scripts
```

CI 里由 `.github/workflows/static-checks.yml` 在改动 `*.yaml` / `justfile` /
`k8s/helm/manifests/**/*.py` / 检查器自身时自动运行。

⚠️ **改规则必须同步改这份文档**（两边不一致的话，要么规则是摆设，要么检查器在误伤）。
V1-V3 的敏感度在上线当天逐条实测过：故意把 oracle 剧本改回 1.2.1、把两集群 cilium 版本
拆开、把 Cilium 升到表外的 minor、把变量改名——六个场景全部按预期判红，行内豁免按预期转绿。
