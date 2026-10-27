# 清单安全规则 (Manifest Safety Checks)

> Last updated: 2026-10-28
> Status: 生效事实
> Scope: CI 强制的仓库规则，本文是 source of truth。四个检查器：
> `scripts/check-manifests.py` 的 **H1-H5**（清单结构）、
> `scripts/check-version-pairs.py` 的 **V1-V4**（版本配对）、
> `scripts/check-embedded-scripts.py` 的 **E1**（内嵌脚本一致性）与
> `scripts/render-manifests.py` 的**渲染检查**。
> 每条规则都对应一次真实发生过的事故或静默失效，不是风格偏好。
> 全部由 [static-checks.yml](../../.github/workflows/static-checks.yml) 在 PR 与 main 上运行。

注释不拦人，所以这里只收「已经发生过（或正在静默发生）」且「能被静态检查抓住」的规则。
⚠️ 本文与检查器必须一一对应：文档比检查器严，规则是摆设；检查器比文档严，就会误伤。改一边就同步另一边。
文档组织规则另见 [RULES.md](../RULES.md) 的 R1-R8。

## 规则

### H1：`Namespace` / `CustomResourceDefinition` 必须独占文件

- 判据：GitOps 同步树（`k8s/helm/manifests`、`cloud/oracle/manifests`、`backup`、`argocd`）里，文件含
  `Namespace` 或 CRD 且还有别的 kind，即违规。
- 为什么：ArgoCD 按目录同步，删文件 = prune 文件里的全部对象。内嵌 Namespace 会连带删光该 ns 下其它应用（含 PVC），
  内嵌 CRD 会删光集群内该类型的全部 CR。2026-08-03 真删过一次：[records](../records/2026-08-03-namespace-prune-cascade.md)。
- ☠️ PVC 上的 `Prune=false` 拦不住：被 prune 的是 Namespace，不是 PVC。
- 修法：Namespace 单独放 `namespace.yaml`（或 `namespace-<name>.yaml`）。
- 刻意不管 `ClusterRole` / `ClusterRoleBinding`：通常是本应用自己的 RBAC，同生共死是对的；列进来只会误报。

### H2：Application 的 `source.path` / `$values` / `project` 与 `destination` 必须同集群；AppProject 只许一条 destination

控制面在 oracle-k3s，`https://kubernetes.default.svc` 指 oracle，homelab 负载必须显式写 `https://100.94.186.7:6443`。
☠️ 写错 = 把 homelab 全套负载装到 oracle。迁移期顺序见 [argocd-control-plane-on-oracle.md](../runbooks/argocd-control-plane-on-oracle.md)。

判据（表在 `check-manifests.py` 的 `PATH_CLUSTER` / `VALUES_CLUSTER` / `PROJECT_FOR_SERVER`）：

| | homelab | oracle |
|---|---|---|
| `destination.server` | `https://100.94.186.7:6443` | `https://kubernetes.default.svc` |
| ① `source.path` 前缀 | `k8s/helm/manifests/…` · `backup/overlays/homelab` | `cloud/oracle/manifests/…` · `backup/overlays/oracle` · `argocd/…` |
| ② `$values/…` 的 valueFiles 前缀 | `k8s/helm/values/…` | `cloud/oracle/values/…` |
| ③ `project` | `homelab` | `oracle-k3s` |

- ① chart 型 source 没有 `path`，由 ② ③ 兜住。
- ② values 一棵集群一棵树（放错树时 `Synced` 照绿）；不在已知树里也报错，新树先登记 `VALUES_CLUSTER`。
  ⚠️ 两集群成对的 values（external-dns / opencost / trivy-operator）改一边忘另一边会静默分叉，本条不查。
- ③ 脱节时 ArgoCD 服务端也会拒绝同步（`destination server ... is not permitted`），本条在 push 前就拦。
  内置全放行的 `default` 只许 `argocd/` 下的 root / projects 两个元 App 用。[ADR](../decisions/argocd-project-per-cluster.md)
- ④ AppProject 必须且只能有一条 destination，且是 project 名对应的集群；多列或通配会让服务端兜底静默失守。
  新集群入编 = 新 project 文件 + 登记 `PROJECT_FOR_SERVER`（集群表的唯一副本）。
- 查不到：manual-helm 的 values 由 justfile `--values` 直接给，不经 Application（如 ArgoCD 本体的
  `k8s/helm/values/argocd.yaml` + `argocd-oracle.yaml`，装在 oracle，配方在 `k8s/helm/justfile`）。
  判断归谁管：`kubectl --context <ctx> -n <ns> get secret -l owner=helm`。

### H3：`ReferenceGrant` 必须声明 `v1beta1`

- 判据：每个 ReferenceGrant 的 `apiVersion` 必须是 `gateway.networking.k8s.io/v1beta1`。
- 为什么：声明集群没提供的版本，整个 App 报 `ComparisonError: unable to resolve parseableType`，不只是这一个对象。
- 为什么是 v1beta1：现装 Gateway API v1.6.1 的 CRD 同时 served `v1` 与 `v1beta1`，`v1beta1` 仍是 storage 版本，
  改 v1 是无谓 churn。⚠️ 别说成「v1 不存在」：它存在，且 Cilium 1.20 要求 CRD 提供 v1
  （[records](../records/2026-08-11-gateway-api-crd-stall.md)）。判据永远是集群实际提供的版本：
  `kubectl --context <ctx> get crd referencegrants.gateway.networking.k8s.io -o jsonpath='{.spec.versions[*].name}'`
- ☠️ 同 ns 后端不需要 grant：它只管跨 ns 的 `backendRefs`，Gateway 接管别的 ns 的路由靠 listener 的 `allowedRoutes`。
  2026-09-06 实测仓库现存 grant 全是同 ns 的，一个都没在起作用；H3 留给真写跨 ns grant 时用。见
  [networking-ingress.md](networking-ingress.md)。
- 本仓库 grant 的 `to[]` 不限定 `name`（授权整个 ns），是刻意简化；位置风险见「查不出来的那些」。

### H4：清单里声明的每个 PVC 都必须有备份归属

- 判据：清单树里每个 PVC，名字须被对应备份脚本白名单（`for pat in …;`）的某个模式子串命中（脚本用
  `/localpath/*"$pat"*` 匹配目录名），或在 `check-manifests.py` 的 `BACKUP_EXEMPT` 里写明靠什么保住。
  `k8s/helm/manifests/` 对 `backup/overlays/homelab/backup-script.yaml`，`cloud/oracle/manifests/` 对
  `backup/overlays/oracle/backup-script.yaml`。
- 为什么：备份是显式白名单，漏加就静默不备份，恢复时才发现。上线即抓到 `trends-data` 漏备约两个月。
- 白名单直接从脚本解析（锚定行首 `for pat in`，多个循环取并集），不维护副本；解析不到就报错。
- 修法：加进白名单，或加 `BACKUP_EXEMPT` 条目。豁免是数据合法不进 restic 的唯一出口，必须写清替代保护。
- ⚠️ worker 夜备（`worker-backup-script.yaml`）整目录扫、不看白名单，但 H4 只解析控制面那份：钉到
  `k8s-worker-106` 的 PVC 也要写进控制面白名单。

当前豁免（真相源 `BACKUP_EXEMPT`）：

| PVC | 靠什么保住 |
|---|---|
| `open-notebook-surreal-local` | SurrealDB HTTP `/export` 逻辑导出 |
| `calibre-books-local` | `BOOKS_DIR` 整目录纳入 restic |
| `apps-pg-data-local` | homelab 共享 Postgres 逐库 `pg_dump`（数据目录无 WAL 自恢复，不能原样拷贝） |
| `media-{movie,tv,anime,music,podcast}` | 只读 NFS，真身在 106 的 ZFS（raidz1+sanoid），再进 restic 无跨机冗余意义（[ADR](../decisions/multimedia-repository-nfs-readonly.md)） |

- ☠️ 逻辑 dump 类豁免只保「卷不用进 restic」，保不住「库有没有被 dump」：共享实例或 CNPG 加库/租户，H4 看不见，
  必须手工在备份脚本加一行 `pg_dump`。
- ⚠️ H4 也查不出「有归属但文件名模式对不上」，见 [storage.md](storage.md)。

### H5：每个 `Namespace` 必须显式声明 PSA 等级

- 判据：每个 Namespace 必须有 `pod-security.kubernetes.io/enforce` 标签，值为 `privileged` / `baseline` /
  `restricted` 之一。`privileged` 算通过（显式豁免，有人能审）；写错值同样报错，因为 PSA 对不认识的值不报错、只是不生效。
- 为什么：没标签 = 静默吃内置默认 `enforce=privileged`，且 `warn`/`audit` 全空，连审计线索都没有，比显式写
  `privileged` 更危险。`zitadel` ns 曾这样敞了一个多月，见 [records](../records/2026-08-10-zitadel-ns-without-psa-labels.md)。
- 收紧前先问准入（会列出现存违规 Pod）：
  `kubectl --context <ctx> label ns <ns> pod-security.kubernetes.io/enforce=restricted --overwrite --dry-run=server`
  ⚠️ 只评估当下存在的 Pod：周期性 Job（trivy 的 node-collector 要 hostPath）不在场，dry-run 干净 ≠ 收紧安全。

### V1：同一 chart 出现在多个 Application 里必须同版本

- 判据：扫 `argocd/applications/*.yaml`，同名 `chart` 的 `targetRevision` 必须一致，自动发现，不维护名单。
- 为什么：跨集群镜像部署的 chart 对（external-dns / opencost / trivy-operator）只升一侧，另一侧静默留在旧版。
- 豁免：刻意灰度在版本行写 `# version-pair-ok: <理由>`，任一处带豁免则整组跳过。

### V2：声明为「同一事实」的版本变量组必须取值一致

- 判据：`check-version-pairs.py` 的 `DECLARED_PAIRS` 里每组变量在所列文件中取值必须一致；找不到变量也报错。
  组与各组理由见 `DECLARED_PAIRS` 的 `why`。
- 为什么：同一版本事实散在多处，漏改的那处只在重建集群时才爆（oracle 剧本曾钉旧 `gateway_api_version` 而注释写
  「与 homelab 一致」；server 剧本曾根本没钉 k3s 版本）。
- 组是人工声明的，不推断「同名变量一律相等」。加组前先问：改一处不改另一处会不会出事？会才加。
- ⚠️ 刻意不收 `node_exporter_version`（三个独立机队）与 `eso_version`（两集群独立安装）：不一致是「该升级了」，
  不是「配置错了」，算违规只会造一条没人看的红灯。
- ⚠️ `k3s_version` 描述现网在跑什么，不是想升到什么：升完节点再改 pin（[k3s-cluster-upgrade.md](../runbooks/k3s-cluster-upgrade.md)）；
  分阶段升级在先行那侧行尾写 `version-pair-ok: <理由>`。

### V3：`cilium_version` 与 `gateway_api_version` 必须符合兼容表

- 判据：`versions.just` 的 `cilium_version` 按 major.minor 查 `CILIUM_GATEWAY_API`，`gateway_api_version` 必须等于表值
  （当前只有 `1.20 → 1.6.1`）。
- 为什么：缺 CRD 时 Gateway API 控制器整个不初始化，旧路由照常 200，只有新增路由静默 503
  （[records](../records/2026-08-11-gateway-api-crd-stall.md)）。
- ☠️ 升 Cilium 时表里查不到对应 minor 直接报错，是特意的：逼升级者读上游前置条件，而不是假设旧 CRD 还能用。

### V4：`versions.just` 的共享变量不得被 import 方重新定义

- 判据：`k8s/helm/justfile` 与 `cloud/oracle/justfile` 必须 `import` [`versions.just`](../../versions.just)，
  且不得再定义它已有的变量名。
- 为什么：`cilium_version` / `gateway_api_version` 是两集群同一个事实（ClusterMesh 要求两端同版本；两集群装同一批 CRD）。
  ☠️ `just import` 允许 import 方重新定义同名变量并静默胜出，读的人还以为值来自共享文件。
- 豁免：分阶段升级在那行行尾写 `version-pair-ok: <理由>`。
- 不进 `versions.just`：`eso_version`（两集群独立装）、`vault_version` / `argocd_chart_version`（只有 homelab 一处）、
  chart 的 `targetRevision`（真相源是 `argocd/applications/<app>.yaml`）。
- ⚠️ oracle ansible 剧本里的 `gateway_api_version` 是 YAML 变量、`import` 不进来，仍归 V2 管。

### E1：ConfigMap 内嵌的脚本必须与同目录的源文件一致，且 pod 模板带它的 checksum

适用于「通用镜像 + ConfigMap 挂脚本」的负载，目标清单见 `check-embedded-scripts.py` 的 `TARGETS`。

- 判据：(a) ConfigMap 的 `data[<key>]` 逐字节等于源文件；(b) pod 模板注解 `checksum/<...>` 等于源文件 sha256 前 16 位。
- 为什么：两份副本（`.py` 给编辑器/linter，YAML 内嵌给 ArgoCD）的两种失效都静默且同形（git 干净、Synced、Running、
  行为是旧的）：改了 `.py` 忘了重新生成；或重新生成了，但 ConfigMap 变更不重启 pod。(b) 让脚本一变 pod 模板就变，
  ArgoCD 自然滚动重启。
- 修法：`cd k8s/helm && just gen-embedded-scripts`（= `--write`），同时重写 ConfigMap 与注解。别手改 ConfigMap 里的 Python。
- 加新目标：`TARGETS` 加一项。ConfigMap 的 `data` 只能有那一个 key 且位于文件末尾（生成器按「`key: |` 之后到文件尾」
  整段替换，以保住文件头注释）。

#### E1 的半个变体：`STAMP_ONLY`（只查 checksum）

没有、也不该有外部源文件的内嵌配置只查 (b)。例：LiteLLM 路由表抽成外部 `.yaml` 会落进同步目录被当清单 apply 而失败。
出事机制相同：subPath 挂载不接收 ConfigMap 更新，进程只在启动时读配置。

- 用 YAML 解析器取 `data[key]`（即 Kubernetes 实际看到的值）：块不必在文件末尾、`key: ""` 空标量也能取到，
  ConfigMap 与 Deployment 可同文件。⚠️ 因此依赖 pyyaml，必须 `uv run --with pyyaml python` 跑。
- `key` 可写成列表，多个 key 合成一个注解。哈希只覆盖值（按列表顺序、`\0` 分隔），不含 key 名：改 key 名必然连带改
  `subPath`，模板本身就变了。
- 当前目标（真相源 `STAMP_ONLY`）：litellm 的 `config.yaml`（[litellm-gateway.md](litellm-gateway.md)）、homepage 的
  6 个配置块、json-exporter 的 `config.yml`，注解都是 `checksum/config`。
- ⚠️ 不用 subPath 不等于免疫：json-exporter 是整目录挂载、文件会刷新，但 json_exporter 只在启动时读 `--config.file`。

验哈希别只看 CI 绿，拿集群里的真实 data 反算，应与注解相等（任意目录执行）：
```bash
kubectl --context oracle-k3s -n homepage get cm homepage-config -o json \
  | python3 -c 'import sys,json,hashlib; d=json.load(sys.stdin)["data"]; \
    print(hashlib.sha256(b"\0".join(d[k].encode() for k in ["settings.yaml","bookmarks.yaml","services.yaml","widgets.yaml","kubernetes.yaml","docker.yaml"])).hexdigest()[:16])'
```

「ConfigMap 变了 pod 不重启」的两种合法解：已走 kustomize 的目录用 `configMapGenerator`（名字带内容哈希，如 oracle
otel-collector，见 [observability-multicluster.md](observability-multicluster.md)）；裸 manifest 用 `checksum/*` 注解 +
`STAMP_ONLY`（如 litellm）。⚠️ 仍未覆盖：`k8s/helm/manifests/media/podcast.yaml` 的 nginx `default.conf`（subPath），
改它静默不生效，加进 `STAMP_ONLY` 只需一条目 + 一个注解。

## 渲染检查（`scripts/render-manifests.py`）

H/V/E 查文件与归属，读不到「ArgoCD 最终会 apply 出什么」。只活在渲染层的三类静默失效：values 写错嵌套层级
（chart 静默忽略，如 Tempo 的 `persistence` 写在 `tempo.` 下 → 一直跑 emptyDir）；多源 `$values` 渲染成空操作
（见 [argocd-app-patterns.md](argocd-app-patterns.md)「Synced 也可能是空操作」）；kustomize 漏登记 / 目录源混进非清单
（如 calibre-metadata 漏登记 `metadata-enrich.yaml`）。

判据：以 `argocd/applications/*.yaml` 为唯一输入，目录源照 ArgoCD 的 recurse/exclude 拼接、kustomize 源走
`kubectl kustomize`、chart 源走 `helm template`（带 `--version` pin 与 `$values` 文件），再 `kubeconform -strict` 逐对象校验。

- ☠️ 必须传 `--kube-version` 与 `--api-versions`：不传则 `.Capabilities.APIVersions.Has` 全为 false，ServiceMonitor /
  PrometheusRule / HTTPRoute 一类模板直接不渲染，校验的是一份与现网不同的清单。`API_VERSIONS` 是两集群
  `kubectl api-versions` 的并集，装了新 operator 要补它的 group。
- 「跳过」不是「通过」：无 schema 的类型由 `-ignore-missing-schemas` 放行并按 kind 打印。当前只跳过
  `CustomResourceDefinition` 与 `CiliumGatewayClassConfig`。
- ⚠️ 要出网拉 chart。只对网络形状的错误重试 3 次（5s/10s 退避）并打印；版本不存在这类真错误立即失败。
- ☠️ 渲染结果必须用 `RenderedLoader` 解析（裸 `=` 按 YAML 1.2 当字符串）；本地复现要让 `HELM_CONFIG_HOME` /
  `HELM_CACHE_HOME` / `HELM_DATA_HOME` 指向空目录，否则缺缓存的 repo 条目让每个 chart 都报 `no cached repo found`。
  它曾在 main 上红了 18 天没人看：[records](../records/2026-09-26-render-check-red-on-main.md)。
- ⚠️ 只证明「渲染得出来 + 结构合法」，证明不了值对（resources 填 1Mi 一样合法）。

```bash
# 仓库根目录；需 kubectl / helm / kubeconform + 联网
uv run --with pyyaml python scripts/render-manifests.py                  # 全部（约 2 分钟）
uv run --with pyyaml python scripts/render-manifests.py --app loki       # 只跑一个
uv run --with pyyaml python scripts/render-manifests.py --out /tmp/r     # 渲染结果落盘，人工 diff
```

`KUBE_VERSION`（当前 `1.35.8`）跟现网走，升 k3s 时同步改，它同时喂给 `helm --kube-version` 与 `kubeconform -kubernetes-version`。

### 同批加的 `terraform validate`

CI 逐 root 跑 `init -backend=false` + `validate`（不碰 state），拦引用不存在的变量这类到 `plan` 才炸的错误。
root 随增减而变，判据：`find . -name '*.tf' -not -path '*/.terraform/*' -exec dirname {} \; | sort -u`（仓库根目录）。

☠️ lock 文件必须覆盖 CI 平台：`.terraform.lock.hcl` 的 `h1:` 只是本机平台的哈希，跨平台靠 registry 签名的 `zh:`。
只有 `h1:` 时 CI 报 `doesn't match any of the checksums previously recorded`，本地复现不出来。新增 root 或升 provider 后补：
```bash
terraform -chdir=<root> providers lock -platform=linux_amd64 -platform=darwin_arm64   # 仓库根目录
```

## 查不出来的那些（仍需人判断）

写下来是为了不让「CI 绿了」被误当成「安全了」。

| 失效模式 | 为什么静态查不了 | 案例与对策 |
|---|---|---|
| 配置值写错嵌套层级 | 语法合法，多余的键静默忽略 | Tempo 的 `persistence` 写在 `tempo.` 下 → 一直跑 emptyDir，重启丢光 trace，而 values 宣称保留 7 天 |
| 改了配置但 Pod 不重启 | 清单没错，错在下发机制 | oracle otel-collector（已改 `configMapGenerator`）、litellm（已由 `STAMP_ONLY` 覆盖）都踩过；podcast 仍无保护，见 E1 |
| ReferenceGrant 寄生在别人的文件里 | 语法与作用都对，错在位置 | 不限定 Service 名的 grant 住在另一个服务的 route 文件里，删那条路由会断掉同 ns 的其它域名（[records](../records/2026-08-03-namespace-prune-cascade.md)）。现每个 route 文件各带自己的 grant（累加式授权） |
| 文档与集群漂移 | 格式可以完美而内容全错 | 改了架构就手动核对，用 `kubectl` 照 |
| operator 动态创建的 PVC 逃出 H4 | CNPG 的卷由 operator 按 `instances` 生成，仓库里没有 PVC 对象 | `apps-pg-1` / `zitadel-pg-1` 的备份全靠 `backup/overlays/oracle/backup-script.yaml` 的逐库 `pg_dump` 行，**apps-pg 加租户必须手工加一行**（[ADR](../decisions/shared-postgres-platform.md)） |
| 清单外创建的 ns 逃出 H5 | Helm chart 自带、`CreateNamespace=true`、operator 自建的 ns 在仓库里没有对象 | oracle 的 `external-secrets` / `cnpg-system` / `trivy-system` / `default` / `cilium-secrets` 至今无 PSA 标签。只能 `kubectl --context <ctx> get ns -L pod-security.kubernetes.io/enforce` 眼看（`just psa-status` 固定 `k3s-homelab` context）。无开放项跟踪；逐层状态见 [security.md](security.md) |
| CRD 字段放错层级 | `--validate=strict` 对 CRD 照样放行，到 ArgoCD SSA 建 typed patch 才报 `field not declared in schema`，且重试会钉住 revision | 如 CNPG `postImportApplicationSQL`（[ADR](../decisions/shared-postgres-platform.md)）。预检 `kubectl --context <ctx> apply --server-side --dry-run=server -f <file>`，字段位置以 `kubectl explain` 为准 |

**删任何清单文件前**先 `grep '^kind:' <file>`：H1 只覆盖 Namespace/CRD，ReferenceGrant 这类「语法对、位置错」的仍靠眼睛。

## 运行

```bash
# 仓库根目录
uv run --with pyyaml python scripts/check-manifests.py             # H1-H5（--list 看规则与出处）
uv run --with pyyaml python scripts/check-version-pairs.py         # V1-V4（--list 同上）
uv run --with pyyaml python scripts/check-embedded-scripts.py      # E1（--write 修复 = cd k8s/helm && just gen-embedded-scripts）
uv run --with pyyaml python scripts/render-manifests.py            # 渲染检查（需 kubectl/helm/kubeconform + 联网）
```

CI 触发路径见 [static-checks.yml](../../.github/workflows/static-checks.yml) 的 `paths`。
