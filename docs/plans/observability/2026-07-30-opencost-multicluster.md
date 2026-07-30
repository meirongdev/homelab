# OpenCost 双集群成本可观测

**日期：** 2026-07-30
**状态：** 🚧 文件已就位，待部署（未 commit / 未 push；AppProject 需先手工 apply，见「实施」）
**范围：** homelab (amd64) + oracle-k3s (arm64)，chart `opencost-2.5.28`
**结论：** 走 **collector 数据源**（不依赖 Prometheus 查询），两集群各跑一份 OpenCost，
成本指标统一汇入 homelab Prometheus 按 `cluster` 聚合。

## 背景 / 问题

想给两个 k3s 集群引入 OpenCost 做成本归因。OpenCost 的默认形态是
「查 Prometheus 算成本 → 把成本指标再吐回 Prometheus」，但当前架构有两个硬阻塞：

1. **oracle 侧没有 cAdvisor 采集。**
   `cloud/oracle/manifests/monitoring/otel-collector.yaml` 的 scrape job 只有
   cloudflared / node-exporter / kube-state-metrics / cilium-envoy / external-secrets /
   external-dns。中枢 Prometheus 里**没有 oracle 的 `container_cpu_usage_seconds_total`、
   `container_memory_working_set_bytes`** —— 这两个是 OpenCost Prometheus 数据源的硬依赖
   （`modules/prometheus-source/pkg/prom/metricsquerier.go`）。

2. **中枢 Prometheus 里两集群数据不对称。**
   oracle 的数据经 remote-write 带 `cluster="oracle-k3s"`，而 homelab 自采指标**没有
   `cluster` 标签** —— 即 `k8s/helm/values/kube-prometheus-stack.yaml:185` 那条注释
   「externalLabels 仅在 remote_write/federation 时附加，本地查询不生效」。

   后果：OpenCost 的多集群方案（`CURRENT_CLUSTER_ID_FILTER_ENABLED` + `PROM_CLUSTER_ID_LABEL`）
   在 homelab 侧会因查不到 `cluster="homelab"` 而返回空；若不开过滤，则会把 oracle 的 KSM
   数据**重复计入 homelab 成本**。

补齐这两条的代价：给 oracle otel 加 cadvisor scrape job（高基数指标跨 Tailscale 灌进
**5Gi / 7d** 的 TSDB），并给 homelab 的 kubelet / KSM / node-exporter 三个 ServiceMonitor
加 relabeling（动正在跑的监控栈）。不划算。

## 方案

### 核心决策：`collectorDataSource`

OpenCost 2.x 有独立的 `collector-source` 模块，直接读 kubelet stats/summary + K8s API，
**完全不依赖 Prometheus**，自带 10m/1h/1d 三级 rollup。

| 问题 | Prometheus 数据源 | collector 数据源 |
|------|------------------|-----------------|
| oracle 无 cAdvisor | 需加 cadvisor scrape job → 高基数跨 Tailscale 灌 5Gi TSDB | 不需要，本地直采 kubelet |
| homelab 缺 `cluster` 标签 | 需改 3 个 ServiceMonitor 的 relabeling | 无关，`CLUSTER_ID` 仅用于打标 |
| 成本历史长度 | 受限于 Prometheus 7d | 自带 **15d** 日粒度 |
| 故障域 | oracle 依赖 Tailscale + homelab 存活 | 各集群自治 |

代价：每集群约 200–300Mi 内存 + 一个 2Gi PVC。homelab 13G / oracle 24G，够。

### 架构

```
homelab OpenCost ──(ServiceMonitor + metricRelabelings: cluster=homelab)──┐
   ↑ 直采本地 kubelet                                                      │
                                                                          ├─→ 中枢 Prometheus
oracle OpenCost ──(otel prometheus/opencost receiver)────────────────────┘        │
   ↑ 直采本地 kubelet          经 Tailscale remote-write，带 cluster=oracle-k3s     ↓
                                                                            Grafana 按 cluster 聚合
```

两侧 OpenCost 仍在 `:9003` 导出 `node_total_hourly_cost`、`container_cpu_allocation`、
`kubecost_cluster_management_cost` 等指标 —— 只是**不用** Prometheus 作为输入。

### 源码验证（本方案成立的前提，均已核对 `opencost@develop`）

| 验证项 | 结论 |
|--------|------|
| collector 模式是否仍会因连不上 Prometheus 而崩 | **否**。`pkg/costmodel/router.go:531` 在 `IsCollectorDataSourceEnabled()` 时**重新赋值** `fn`，Prometheus 闭包（:476）永不执行 → `fatalErr` 恒为 nil → `log.Fatalf("Failed to create Prometheus data source")`（:562）不触发。`PROMETHEUS_SERVER_ENDPOINT` 完全惰性 |
| collector 如何访问 kubelet | `core/pkg/nodestats`：**先** apiserver proxy `/api/v1/nodes/<node>/proxy/stats/summary`，**后** 回退直连 `https://<node-ip>:10250/stats/summary`。chart 的 ClusterRole 已含 `nodes/proxy` → 主路径通，无需额外 RBAC 或 Cilium 策略 |
| collector 模式下 `:9003` 是否仍导出成本指标 | **是**。`NewCostModelMetricsEmitter(k8sCache, cloudProvider, clusterInfoProvider, costModel)` 不接收 Prometheus client，发射循环读 `KubeClusterCache.GetAllNodes()/GetAllPods()` + provider 定价 → 与数据源无关 |
| retention env 是否正确渲染 | **是**。`COLLECTOR_RESOLUTION_{10M,1H,1D}_RETENTION` 均带值（chart #336 的 bug 已在 2.5.9 修复） |
| arm64 支持 | **是**。`ghcr.io/opencost/opencost` manifest list 含 `linux/amd64` + `linux/arm64` |
| homelab ServiceMonitor 选择器 | 实测 `serviceMonitorSelector={"matchLabels":{"release":"kube-prometheus-stack"}}`，namespaceSelector `{}` → 必须加 `release` 标签，跨 ns 可被发现 |

### ⚠️ 必须处理的坑

**坑 1：导出的成本指标不带 `cluster` 标签。**
`pkg/costmodel/metrics.go` 里 `node_total_hourly_cost` 的 label 集是
`{instance, node, instance_type, region, provider_id, arch, uid}`，
`container_cpu_allocation` 是 `{namespace, pod, container, instance, node, uid}` —— **都没有 `cluster`**。

oracle 侧靠 otel 的 target label + remote-write external_labels 会补上；
**homelab 侧不会**，导致 `sum by (cluster)` 出现空标签序列。

→ homelab ServiceMonitor 必须加 `metricRelabelings` 硬写 `cluster=homelab`。
用 `metricRelabelings` 而非 `relabelings`：chart 默认 `honorLabels: true`，
metric 级 relabel 在抓取后执行，不受 honor_labels 合并规则影响，更稳。

**坑 2：MCP server 默认开启。**
渲染结果含 `MCP_SERVER_ENABLED=true` / `MCP_HTTP_PORT=8081`，会额外暴露一个
AI agent 访问成本数据的 HTTP 端点。本方案显式关掉（`opencost.mcp.enabled: false`）。

**坑 3（次要）：定价数值的科学计数法。**
`storage: 0.0000018` 会被渲染成 `"1.8e-06"` 写进 ConfigMap。虽然 Go `ParseFloat` 能解析，
但为可读性统一**用字符串引号**写定价值（已验证可消除）。

**坑 4（次要）：`GPU` / `spotCPU` / `spotRAM` 默认非零。**
chart 默认 `GPU: 0.95`、`spotCPU: 0.006655`、`spotRAM: 0.000892`。两集群都无 GPU / spot，
需显式覆盖，防止将来节点被打上 spot 标签后算出离谱数字。

**坑 5：oracle 侧资源名会带 `-oracle` 后缀（部署后实测发现）。**
ArgoCD 用 **Application 名**当 Helm release 名，而两个 App 同处 `argocd` ns 必须重名不冲突，
于是 oracle 的 release 叫 `opencost-oracle`，渲染出的 Service 变成 `opencost-oracle`。
这会让 otel 里写死的抓取目标 `opencost.opencost.svc.cluster.local:9003` **抓不到**。

→ oracle values 顶层加 `fullnameOverride: opencost`，把资源名对齐回 homelab。
副作用是 ArgoCD 会删旧建新（改名 = 重建），首次部署后立即修的话代价可忽略。

## 定价模型

两集群均用 `provider: custom`（OCI 不在 OpenCost 云账单集成范围内）。

### homelab —— 实测功耗 + 硬件摊销

已有 `node_rapl_package_joules_total`（见 `k8s/helm/manifests/power-overview-dashboard.yaml`），
可直接测：

```promql
avg_over_time(rate(node_rapl_package_joules_total{cluster="homelab"}[5m])[7d:])
```

RAPL 只覆盖 CPU package + DRAM，整机墙上功率再加 15–20W（NVMe / 风扇 / 电源损耗）。

**推导（下列数字为占位，实施第 2 步用实测值替换）：**

```
整机功率 45W → 45/1000 × 730h × ¥0.55/kWh = ¥18.1/月
硬件摊销      ¥3500 / 48 月                 = ¥72.9/月
                                     合计 ≈ ¥91/月 ≈ $12.6/月
节点小时成本 = 12.6 / 730 = $0.01726/hr

CPU:RAM 分摊比按 AWS 默认单价对该规格反推：
  8 vCPU  × 0.031611 = 0.2529  → 82.5%
  12.66GB × 0.004237 = 0.0536  → 17.5%

CPU = 0.01726 × 0.825 / 8     = $0.0018  /vCPU-hr
RAM = 0.01726 × 0.175 / 12.66 = $0.00024 /GB-hr
```

storage（local-path，节点 NVMe）：`1TB ¥450 / 48 月 / 1000GB / 730h ≈ $0.0000018 /GB-hr`。

### oracle-k3s —— OCI 牌价影子定价

Ampere A1 牌价 **$0.01/OCPU-hr、$0.0015/GB-hr**（A1 无 SMT，1 OCPU = 1 vCPU，可直接用）：

```
4 × 0.01 + 23.4 × 0.0015 = $0.0751/hr ≈ $54.8/月
```

**为什么用影子定价而不是填 0：** homelab 场景下成本看板的价值是「工作负载该放哪个集群」
的比较决策，填 0 会让 oracle 永远赢。另外 Oracle 于 2026-07 悄悄把 Free Tier A1 配额砍半
（当前 4 OCPU/24GB 是旧额度），影子定价正好量化这块的暴露面。

## 实施

### 新增/修改文件

| 路径 | 动作 |
|------|------|
| `argocd/projects/homelab.yaml` | **加 chart 仓库到 `sourceRepos` 白名单** ⚠️ 见下 |
| `k8s/helm/values/opencost.yaml` | 新增 |
| `k8s/helm/values/opencost-oracle.yaml` | 新增 |
| `argocd/applications/opencost.yaml` | 新增（root App 自动发现） |
| `argocd/applications/opencost-oracle.yaml` | 新增（仿 `falco.yaml` 跨集群模式） |
| `cloud/oracle/manifests/opencost/namespace.yaml` | 新增 |
| `cloud/oracle/manifests/kustomization.yaml` | 加 `- opencost/namespace.yaml` |
| `cloud/oracle/manifests/monitoring/otel-collector.yaml` | 加 receiver + pipeline |
| `k8s/helm/manifests/opencost-dashboard.yaml` | 新增 Grafana 看板 |
| `argocd/applications/monitoring-dashboards.yaml` | `directory.include` 追加上一行文件名 |

> ⚠️ **`homelab` AppProject 有 `sourceRepos` 白名单**，不含 opencost chart 仓库 —— 不加则两个
> Application 都会以 `application repo ... is not permitted in project 'homelab'` 拒绝同步。
>
> 且 **AppProject 不由 root App 托管**（root App 的 path 是 `argocd/applications`，
> AppProject 由 `just deploy-argocd` 第 3 步注册），**git push 不会自动生效**，
> 必须先手工 apply：
>
> ```bash
> kubectl --context k3s-homelab apply -f argocd/projects/homelab.yaml
> ```
>
> （`just deploy-argocd` 也可，但它会连带 `helm upgrade` 整个 ArgoCD，此处没必要。）

### `k8s/helm/values/opencost.yaml`（homelab）

```yaml
# OpenCost — homelab 成本归因
# 数据源: collector (不查 Prometheus, 见 docs/plans/observability/2026-07-30-opencost-multicluster.md)
opencost:
  exporter:
    defaultClusterId: homelab
    collectorDataSource:
      enabled: true
      scrapeInterval: 30s
      retention10m: 36   # 6h
      retention1h: 49    # ~2d
      retention1d: 15    # 15d
    persistence:
      enabled: true        # collector 状态需跨重启保留
      storageClass: local-path
      accessMode: ReadWriteOnce
      size: 2Gi
    resources:
      requests: { cpu: 20m, memory: 200Mi }
      limits:   { memory: 1Gi }

  # AI agent 访问成本数据的 HTTP 端点，默认开启 —— 不需要，关掉
  mcp:
    enabled: false

  customPricing:
    enabled: true
    provider: custom
    createConfigmap: true
    costModel:
      description: "homelab bare-metal (Ryzen 5600H) — 实测功耗 + 硬件摊销"
      # ⚠️ 全部用字符串，避免被渲染成科学计数法
      CPU: "0.0018"
      RAM: "0.00024"
      storage: "0.0000018"
      GPU: "0"              # 无 GPU
      spotCPU: "0.0018"     # 无 spot，与 on-demand 同价
      spotRAM: "0.00024"
      zoneNetworkEgress: "0"
      regionNetworkEgress: "0"
      internetNetworkEgress: "0"

  # collector 模式下这些完全惰性，仅为避免误读保留 false
  prometheus:
    internal: { enabled: false }
    external: { enabled: false }

  metrics:
    serviceMonitor:
      enabled: true
      scrapeInterval: 60s
      honorLabels: true
      additionalLabels:
        release: kube-prometheus-stack   # Prometheus serviceMonitorSelector 要求
      # ⚠️ OpenCost 导出的成本指标自身不带 cluster 标签，必须补，否则统一看板聚合出空标签
      metricRelabelings:
        - action: replace
          targetLabel: cluster
          replacement: homelab

  ui:
    enabled: true
```

### `k8s/helm/values/opencost-oracle.yaml`

与上面**仅三处不同**：

```yaml
opencost:
  exporter:
    defaultClusterId: oracle-k3s        # ① 
    # ... 其余同 homelab
  customPricing:
    costModel:
      description: "oracle-k3s Ampere A1 — OCI 牌价影子定价"
      CPU: "0.01"                       # ② OCI Ampere A1 牌价（已核实）
      RAM: "0.0015"
      # ⚠️ 待核实：OCI Block Volume 牌价（$/GB-月 ÷ 730）。实施前查 oracle.com/cloud/price-list
      # 先填 0，storage 成本在本环境占比极小，不阻塞上线
      storage: "0"
      GPU: "0"
      spotCPU: "0.01"
      spotRAM: "0.0015"
      zoneNetworkEgress: "0"
      regionNetworkEgress: "0"
      internetNetworkEgress: "0"        # 10TB/月免费额度内
  metrics:
    serviceMonitor:
      enabled: false                    # ③ oracle 无 Prometheus Operator，由 otel 抓
```

### `argocd/applications/opencost.yaml`

```yaml
---
# OpenCost — homelab 集群成本归因
# Chart: opencost/opencost
# Values: k8s/helm/values/opencost.yaml
# 见 docs/plans/observability/2026-07-30-opencost-multicluster.md
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: opencost
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: homelab
  sources:
    - repoURL: https://opencost.github.io/opencost-helm-chart
      chart: opencost
      targetRevision: "2.5.28"
      helm:
        valueFiles:
          - $values/k8s/helm/values/opencost.yaml
    - repoURL: https://github.com/meirongdev/homelab
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: opencost
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

### `argocd/applications/opencost-oracle.yaml`

同上，但 **destination 指 oracle**（仿 `falco.yaml`）：

```yaml
  destination:
    server: https://100.107.166.37:6443   # Tailscale 端点，与 oracle-k3s App 同
    namespace: opencost
  syncPolicy:
    syncOptions:
      # opencost ns 由 oracle-k3s kustomize App 拥有，避免双重所有权（同 falco）
      - CreateNamespace=false
      - ServerSideApply=true
```

### `cloud/oracle/manifests/opencost/namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: opencost
  labels:
    # OpenCost 只经 apiserver proxy 读 kubelet stats，无 hostNetwork/hostPath 需求
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/audit: restricted
```

### `cloud/oracle/manifests/monitoring/otel-collector.yaml` 增补

receivers 段末尾（约 L360，紧跟 `prometheus/external-dns` 之后）：

```yaml
      # OpenCost 成本指标 → homelab Prometheus (cluster=oracle-k3s)。
      # OpenCost 自身以 collector 数据源运行（不查 Prometheus），此处仅抓它的输出。
      # honor_labels 与上游 extraScrapeConfigs 一致。
      prometheus/opencost:
        config:
          scrape_configs:
            - job_name: 'opencost'
              honor_labels: true
              scrape_interval: 60s
              scrape_timeout: 10s
              static_configs:
                - targets: ['opencost.opencost.svc.cluster.local:9003']
                  labels:
                    cluster: oracle-k3s
```

pipelines 段末尾（L422 之后）：

```yaml
        metrics/opencost:
          receivers: [prometheus/opencost]
          processors: [memory_limiter, resource, batch]
          exporters: [prometheusremotewrite]
```

### `k8s/helm/manifests/opencost-dashboard.yaml`

uid `opencost-multicluster-overview`，folder `Platform`，tag 含 `curated`。4 组面板：
成本总览（月度总额 / 分集群 / 闲置占比）、节点成本（含定价校准表）、命名空间归因、分配率趋势。

**设计约束：只用 OpenCost 自身导出的指标，不掺 kube-state-metrics。**
homelab 的 KSM 指标没有 `cluster` 标签（同「背景/问题」§2），一旦掺进来跨集群聚合就会算错。
因此闲置率不走 `kube_node_status_capacity`，而是用纯 OpenCost 指标推导：

```
已分配 = Σ(container_cpu_allocation × node_cpu_hourly_cost)
       + Σ(container_memory_allocation_bytes / 1GiB × node_ram_hourly_cost)
闲置率 = 1 - 已分配 / Σ node_total_hourly_cost
```

单价语义已核对源码（`pkg/costmodel/metrics.go`）：
`totalCost := cpu*cpuCost + ramCost*(ram/1024/1024/1024) + gpu*gpuCost`
—— 即 `node_cpu_hourly_cost` 是 **$/vCPU-hr 单价**、`node_ram_hourly_cost` 是 **$/GiB-hr 单价**
（故除数用 1073741824 而非 1e9），`node_total_hourly_cost` 才是节点总额。

`$cluster` 变量取自 `label_values(node_total_hourly_cost, cluster)` 而非 `kube_node_info`，
天然只返回跑了 OpenCost 的两个集群，不会混入 `dgx-spark` / `macbook` 这类外部 node-exporter 目标。

## 分阶段落地

| # | 步骤 | 验证点 | 可回滚 |
|---|------|--------|--------|
| **0** | **`kubectl apply -f argocd/projects/homelab.yaml`**（前置，git push 不生效） | `kubectl get appproject homelab -n argocd -o jsonpath='{.spec.sourceRepos}'` 含 opencost | ✅ 移除白名单条目 |
| 1 | homelab 上线（values + Application） | `kubectl -n opencost get pod` Running；`port-forward svc/opencost 9090` UI 出数；Prometheus 里 `node_total_hourly_cost{cluster="homelab"}` 有值 | ✅ 删 App |
| 2 | 校准 homelab 定价 | 跑满 24h，用 RAPL 实测回推 CPU/RAM 单价，改 values 重新同步。看板「节点成本与单价明细」表的单价列应与 values 一致 | ✅ |
| 3 | oracle 上线（ns 入 kustomize → Application） | 本地 `port-forward` UI 出数；确认无 `Failed to create Prometheus data source` 日志 | ✅ |
| 4 | oracle otel 接入 | 中枢 Prometheus 里 `node_total_hourly_cost{cluster="oracle-k3s"}` 有值 | ✅ |
| 5 | 统一看板 | `sum by (cluster) (node_total_hourly_cost)` 返回恰好两条序列，**无空标签** | ✅ |
| 6 | （可选）UI 经 Cilium Gateway + zitadel SSO 暴露 | 同 `draw.meirong.dev` 模式 | ✅ |

**步骤 1 与 3 之间建议隔 24h** —— 先在 amd64 上把定价和看板跑顺，再复制到 arm64，
避免同时引入「新组件 + 新架构 + 新定价」三个变量。

### 落地前已完成的验证

| 验证 | 结果 |
|------|------|
| `helm template` 两份 values（2.5.28） | ✅ 各 8/7 类资源；env 中 `COLLECTOR_DATA_SOURCE_ENABLED=true`、`CLUSTER_ID` 正确、`MCP_SERVER_ENABLED=false`；定价 ConfigMap 无科学计数法；PVC 走 local-path 2Gi |
| `kubectl kustomize cloud/oracle/manifests` | ✅ opencost ns 正确生成 |
| otel 内嵌 `config.yaml` | ✅ YAML 有效；9 个 pipeline receiver 引用全部有定义 |
| 看板 15 条 PromQL 打真实 Prometheus | ✅ 15/15 语法通过（结果为空，OpenCost 尚未部署） |
| Application / ConfigMap / Namespace | ✅ `kubectl apply --dry-run=server` 全部通过（含 ArgoCD CRD schema） |

未做：`otelcol validate`（本机 docker daemon 未运行）。新 receiver 是既有
`prometheus/external-dns` 的同构复制，仅多 `honor_labels` / `scrape_timeout` 两个标准字段，
风险低；如需可跑
`docker run --rm -v <cfg>:/cfg/config.yaml otel/opentelemetry-collector-contrib:0.120.0 validate --config=/cfg/config.yaml`。

## 风险与注意事项

- **`namespace-guardrails` 不覆盖新 ns。** 该 App 只给 4 个既有 ns 下发 LimitRange，
  `opencost` ns 不会自动获得 —— values 里已显式写死 requests/limits。
- **trivy-operator 会扫新镜像**，预期有若干 CVE 告警，按 `323b2d4` 的 accept-risk 流程处理。
- **成本历史长度不对齐。** OpenCost 自带 15d 日粒度（其 UI/API 可查 15d），
  但汇入中枢 Prometheus 的指标只留 **7d**（`retention: 7d`）。
  Grafana 看板因此只能回看 7d；若要对齐，需提 Prometheus retention + PVC（当前 5Gi）。
- **`dgx-spark` / `macbook` 不是 k3s 集群**，是带 `cluster` 标签的外部 node-exporter 目标。
  成本看板的 `cluster` 变量应显式限定为 `homelab|oracle-k3s`，否则下拉框会混入无成本数据的值。
- **单节点集群的 idle 成本会很高。** 两集群都是单节点，节点成本恒定而工作负载占用有限，
  OpenCost 的 `__idle__` 分摊会占大头 —— 这是真实情况（闲置容量确实在烧电/占额度），
  但看板上要有心理预期，别误读成「归因失败」。

## 参考

- [OpenCost — On-Prem / Custom Pricing](https://www.opencost.io/docs/configuration/on-prem)
- [OpenCost — Multi-Cluster with a Single Source of Data](https://opencost.io/docs/installation/multi-cluster-single-source-of-data/)（本方案**未**采用，见「背景/问题」§2）
- [opencost-helm-chart](https://github.com/opencost/opencost-helm-chart)
- [Oracle Ampere A1 定价](https://www.oracle.com/cloud/compute/arm/)
