# ArgoCD Application Patterns

> Last updated: 2026-09-02
> Status: 生效事实
>
> 当前 ArgoCD 管理模式分析、可选 pattern 对比与取舍建议。
> 2026-07-31 随 manifests/ 目录化重组更新，见 [`decisions/manifests-directory-per-app.md`](../decisions/manifests-directory-per-app.md)。

## Current Pattern: App-of-Apps

整个 GitOps 由一个 `root` Application 驱动：

```
root (Application)
 └─ argocd/applications/*.yaml（排除 root.yaml；**非递归**，`recurse: false`，子目录不生效）
     ├── loki / tempo / sloth / kyverno / tetragon / trivy-operator /
     │   trivy-operator-oracle / falco / cnpg-operator / opencost / opencost-oracle /
     │   kube-prometheus-stack / external-dns-oracle / otel-collector
     │                          # 多源 Helm：remote chart + $values/k8s/helm/values/<app>.yaml
     ├── external-dns           # 混合多源：chart + manifests/external-dns/（目录源，管 ExternalSecret）
     ├── oracle-k3s             # Kustomize 树（跨集群推 cloud/oracle/manifests/）
     ├── backup                 # Kustomize（backup/overlays/homelab）
     ├── monitoring-dashboards  → manifests/monitoring/（目录源 + recurse）
     ├── personal-services      → manifests/personal-services/（目录源）
     ├── vault-eso              → manifests/vault-eso/（目录源）
     ├── gateway / cloudflare / kube-bench / namespace-guardrails
     │                          → manifests/<同名目录>/（目录源）
     ├── calibre-metadata       → cloud/oracle/manifests/calibre-metadata/（Kustomize，目标 oracle）
     └── kyverno-policies       → manifests/kyverno-policies/（目录源）
```

### 3 种子模式

| 子模式 | 代表 | 说明 |
|--------|------|------|
| Helm Chart + 本地 values | `loki.yaml`, `kyverno.yaml` | 多源：remote chart repo + `$values/k8s/helm/values/<app>.yaml`（oracle 变体 `<app>-oracle.yaml`）。⚠️ chart 也可以来自 **OCI registry**（当前只有 `multica.yaml`）：那时 `repoURL` 写不带 `https://` 的 `ghcr.io/<org>/charts` |
| Kustomize 目录 | `oracle-k3s.yaml` | `cloud/oracle/manifests/` 整棵 kustomize 树 |
| 目录源（目录即清单） | `personal-services.yaml`, `monitoring-dashboards.yaml` | 一个 App ↔ `k8s/helm/manifests/` 下一个子目录，目录内文件全部纳管；2026-07-31 起取代 `directory.include` glob（所有权地图见 `k8s/helm/manifests/README.md`） |

**怎么选**：第 1 种只用于上游第三方 chart；**自研应用一律用后两种，不打 chart**，
理由与推翻条件见 [decisions/no-helm-chart-for-in-house-apps](../decisions/no-helm-chart-for-in-house-apps.md)。

### 跨集群

**2026-08-02 起控制面在 oracle-k3s**，一个 ArgoCD 实例管两个集群。
**2026-09-02 起每集群一个 AppProject**（[决策](../decisions/argocd-project-per-cluster.md)）：
`homelab` project 只允许 `https://100.94.186.7:6443`（经 Tailscale），`oracle-k3s` project 只允许
`https://kubernetes.default.svc`（控制面自己所在集群）；root / projects 两个元 App 挂内置 `default`。
`Application.spec.project` 与 `destination.server` 必须配对，写错时服务端拒绝同步，CI 的 H2 也拦。
⚠️ 控制面搬家后 `kubernetes.default.svc` 的所指从 homelab 变成了 oracle，
homelab 负载必须显式写 `https://100.94.186.7:6443`，写错会把整套 homelab 负载
部署到 oracle 上。见 [runbook](../runbooks/argocd-control-plane-on-oracle.md)。

## 控制面部署形态与运维事实

- **Install**: ArgoCD 本体是 Helm 手动管理，chart `argo/argo-cd` `10.1.4`（appVersion v3.4.5；
  pin 在 `k8s/helm/justfile` 的 `argocd_chart_version`），release `argocd`，values
  `k8s/helm/values/argocd.yaml` + `values/argocd-oracle.yaml`（后者只覆盖 `crds.install=true`）。
  `just deploy-argocd`（`argocd_ctx := "oracle-k3s"`）只装 chart + AppProject；
  **Application 注册是单独的 `just deploy-argocd-apps`**。`argocd.yaml` 是唯一真相源
  （repo-server DNS-gate initContainer、Cilium Gateway 健康检查、ESO ignoreDifferences、
  `server.insecure`、禁 dex/notifications/CRDs 的瘦装全在里面）。
  历史：最初是 stock-manifest kubectl 安装，原地 Helm 采纳不可行（`.spec.selector` 不可变标签差异），
  经维护窗口重装迁移（保 CRD + Application CR + `argocd-secret`/`argocd-redis`），停机约 4 分钟，
  被管服务无感。
- **同步节奏**: 3 分钟轮询，`git push` 后自动同步；已纳管资源**不可手动 `kubectl apply`** 覆盖
  （selfHeal 会拉回，改动必须先进 Git）。
- **资源追踪**: ArgoCD v3.x 默认用 annotation 方式，被管对象带 `argocd.argoproj.io/tracking-id`，
  **不是** v2 时代的 `app.kubernetes.io/instance` label。区分 GitOps 资源与 manual-helm 资源：
  `kubectl -n <ns> get secret -l owner=helm`（有 Helm release 归档 = manual-helm）。
- **孤儿资源监控**（2026-07-31）: 两个 AppProject 各自声明 `orphanedResources`（`warn: false` +
  各自集群真实存在的那几条 ignore）：在 App 资源树里标出「集群里有、Git 里没有」的对象但不产生 warning。
  `warn` 刻意关掉：`ignore` 没有 namespace 字段，4 个 manual-helm ns 贡献 ~255 个永久无主对象。
  依据/测量/被否的 `kor` 见 [../decisions/orphaned-resources.md](../decisions/orphaned-resources.md)。
- **homelab 外部集群凭据**: Vault `secret/homelab/argocd-homelab-cluster` → ESO
  `cloud/oracle/manifests/argocd/homelab-cluster-external-secret.yaml`。
  （2026-08-02 之前方向相反，oracle 作外部集群的 `argocd-oracle-cluster` 凭据已退役。）

## Application 清单（按 project 分组）

核对: `kubectl --context oracle-k3s -n argocd get app -o custom-columns=NAME:.metadata.name,PROJECT:.spec.project`。
源→目录映射见上方树；这里只记归属与踩过坑的备注。总数别写死，以命令为准。

**project `homelab`（destination 显式 `https://100.94.186.7:6443`）**:
`backup` · `cloudflare` · `databases` · `external-dns` · `gateway` · `kube-bench` ·
`kube-prometheus-stack` · `kyverno` · `kyverno-policies` · `monitoring-dashboards` ·
`namespace-guardrails` · `opencost` · `otel-collector` · `personal-services` · `sloth` ·
`tetragon` · `trivy-operator` · `vault-eso` · `jobs-sg`（2026-08-03 上线，kustomize 目录）·
`media`（2026-08-16 上线，plain manifest 目录）· `litellm`（2026-08-16 上线，plain manifest 目录）·
`multica`（2026-08-18 上线，本仓库唯一的 OCI chart 源，见下）

**project `oracle-k3s`（destination in-cluster `kubernetes.default.svc`）**:
`oracle-k3s` · `calibre-metadata` · `cnpg-operator` · `external-dns-oracle` ·
`falco` · `loki` · `tempo` · `trivy-operator-oracle` · `opencost-oracle`

**project `default`（元 App，只写 argocd ns）**: `root`（App-of-Apps）· `projects`（托管 `argocd/projects/`）

值得记住的备注：

- **`kube-prometheus-stack`**（2026-07-31 从 manual-helm 采纳）: ⚠️ 三条硬约束改动前必读
  [../decisions/manual-helm-to-argocd-adoption.md](../decisions/manual-helm-to-argocd-adoption.md)：
  ① Application 名不能改（= release 名，进 Deployment 不可变 selector）；② `skipCrds: true`
  是刻意的（集群 CRD 停在 operator v0.89.0、运行 v0.92.1，`helm upgrade` 从不升 `crds/`，
  让 ArgoCD 接管会夹带 10 个 CRD 升级，该升级仍是待决项）；③ admission webhook `caBundle`
  已豁免（运行时 Job 注入）。
- **`otel-collector`**（homelab，2026-07-31 首次部署，此前 homelab 根本没有 collector）:
  **刻意无 metrics 管道**（kps 原生抓取）；Loki 查询标签是 OTel 风格
  （`k8s_namespace_name`，非 `namespace`）。升级纪律：chart pin 与 oracle 镜像 tag 同
  appVersion 一起动。见 [../decisions/otel-2026-alignment.md](../decisions/otel-2026-alignment.md)。
- **`loki` / `tempo`** 2026-08-02 随负载迁 oracle（destination 改 in-cluster）；`sloth`
  留 homelab（规则评估在 homelab，oracle 指标已 remote-write 过来）。
- **`personal-services`** 只剩 open-notebook 全家 + LimitRange/Quota（calibre 2026-08-03 迁 oracle）。
- **`cnpg-operator`** 必须与它管的 `zitadel-pg` `Cluster` CR 同集群（见
  [identity.md](identity.md)）。
- **`monitoring-dashboards`** 的 App 名是历史名。**改 Application 名会触发 ArgoCD 删旧建新**，
  不值得。
- **`trivy-operator-oracle`** 2026-08-03 补齐（控制面迁移后 oracle 镜像脱离 CVE 扫描的盲区，
  见 [trivy-cve-ops.md](trivy-cve-ops.md)）。
- **`backup`** = `backup/overlays/homelab`；oracle 侧不是独立 App，经 `oracle-k3s` App 引
  `backup/overlays/oracle`。
- **`external-dns` ×2** 的配置事实（upsert-only、token、通配路由）在
  [networking-ingress.md](networking-ingress.md)；oracle 侧 `helm.releaseName` 的坑见下文坑 2。
- **`multica`**（homelab，2026-08-18）: 唯一从 OCI registry 拉 chart 的 App
  （`repoURL: ghcr.io/multica-ai/charts` + `chart: multica`，**没有 `https://` 前缀**，
  写了会被当成传统 Helm repo）。两点与别的 Helm App 不同：① 它自带有状态 Postgres，
  两个 PVC 由 chart 生成，**CI 的 H4 看不见**（见 [storage.md](storage.md)）；
  ② 服务是两半的，执行任务的 daemon 在 M2 MacBook 上，daemon 离线时集群侧一切正常。
  安装/重建见 [../runbooks/multica-install.md](../runbooks/multica-install.md)。
- ~~`argocd-image-updater`~~ ❌ 2026-08-03 退役（0 个 CR 空转数月）；机制存档
  [../decisions/argocd-image-updater.md](../decisions/argocd-image-updater.md)，替代方向
  Renovate（ROADMAP #12）。

### oracle-k3s App（kustomize 树）的专有事实

- `cloud/oracle/manifests/` 自 2026-06-04 进 GitOps；auto-sync + selfHeal + **prune** 全开。
  有状态 PVC（`uptime-kuma-data-v2`）带
  `argocd.argoproj.io/sync-options: Prune=false`。
  ⚠️ 2026-08-11 退役 stirling-pdf 时踩到这条的另一面：`Prune=false` 意味着**删清单文件
  不会删卷**，PVC 会静静留成孤儿。退役带 PVC 的服务必须手工 `kubectl delete pvc`
  （2026-08-14 退役 karakeep 时，`karakeep-data`/`meilisearch-data` 即按此手工删除）。
  ⚠️ CNPG 的卷（`apps-pg-1`、`zitadel-pg-1`）不在这个名单里，也不需要在：它们由 operator
  按 `Cluster` 生成，不是清单对象，ArgoCD 的 prune 根本看不到。删 `Cluster` 才会连带删卷。
- **不入 git 的 bootstrap 依赖**: `argocd-manager` SA + cluster-admin 在
  `cloud/oracle/bootstrap/argocd-manager.yaml`，手工 apply 一次、刻意留在 kustomize 树外；
  `vault-token` Secret（`rss-system`）同为手工前置（不被 prune，见 `base/vault-store.yaml`）。
- 记录: [首次纳管](../plans/networking/2026-06-04-oracle-k3s-argocd-gitops.md) ·
  [控制面迁移/重装](../runbooks/argocd-control-plane-on-oracle.md) ·
  [整节点重建](../runbooks/oracle-k3s-rebuild.md)。

## 不由 ArgoCD 管理的组件

| 组件 | 原因 / 入口 |
|------|-------------|
| HashiCorp Vault | 需手动 init/unseal（重启恢复走 `just homelab-recover`） |
| External Secrets Operator | 依赖 Vault（`just deploy-eso` / oracle `just install-eso`） |
| Cilium | `just deploy-cilium`，pin v1.20.0（见 [networking-ingress.md](networking-ingress.md)） |
| Cloudflare Terraform | 非 K8s 资源 |

⚠️ kube-prometheus-stack / otel-collector / external-dns×2 已于 2026-07-31 迁入 ArgoCD，
justfile 里的手动部署配方已移除，**chart 版本唯一真源是 `argocd/applications/*.yaml` 的
`targetRevision`**。紧急回滚仍可 `helm -n <ns> rollback <release> <rev>`；手动重部署模板见
`k8s/helm/justfile` 头部注释。

## 新增 Application 的四个坑

2026-07 引入 OpenCost / KRR 时逐一踩到，都会导致「push 了但不生效」。

### 1. `AppProject.sourceRepos` 是白名单，而且分集群

新 chart 仓库不加进**目标集群对应的** project 文件（`argocd/projects/homelab.yaml` 或
`oracle-k3s.yaml`）的 `sourceRepos`，Application 会拒绝同步：

```
application repo https://xxx.github.io/chart is not permitted in project 'homelab'
```

2026-09-02 起 `argocd/projects/` 由 `projects` App 托管，改完 `git push` 即生效
（此前不在任何 App 的托管路径下、必须手工 apply，四篇 runbook 各提醒一遍还是漏过）。
只有全新装的 ArgoCD 才靠 `just deploy-argocd` 第 2 步先 bootstrap 一次。
同样分集群的还有 `project` 字段本身：homelab 的 App 挂 `homelab`，oracle 的挂 `oracle-k3s`，
写反了服务端拒绝、CI 的 H2 也拦（[决策](../decisions/argocd-project-per-cluster.md)）。

**OCI registry 的写法与 HTTP repo 不同**（2026-08-18 加 multica 时确立，本仓库首个 OCI chart）：
`repoURL` 与 `sourceRepos` 都写不带 `oci://` 前缀的裸地址（`ghcr.io/multica-ai/charts`），
ArgoCD 官方文档原话 "note: the `oci://` syntax is not included."。公开 registry
不需要注册 repository Secret（`enableOCI` 只对私有的有意义）：
本仓库至今零个 repository Secret，公开 chart 全靠这条。
本地核对版本用 `helm show values oci://ghcr.io/<org>/<path>/<chart>`（这里要带前缀，
helm 与 ArgoCD 在这点上不一致，容易来回踩）。

另注意 chart 版本 pin: `argocd/applications/*.yaml` 里 pin 的 `targetRevision`
部署前须 `helm search repo <chart> --versions` 核对存在（Kyverno/Trivy 落地时因 pin 了
不存在的版本 sync 失败过）。

### 2. Application 名 = Helm release 名 → 资源名会带后缀

同一个 chart 部署到两个集群时，两个 Application 同处 `argocd` ns 不能重名，
于是通常叫 `foo` / `foo-oracle`。**ArgoCD 用 Application 名当 Helm release 名**，
所以 oracle 侧渲染出的 Service 会变成 `foo-oracle`，任何写死
`foo.<ns>.svc.cluster.local` 的地方（otel 抓取目标、runbook、跨集群引用）都会失配。

**全新部署**（资源由 ArgoCD 亲手创建，如 `opencost-oracle`）：在该集群的 values 顶层加
`fullnameOverride: foo` 就够了。

⚠️ **采纳现存 Helm release 时 `fullnameOverride` 不够用**（2026-07-31 实测更正）。
release 名不只影响对象名，还会渲染进 `app.kubernetes.io/instance` 标签，而该标签在
Deployment 的 `spec.selector.matchLabels` 里，而那是**不可变字段**。
以 external-dns 采纳为例：

| 配置 | 结果 |
|---|---|
| 什么都不加 | 5 删 5 建（全部资源改名重建） |
| 只加 `fullnameOverride` | 对象名对上了，5 个对象的 selector/labels 仍不符 → 同步失败 |
| `helm.releaseName: foo` | ✅ 与 live 逐字节一致 |

正解是把 release 名与 Application 名解耦：

```yaml
sources:
  - repoURL: https://example.github.io/charts
    chart: foo
    targetRevision: "1.2.3"
    helm:
      releaseName: foo        # ← App 叫 foo-oracle，release 仍叫 foo
      valueFiles: [$values/k8s/helm/values/foo-oracle.yaml]
```

> 本地 `helm template -f values.yaml` 默认复现不出这个问题，但只要显式把 release 名
> 传成 ArgoCD 会用的那个（`helm template foo-oracle ...`）就能提前暴露。采纳前务必这样
> 比对，见 `docs/decisions/manual-helm-to-argocd-adoption.md`。

### 3. ~~`directory.include` 是显式清单，新文件不会被自动捡起~~（2026-07-31 已消除）

曾经：用 `directory.include: "{a.yaml,b.yaml,…}"` 的 App，往 `k8s/helm/manifests/` 放新文件后
**必须同步把文件名加进 glob**，否则文件静静躺着不生效（OpenCost/KRR 落地时踩到的就是它）。

现已按一个 App 一个目录重组（`docs/decisions/manifests-directory-per-app.md`），App 一律
目录源，文件放进目录即生效。**显式清单仍残留在 4 棵 kustomize 树**：
`cloud/oracle/manifests/`、`cloud/oracle/manifests/calibre-metadata/`、
`k8s/helm/manifests/jobs-sg/`、`k8s/helm/manifests/media/` 各自的 `kustomization.yaml`
`resources:` 列表，新文件必须登记（calibre-metadata 曾漏登记 `metadata-enrich.yaml`），
此坑在那 4 处仍然成立。核对：`find . -name kustomization.yaml -not -path './.git/*'`。

### 4. kustomize 全局 `namespace:` 是后置 transformer，会覆盖 JSON patch

`kustomization.yaml` 的全局 `namespace:` 字段在 JSON patch 之后执行，patch 改的
namespace 会被它覆盖回去。资源跨多个 namespace 时不要用全局字段，在每个 manifest 里
显式声明 namespace。

## Alternative Patterns

### Pattern A: ApplicationSet（推荐优先考虑）

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: helm-apps
spec:
  generators:
    - git:
        repoURL: https://github.com/meirongdev/homelab
        revision: main
        files:
          - path: "argocd/appsets/helm-apps.json"
  template:
    spec:
      project: homelab
      source:
        repoURL: '{{ chartRepo }}'
        chart: '{{ chartName }}'
        targetRevision: '{{ chartVersion }}'
        helm:
          valueFiles:
            - $values/k8s/helm/values/{{ name }}.yaml
      destination:
        server: '{{ destination }}'
        namespace: '{{ namespace }}'
```

**变体**:
- **Git generator**：按目录或配置文件批量生成（最适合已有标准化 `k8s/helm/values/` 的场景）
- **Cluster generator**：按集群列表生成，新加集群自动对所有应用生效（适合多集群同质化部署，不适合双集群异构）
- **Matrix generator**：组合两个 generator，实现集群 × 应用的笛卡尔积
- **SCM provider generator**：按 GitHub org/repo 列表生成

### Pattern B: 纯 Kustomize（摒弃 Helm source 异构）

放弃 remote Helm chart，把所有 chart 拉到本地 `vendor/`，用 `kustomize build` 灌入。ArgoCD 里统一用 `source.path` 指向本地目录。

**适合场景**：对图表有强定制需求、希望离线可用、不想依赖 chart repo 可用性。

**代价**：升级 chart 变成手动 diff 合并；失去 Helm source 的 declarative 版本声明。

### Pattern C: 带 env overlay 的 Kustomize

```
k8s/
├── base/              # 所有应用的通用 base
│   ├── loki/
│   └── kyverno/
└── overlays/
    ├── homelab/       # homelab 专用 patch
    └── oracle/        # oracle-k3s 专用 patch
```

ArgoCD 的 `oracle-k3s.yaml` 指向 `overlays/oracle`。适合多环境（staging/prod），但双集群异构场景下 Helm values 已天然是 Environment-as-overlay。

### Pattern D: 分层 App-of-Apps（模块化）

当前扁平的 `root` 统一管理。分层式将应用按领域分组：

```
root
├── observability    (管 loki/tempo/mimir/grafana)
├── security         (管 kyverno/trivy/tetragon/falco/kube-bench)
├── infra            (管 gateway/vault-eso/backup/cloudflare)
└── oracle-apps      (跨集群推 oracle-k3s)
```

**适合场景**：多人协作、按领域划分 RBAC/同步策略隔离（如安全组件 fail-open 需更保守的 sync policy）。

### Pattern E: Config Management Plugin (CMP)

不依赖 Helm/Kustomize，在 ArgoCD 里用 CMP 跑自定义渲染工具（jsonnet/ytt/tanka）。

**适合场景**：渲染管线有独特需求，Helm/Kustomize 不够。当前项目无此需求。

## Tradeoff Comparison

| 维度 | 当前 App-of-Apps | ApplicationSet | 分层 App-of-Apps |
|------|-----------------|----------------|-----------------|
| 样板文件量 | 每个 app 一个 yaml，~15-25 行，重复度高 | 大幅减少，JSON 配置驱动 | 增加，每层多一个 root |
| 声明性 | ✅ 最高，每个 app 完全显式 | ✅ 高，generator template 仍是声明式 | ✅ 最高 |
| 变更影响面 | 改一个 app 只影响自身 | 改 template 影响所有实例（风险大） | 局部隔离，安全 |
| 新加入应用成本 | 复制粘贴 yaml + 改字段 | 在 JSON 加一条记录 | 在对应层加一个 app |
| 跨集群管理 | 手工指定 destination | Cluster generator 自动化 | 手工指定 |
| 调试复杂度 | 最低，每个 app 独立对账 | 中等，需 trace generator 渲染 | 低 |
| 多集群同质化 | ❌ 不擅长 | ✅ 最擅长 | ❌ |
| ArgoCD UI 可读性 | 每个 app 独立显示 | 自动命名，每个实例独立 | 按层分组 |
| argocd-image-updater 兼容性 | ✅ 直接 annotation | ⚠️ 需注意 annotation 注入 | ✅ |

## Guidance

1. **双集群异构**（homelab 双节点/amd64 vs oracle-k3s free tier/arm64；homelab 2026-08-13 加了 worker `k8s-worker-106`）决定了 ApplicationSet 的 Cluster generator 不是最佳选择：两个集群的 manifest 差别太大，template 里会塞满条件判断，降低可读性。
2. **如果继续加 Helm 应用**（如再加 Grafana 全家桶成员）→ ApplicationSet + Git generator，用一个配置文件（例如 `argocd/appsets/helm-apps.json`）驱动，新增只需一行 JSON。⚠️ 这是**尚未采用的建议方案**，`argocd/appsets/` 目录当前不存在，本文中该路径与上面的 ApplicationSet YAML 都是示例，不是仓库现状。
3. **如果不同组件需要不同的同步策略/namespace 权限** → 分层 App-of-Apps，把 security 和 observability 拆开。
4. **跨集群**：当前 `oracle-k3s.yaml` 用 Kustomize 直推是最简单的方式。如果 oracle 侧加更多应用，在 `cloud/oracle/manifests/` 内用 Kustomize `components/` 组织，ArgoCD 侧保持一个 Application 不变，这是约束跨集群复杂度最有效的边界。
