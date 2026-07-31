# ArgoCD Application Patterns

> Last updated: 2026-07-31
> Status: 生效事实
>
> 当前 ArgoCD 管理模式分析、可选 pattern 对比与取舍建议。
> 2026-07-31 随 manifests/ 目录化重组更新，见 [`decisions/manifests-directory-per-app.md`](../decisions/manifests-directory-per-app.md)。

## Current Pattern: App-of-Apps

整个 GitOps 由一个 `root` Application 驱动：

```
root (Application)
 └─ argocd/applications/*.yaml（排除 root.yaml）
     ├── loki / tempo / sloth / kyverno / tetragon / trivy-operator /
     │   argocd-image-updater / falco / cnpg-operator / opencost / opencost-oracle /
     │   kube-prometheus-stack / external-dns-oracle / otel-collector
     │                          # 多源 Helm：remote chart + $values/k8s/helm/values/<app>.yaml
     ├── external-dns           # 混合多源：chart + manifests/external-dns/（目录源，管 ExternalSecret）
     ├── oracle-k3s             # Kustomize 树（跨集群推 cloud/oracle/manifests/）
     ├── backup                 # Kustomize（backup/overlays/homelab）
     ├── monitoring-dashboards  → manifests/monitoring/（目录源 + recurse）
     ├── personal-services      → manifests/personal-services/（目录源）
     ├── vault-eso              → manifests/vault-eso/（目录源）
     ├── bifrost / gateway / cloudflare / kube-bench / namespace-guardrails
     │                          → manifests/<同名目录>/（目录源）
     ├── calibre-metadata       → manifests/calibre-metadata/（Kustomize）
     └── kyverno-policies       → manifests/kyverno-policies/（目录源）
```

### 3 种子模式

| 子模式 | 代表 | 说明 |
|--------|------|------|
| Helm Chart + 本地 values | `loki.yaml`, `kyverno.yaml` | 多源：remote chart repo + `$values/k8s/helm/values/<app>.yaml`（oracle 变体 `<app>-oracle.yaml`） |
| Kustomize 目录 | `oracle-k3s.yaml` | `cloud/oracle/manifests/` 整棵 kustomize 树 |
| 目录源（目录即清单） | `personal-services.yaml`, `monitoring-dashboards.yaml` | 一个 App ↔ `k8s/helm/manifests/` 下一个子目录，目录内文件全部纳管；2026-07-31 起取代 `directory.include` glob（所有权地图见 `k8s/helm/manifests/README.md`） |

### 跨集群

一个 ArgoCD 实例管两个集群 —— `AppProject.destinations` 声明 `homelab` 和 `oracle-k3s` 端点（Tailscale），`Application.spec.destination.server` 选目标。

## 新增 Application 的三个坑

2026-07 引入 OpenCost / KRR 时逐一踩到，都会导致「push 了但不生效」。

### 1. `AppProject.sourceRepos` 是白名单，且**不由 GitOps 托管**

新 chart 仓库不加进 `argocd/projects/homelab.yaml` 的 `sourceRepos`，Application 会拒绝同步：

```
application repo https://xxx.github.io/chart is not permitted in project 'homelab'
```

更麻烦的是 **AppProject 不在 root App 的托管路径下**（root App 的 path 是
`argocd/applications/`，AppProject 由 `just deploy-argocd` 第 3 步注册）——
**`git push` 不会让它生效**，必须手工 apply：

```bash
kubectl --context k3s-homelab apply -f argocd/projects/homelab.yaml
```

（`just deploy-argocd` 也行，但会连带 `helm upgrade` 整个 ArgoCD，通常没必要。）

### 2. Application 名 = Helm release 名 → 资源名会带后缀

同一个 chart 部署到两个集群时，两个 Application 同处 `argocd` ns 不能重名，
于是通常叫 `foo` / `foo-oracle`。**ArgoCD 用 Application 名当 Helm release 名**，
所以 oracle 侧渲染出的 Service 会变成 `foo-oracle` —— 任何写死
`foo.<ns>.svc.cluster.local` 的地方（otel 抓取目标、runbook、跨集群引用）都会失配。

**全新部署**（资源由 ArgoCD 亲手创建，如 `opencost-oracle`）：在该集群的 values 顶层加
`fullnameOverride: foo` 就够了。

⚠️ **采纳现存 Helm release 时 `fullnameOverride` 不够用**（2026-07-31 实测更正）。
release 名不只影响对象名，还会渲染进 `app.kubernetes.io/instance` 标签，而该标签在
Deployment 的 **`spec.selector.matchLabels`** 里 —— 那是**不可变字段**。
以 external-dns 采纳为例：

| 配置 | 结果 |
|---|---|
| 什么都不加 | **5 删 5 建**（全部资源改名重建） |
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

> 本地 `helm template -f values.yaml` 默认**复现不出**这个问题，但只要显式把 release 名
> 传成 ArgoCD 会用的那个（`helm template foo-oracle ...`）就能提前暴露 —— 采纳前务必这样
> 比对，见 `docs/decisions/manual-helm-to-argocd-adoption.md`。

### 3. ~~`directory.include` 是显式清单，新文件不会被自动捡起~~（2026-07-31 已消除）

曾经：用 `directory.include: "{a.yaml,b.yaml,…}"` 的 App，往 `k8s/helm/manifests/` 放新文件后
**必须同步把文件名加进 glob**，否则文件静静躺着不生效（OpenCost/KRR 落地时踩到的就是它）。

现已按**一个 App 一个目录**重组（`docs/decisions/manifests-directory-per-app.md`），App 一律
目录源，文件放进目录即生效。**显式清单仍残留在 kustomize 树**——`cloud/oracle/manifests/`
与 `k8s/helm/manifests/calibre-metadata/` 的 `kustomization.yaml` `resources:` 列表，新文件
必须登记（calibre-metadata 曾漏登记 `metadata-enrich.yaml`），此坑在那里仍然成立。

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
- **Cluster generator**：按集群列表生成，新加集群自动对所有应用生效（适合多集群同质化部署，**不**适合双集群异构）
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

1. **双集群异构**（homelab 单节点 vs oracle-k3s free tier）决定了 ApplicationSet 的 Cluster generator 不是最佳选择——两个集群的 manifest 差别太大，template 里会塞满条件判断，降低可读性。
2. **如果继续加 Helm 应用**（如再加 Grafana 全家桶成员）→ **ApplicationSet + Git generator**，用一个配置文件（例如 `argocd/appsets/helm-apps.json`）驱动，新增只需一行 JSON。⚠️ 这是**尚未采用的建议方案**，`argocd/appsets/` 目录当前不存在——本文中该路径与上面的 ApplicationSet YAML 都是示例，不是仓库现状。
3. **如果不同组件需要不同的同步策略/namespace 权限** → **分层 App-of-Apps**，把 security 和 observability 拆开。
4. **跨集群**：当前 `oracle-k3s.yaml` 用 Kustomize 直推是最简单的方式。如果 oracle 侧加更多应用，在 `cloud/oracle/manifests/` 内用 Kustomize `components/` 组织，ArgoCD 侧保持一个 Application 不变，这是约束跨集群复杂度最有效的边界。
