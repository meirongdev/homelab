# ArgoCD Application Patterns

> Last updated: 2026-10-28
> Status: 生效事实
>
> GitOps 现状：App 结构与源写法、控制面形态、Application 清单、新增 App 的坑；文末是未采用的备选 pattern。
> 一目录一个 App 的理由见 [`decisions/manifests-directory-per-app.md`](../decisions/manifests-directory-per-app.md)。

## Current Pattern: App-of-Apps

`root` Application 同步 `argocd/applications/*.yaml`（排除 `root.yaml`；`recurse: false`，子目录里的 yaml
不生效），一个文件一个 Application。`projects` App 托管 `argocd/projects/`（两个 AppProject）。

### 3 种子模式

| 子模式 | 代表 | 说明 |
|--------|------|------|
| Helm chart + 本地 values（多源） | `loki`、`kyverno`、`kube-prometheus-stack` | remote chart + `$values/<该集群的 values 树>/<name>.yaml`（homelab `k8s/helm/values/`，oracle `cloud/oracle/values/`）。`external-dns` 的 git 源另带 `path: k8s/helm/manifests/external-dns`（管 ExternalSecret）。OCI chart 见坑 1 |
| Kustomize 目录 | `oracle-k3s`、`oracle-monitoring`、`calibre-metadata`、`jobs-sg`、`media`、`backup` | `oracle-k3s` = `cloud/oracle/manifests/` 根树（只剩地基与全部 Namespace）；`oracle-monitoring` 必须留 kustomize（`configMapGenerator`）；`jobs-sg` 靠 `images` 转换器按 digest 固定镜像。`resources:` 是显式清单（坑 3） |
| 目录源（目录即清单） | `personal-services`、`monitoring-dashboards`（`recurse: true`）、`oracle-rss`、`oracle-zitadel` | 一个 App ↔ 一个子目录，目录内文件全部纳管。归属地图：`k8s/helm/manifests/README.md`、`cloud/oracle/manifests/README.md` |

怎么选：第 1 种只用于上游第三方 chart；自研应用一律用后两种，不打 chart，
理由与推翻条件见 [decisions/no-helm-chart-for-in-house-apps](../decisions/no-helm-chart-for-in-house-apps.md)。

☠️ 查多源 App 的同步进度别读 `.status.sync.revision`：多源（`spec.sources`）App 的该字段恒为空串，
git sha 在 `.status.sync.revisions[]`（顺序同 `sources`，如 `["0.33.1", "<git sha>"]`）。不报错，
`until ... | grep -q '^<sha>'` 这类等待循环会永远空转，看着像 ArgoCD 卡住。单源 App 不受影响。

```bash
# 多源取数组；单源取 .status.sync.revision
kubectl --context oracle-k3s -n argocd get app <name> -o jsonpath='{.status.sync.revisions}'
```

### Synced 也可能是空操作

`Synced` 只说明 live 等于已 push 的 revision 的渲染结果，不说明渲染结果合你的意图。没 push 先看
`git log origin/main..HEAD`。⚠️ values 覆盖可能渲染成空操作：map 写 `{}` 不覆盖非空的 chart 默认值（要写 `null`，
例见 [oracle-k3s-shape-downsize](../runbooks/oracle-k3s-shape-downsize.md) 的 Loki gateway `affinity`）；list 整体替换，
漏抄 chart 默认项就丢了（`k8s/helm/values/tetragon.yaml`）。判据是看渲染结果：仓库根跑
`uv run --with pyyaml python scripts/render-manifests.py --app <app> --out <dir>` 后 diff
（CI 的渲染检查只证明结构合法，见 [manifest-safety-checks.md](manifest-safety-checks.md)）。

### 跨集群

一个 ArgoCD 实例（在 oracle-k3s）管两个集群，每集群一个 AppProject（[决策](../decisions/argocd-project-per-cluster.md)）：
`homelab` 只允许 `https://100.94.186.7:6443`（经 Tailscale），`oracle-k3s` 只允许
`https://kubernetes.default.svc`（控制面自己所在的集群）；内置 `default` 只给 `root`、`projects` 两个元 App。

☠️ `kubernetes.default.svc` 指 oracle，不是 homelab。homelab 负载必须显式写 `https://100.94.186.7:6443`，
写错会把整套 homelab 负载部署到 oracle。`spec.project` 与 `destination.server` 必须配对，写错时服务端
拒绝同步，CI 的 H2 也拦。见 [runbook](../runbooks/argocd-control-plane-on-oracle.md)。

## 控制面部署形态与运维事实

- **安装**：ArgoCD 本体是 manual-helm，刻意不自管。chart `argo/argo-cd`（pin 在 `k8s/helm/justfile` 的
  `argocd_chart_version`），release `argocd`，values `k8s/helm/values/argocd.yaml`（唯一真相源）+
  `argocd-oracle.yaml`（oracle 增量，如 `crds.install=true`）。`cd k8s/helm && just deploy-argocd`
  （`argocd_ctx := "oracle-k3s"`）只装 chart + bootstrap AppProject。☠️ Application 注册是单独的
  `just deploy-argocd-apps`，只在全新装的 ArgoCD 上、destination 已正确时跑一次；日常不跑。
- **同步**：3 分钟轮询，`git push` 后自动同步，改 `argocd/applications/*.yaml` 本身也一样（`root` 自管
  Application 对象）。已纳管资源不可手动 `kubectl apply` 覆盖，selfHeal 会拉回。全部 App 开
  automated + selfHeal + prune，`projects` 例外（`prune: false`）。
- **归属判据**：ArgoCD v3.x 用注解 `argocd.argoproj.io/tracking-id` 追踪资源（不是 v2 的
  `app.kubernetes.io/instance` label），非空即 ArgoCD 管：
  `kubectl --context <ctx> -n <ns> get deploy <name> -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}'`。
  ⚠️ 别用 `get secret -l owner=helm` 或 `helm list` 判：从 manual-helm 采纳的 release（如 `kube-prometheus-stack`、
  `external-dns`）刻意留着 `sh.helm.release.v1.*` 供 `helm rollback`，会被误判成 manual-helm
  （[采纳决策](../decisions/manual-helm-to-argocd-adoption.md)）。
- **孤儿资源**：两个 AppProject 的 `orphanedResources` 在资源树里标出「集群里有、Git 里没有」的对象。
  `warn: false` 是刻意的：`ignore` 没有 namespace 字段，manual-helm 的 ns 有大量永久无主对象
  （[决策](../decisions/orphaned-resources.md)）。
- **homelab 集群凭据**：Vault `secret/homelab/argocd-homelab-cluster` → ESO
  `cloud/oracle/manifests/argocd/homelab-cluster-external-secret.yaml` → cluster Secret `homelab-cluster`，
  token 属于 homelab 的 `kube-system/argocd-manager` SA（不进 GitOps）。☠️ 它是 oracle 纳管 homelab 的活凭据，
  清理 RBAC 时别按前缀删。oracle 侧已没有 `argocd-manager`（[记录](../records/2026-10-24-intrusion-sweep-argv-secrets-in-loki.md)）。

## Application 清单（按 project 分组）

核对: `kubectl --context oracle-k3s -n argocd get app -o custom-columns=NAME:.metadata.name,PROJECT:.spec.project`。
源与路径看 `argocd/applications/<app>.yaml`；总数以命令为准。

**project `homelab`（destination 显式 `https://100.94.186.7:6443`）**:
`backup` · `cloudflare` · `databases` · `external-dns` · `gateway` · `jobs-sg` · `kube-bench` ·
`kube-prometheus-stack` · `kyverno` · `kyverno-policies` · `litellm` · `media` · `monitoring-dashboards` ·
`multica` · `namespace-guardrails` · `opencost` · `otel-collector` · `personal-services` · `sloth` ·
`tetragon` · `trivy-operator` · `vault-eso`

**project `oracle-k3s`（destination in-cluster `kubernetes.default.svc`）**:
`oracle-k3s` · `oracle-rss` · `oracle-uptime-kuma` · `oracle-personal-services` ·
`oracle-monitoring` · `oracle-zitadel` · `calibre-metadata` · `cnpg-operator` ·
`external-dns-oracle` · `falco` · `loki` · `tempo` · `trivy-operator-oracle` ·
`opencost-oracle`

**project `default`（元 App，只写 argocd ns）**: `root`（App-of-Apps）· `projects`（托管 `argocd/projects/`）

前五个 `oracle-*` 从单体 `oracle-k3s` App 拆出（归属见 `cloud/oracle/manifests/README.md`，手法见
[runbook](../runbooks/oracle-manifests-split-to-apps.md)）。☠️ 全部 Namespace 刻意留在 `oracle-k3s`：
目录源 App 用 `directory.exclude: namespace.yaml` 排除，`oracle-monitoring` 不把它登记进 `resources:`。
Namespace 被 prune 会级联删光 ns 下一切，`Prune=false` 拦不住（[记录](../records/2026-08-03-namespace-prune-cascade.md)）。

值得记住的备注：

- **`kube-prometheus-stack`**（从 manual-helm 采纳，改前读[采纳决策](../decisions/manual-helm-to-argocd-adoption.md)）:
  ① App 名不能改（= release 名，进 Deployment 不可变 selector）；② CRD 由本 App 接管（`skipCrds` 已移除）
  且 `prune: true`：chart 移除某个 CRD 会级联删光该类型全部 CR，大版本升级前的核对（diff `crds/`、
  `status.storedVersions`）见该 Application 文件注释；③ webhook `caBundle` 已 ignoreDifferences（运行时 Job 注入）。
- **`otel-collector`**（homelab）: 刻意无 metrics 管道（kps 原生抓取）；Loki 查询标签是 OTel 风格
  （`k8s_namespace_name`，非 `namespace`）。chart pin 与 oracle 镜像 tag 同 appVersion 一起动
  （[决策](../decisions/otel-2026-alignment.md)）。
- **`loki` / `tempo`** 在 oracle；`sloth` 留 homelab（规则评估在 homelab，oracle 指标已 remote-write 过来）。
- **`cnpg-operator`** 必须与它管的 CNPG `Cluster`（`zitadel-pg`、`apps-pg`）同集群（[identity.md](identity.md)）。
- **`monitoring-dashboards`** 的 App 名是历史名。改 Application 名会触发删旧建新，不值得。
- **`trivy-operator-oracle`** 负责 oracle 镜像的 CVE 扫描（[trivy-cve-ops.md](trivy-cve-ops.md)）。
- **`backup`** = `backup/overlays/homelab`；oracle 侧不是独立 App，由 `oracle-k3s` 引 `backup/overlays/oracle`。
- **`external-dns` ×2** 的配置事实在 [networking-ingress.md](networking-ingress.md)；oracle 侧 `helm.releaseName` 见坑 2。
- **`multica`**: OCI chart（坑 1）。库在共享的 `databases/apps-pg`（`postgres.external.enabled: true`）；
  chart 生成的 `multica-backend-uploads` PVC，CI 的 H4 看不见（备份见 [storage.md](storage.md)）。执行任务的
  daemon 在 M2 MacBook 上，离线时集群侧一切正常（[runbook](../runbooks/multica-install.md)）。
- 没有任何镜像自动升级：`argocd-image-updater` 已退役（[存档](../decisions/argocd-image-updater.md)）。

## Prune 与 bootstrap 依赖

- 有状态 PVC 带 `argocd.argoproj.io/sync-options: Prune=false`。⚠️ 反面：删清单文件不会删卷，退役带 PVC 的
  服务要手工 `kubectl --context <ctx> -n <ns> delete pvc <name>`，否则卷成孤儿，App 还会一直 OutOfSync
  （[storage.md](storage.md) 有现存例子）。
- CNPG 的卷（`apps-pg-1`、`zitadel-pg-1`）由 operator 按 `Cluster` 生成，不是清单对象，prune 看不到，
  不需要这个注解；删 `Cluster` 才会连带删卷。
- 不入 git 的 bootstrap 依赖：`vault-token` Secret（`rss-system`），手工前置（见 `cloud/oracle/manifests/base/vault-store.yaml`）。
- 相关: [首次纳管](../plans/2026-06-04-oracle-k3s-argocd-gitops.md) ·
  [控制面迁移/重装](../runbooks/argocd-control-plane-on-oracle.md) · [整节点重建](../runbooks/oracle-k3s-rebuild.md)。

## 不由 ArgoCD 管理的组件

| 组件 | 原因 / 入口 |
|------|-------------|
| ArgoCD 本体 | 刻意不自管；`cd k8s/helm && just deploy-argocd` |
| HashiCorp Vault | 需手动 init/unseal；`cd k8s/helm && just deploy-vault`，重启恢复 `just homelab-recover` |
| External Secrets Operator | 依赖 Vault；`cd k8s/helm && just deploy-eso` / `cd cloud/oracle && just install-eso` |
| Cilium | 两集群各自 `just deploy-cilium`，版本 pin 在根 `versions.just`（[networking-ingress.md](networking-ingress.md)） |
| Cloudflare Terraform | 非 K8s 资源 |

⚠️ GitOps 托管的 Helm App，chart 版本唯一真源是 `argocd/applications/*.yaml` 的 `targetRevision`。
ArgoCD 不可用时仍可 `helm -n <ns> rollback <release> <rev>`，手动重部署模板见 `k8s/helm/justfile` 头部注释。

## 新增 Application 的四个坑

都会导致「push 了但不生效」。

### 1. `AppProject.sourceRepos` 是白名单，而且分集群

新 chart 仓库不加进目标集群对应的 project 文件（`argocd/projects/homelab.yaml` 或 `oracle-k3s.yaml`）的
`sourceRepos`，Application 会拒绝同步：

```
application repo https://xxx.github.io/chart is not permitted in project 'homelab'
```

`argocd/projects/` 由 `projects` App 托管，改完 `git push` 即生效（全新装的 ArgoCD 靠 `just deploy-argocd`
第 2 步 bootstrap）。`project` 字段本身也分集群，见「跨集群」。

- **OCI registry**（`multica`、`cnpg-operator`）：`repoURL` 与 `sourceRepos` 都写不带 `oci://` 前缀的裸地址
  （`ghcr.io/multica-ai/charts`；官方文档 "note: the `oci://` syntax is not included."）。公开 registry 不需要
  repository Secret（`enableOCI` 只对私有的有意义）。⚠️ 本地 helm 反而要带前缀：
  `helm show values oci://ghcr.io/<org>/<path>/<chart>`，容易来回踩。
- **版本 pin**：`targetRevision` 部署前用 `helm search repo <chart> --versions` 核对存在，否则 sync 失败。
- ☠️ **chart 仓库的可达性是静默依赖**：repo-server 有缓存，源已拉不到时 App 照样 Synced，要等重新拉 chart
  （重启 / 缓存过期 / 改 `targetRevision`）才炸。CI 渲染检查能照出来，本机常因 DNS 缓存复现不了。
  换源前做渲染等价性验证（[采纳决策](../decisions/manual-helm-to-argocd-adoption.md)），先例见
  `argocd/applications/cnpg-operator.yaml` 注释。

### 2. Application 名 = Helm release 名 → 资源名会带后缀

同一 chart 部署到两个集群时，两个 Application 同在 `argocd` ns 不能重名，通常叫 `foo` / `foo-oracle`。
**ArgoCD 用 Application 名当 Helm release 名**，oracle 侧的 Service 会变成 `foo-oracle`，写死
`foo.<ns>.svc.cluster.local` 的地方（otel 抓取目标、runbook、跨集群引用）都会失配。

- 全新部署（对象由 ArgoCD 亲手创建，如 `opencost-oracle`）：该集群 values 顶层加 `fullnameOverride: foo` 就够。
- ⚠️ 采纳现存 Helm release 时 `fullnameOverride` 不够：release 名还会渲染进 `app.kubernetes.io/instance`
  标签，它在 Deployment 不可变的 `spec.selector.matchLabels` 里。要把 release 名与 App 名解耦
  （对比实测见[采纳决策](../decisions/manual-helm-to-argocd-adoption.md)决策三）：

```yaml
sources:
  - repoURL: https://example.github.io/charts
    chart: foo
    targetRevision: "1.2.3"
    helm:
      releaseName: foo        # ← App 叫 foo-oracle，release 仍叫 foo
      valueFiles: [$values/cloud/oracle/values/foo.yaml]
```

本地 `helm template -f values.yaml` 默认复现不出；显式传 ArgoCD 会用的 release 名
（`helm template foo-oracle ...`）就能提前暴露，采纳前务必这样比对。

### 3. kustomize 树的 `resources:` 是显式清单，新文件不会被自动捡起

目录源放进目录即生效；kustomize 源的新文件必须登记进 `kustomization.yaml` 的 `resources:`，否则静静躺着
不生效（calibre-metadata 曾漏登记 `metadata-enrich.yaml`）。所有 kustomize 树都如此，仓库根列出：
`find . -name kustomization.yaml -not -path './.git/*'`。

### 4. kustomize 全局 `namespace:` 是后置 transformer，会覆盖 JSON patch

全局 `namespace:` 在 JSON patch 之后执行，patch 改的 namespace 会被覆盖回去。资源跨多个 namespace 时
不要用全局字段，在每个 manifest 里显式声明 namespace。

## Alternative Patterns

都未采用。仓库里没有 ApplicationSet，也没有 `argocd/appsets/`。

| Pattern | 做法 | 何时考虑 / 为什么现在不用 |
|---|---|---|
| **A: ApplicationSet** | 按 generator 批量生成 App：Git（目录/配置文件）、Cluster（集群列表）、Matrix（笛卡尔积）、SCM provider | 省 App yaml 样板，但改 template 影响全部实例，调试要追 generator 渲染。Cluster generator 擅长同质化多集群，本仓库双集群异构（amd64 vs arm64，manifest 差别大）。Helm App 继续增多时再评估 Git generator（[评估](../decisions/manifests-directory-per-app.md)） |
| **B: 纯 Kustomize** | chart 拉到本地 `vendor/` 用 `kustomize build` 灌入 | 强定制、要离线、不想依赖 chart repo 可用性；代价是升级 chart 变成手动 diff 合并 |
| **C: env overlay Kustomize** | `base/` + `overlays/<env>/` | 只有 `backup/` 这么用；其余场景按集群分的 Helm values 树已经是 overlay |
| **D: 分层 App-of-Apps** | `root` 下按领域（observability / security / infra）各一个子 root | 不同组件需要不同的同步策略或 RBAC 时（如安全组件要更保守的 sync policy），代价是每层多一个 root |
| **E: Config Management Plugin** | ArgoCD 里跑 jsonnet / ytt / tanka 等自定义渲染 | 当前无此需求 |

现行做法（App-of-Apps）的取舍：每个 App 一个 yaml、重复度高，但改一个只影响自身，逐 App 对账最好调试。
oracle 侧加应用照一目录一个 App（`cloud/oracle/manifests/<app>/`，Namespace 留在 `oracle-k3s`）。
