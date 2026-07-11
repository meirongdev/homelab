# ArgoCD Application Patterns

> 当前 ArgoCD 管理模式分析、可选 pattern 对比与取舍建议。
> Date: 2026-07-08

## Current Pattern: App-of-Apps

整个 GitOps 由一个 `root` Application 驱动：

```
root (Application)
 └─ argocd/applications/*.yaml（排除 root.yaml）
     ├── loki.yaml           # 多源 Helm (remote chart + local values)
     ├── kyverno.yaml         # 同上
    ├── kyverno-policies.yaml

     ├── tempo.yaml           # 同上
     ├── trivy-operator.yaml  # Helm
     ├── tetragon.yaml        # Helm
     ├── falco.yaml           # Helm
     ├── sloth.yaml           # Helm
     ├── argocd-image-updater.yaml
     ├── oracle-k3s.yaml      # Kustomize 目录（跨集群推 oracle-k3s）
     ├── personal-services.yaml  # directory.include 子集
     ├── vault-eso.yaml          # directory.include 子集
     ├── bifrost.yaml            # directory.include 单文件
     ├── gateway.yaml            # directory.include 单文件
     ├── monitoring-dashboards.yaml
     ├── calibre-metadata.yaml
     ├── namespace-guardrails.yaml
     ├── kube-bench.yaml
     ├── backup.yaml
     └── cloudflare.yaml
```

### 3 种子模式

| 子模式 | 代表 | 说明 |
|--------|------|------|
| Helm Chart + 本地 values | `loki.yaml`, `kyverno.yaml` | 多源：remote chart repo + `$values/k8s/helm/values/` |
| Kustomize 目录 | `oracle-k3s.yaml` | `cloud/oracle/manifests/` 整棵 kustomize 树 |
| directory.include 子集 | `personal-services.yaml` | 从 `k8s/helm/manifests/` 用 glob 选特定文件 |

### 跨集群

一个 ArgoCD 实例管两个集群 —— `AppProject.destinations` 声明 `homelab` 和 `oracle-k3s` 端点（Tailscale），`Application.spec.destination.server` 选目标。

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
2. **如果继续加 Helm 应用**（如再加 Grafana 全家桶成员）→ **ApplicationSet + Git generator**，用 `argocd/appsets/helm-apps.json` 配置驱动，新增只需一行 JSON。
3. **如果不同组件需要不同的同步策略/namespace 权限** → **分层 App-of-Apps**，把 security 和 observability 拆开。
4. **跨集群**：当前 `oracle-k3s.yaml` 用 Kustomize 直推是最简单的方式。如果 oracle 侧加更多应用，在 `cloud/oracle/manifests/` 内用 Kustomize `components/` 组织，ArgoCD 侧保持一个 Application 不变，这是约束跨集群复杂度最有效的边界。
