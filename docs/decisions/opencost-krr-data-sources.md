# OpenCost 与 KRR 的数据源选型

> 日期: 2026-07-30（2026-07-31 更正一处论据）
> 状态: 已实施

## 上下文

同一周内引入两个工具：OpenCost（成本归因）和 KRR（资源右尺寸）。两者都需要
**容器级用量历史**，而当时的中枢 Prometheus 里只有 homelab 有：

| 指标 | homelab | oracle-k3s |
|---|---|---|
| `container_cpu_usage_seconds_total` | 144 | **0** |
| `container_memory_working_set_bytes` | 144 | **0** |

原因：oracle 的 otel-collector 只抓 node-exporter / KSM / cloudflared / cilium-envoy /
external-secrets / external-dns，**没有 kubelet cAdvisor**。

同一个缺口，两个工具给出了不同的答案。

## 决策一：OpenCost 用 collector 数据源，不查 Prometheus

### 选项

| 选项 | 评价 |
|---|---|
| A. Prometheus 数据源 + 给 oracle 补全量 cAdvisor | oracle 侧本来就查不到数；补全量 cAdvisor 意味着把高基数指标跨 Tailscale 灌进 **5Gi / 7d** 的 TSDB |
| B. 在 oracle 上另起一个本地 Prometheus | 多一套要维护的有状态组件，为一个消费者不值 |
| **C. collector 数据源（选中）** | OpenCost 2.x 自带，直读 kubelet stats/summary + K8s API，完全不碰 Prometheus |

### 理由

1. **oracle 侧 Prometheus 数据源直接不成立** —— 没有 cAdvisor 就没有输入。
2. **自带更长的历史**：collector 有 10m/1h/1d 三级 rollup，日粒度保留 **15d**；
   中枢 Prometheus 只有 7d。
3. **故障域自治**：oracle 不必依赖 Tailscale 通、也不必依赖 homelab 存活。
4. 代价小：每集群约 200–300Mi 内存 + 2Gi PVC。

### 源码前提（已核对 `opencost@develop`）

- `pkg/costmodel/router.go:531`：`IsCollectorDataSourceEnabled()` 时**重新赋值**数据源工厂，
  Prometheus 闭包（:476）永不执行 → `fatalErr` 恒 nil → `log.Fatalf("Failed to create
  Prometheus data source")` 不触发。**`PROMETHEUS_SERVER_ENDPOINT` 完全惰性**，
  即使指向不存在的地址也不影响。
- `core/pkg/nodestats`：先走 apiserver proxy，失败才回退直连 `:10250`。
  chart ClusterRole 已含 `nodes/proxy`，主路径通，无需额外 RBAC。
- `NewCostModelMetricsEmitter(k8sCache, cloudProvider, clusterInfoProvider, costModel)`
  不接收 Prometheus client，发射循环只读 clusterCache + 定价 →
  **`:9003` 的指标导出与数据源无关**，换 collector 不影响看板。

### 一处论据是错的（2026-07-31 更正）

当初还写了第二条理由：「homelab 自采指标没有 `cluster` 标签，所以 OpenCost 的
`CURRENT_CLUSTER_ID_FILTER_ENABLED` 多集群方案两侧都不成立」。**这是错的。**

`kube-prometheus-stack.yaml` 有 `scrapeClasses` 默认类（`default: true`），
对所有 ServiceMonitor 统一打 `cluster=homelab`。误读来源是该文件里一条只针对
`externalLabels` 的注释，被当成了整体结论。

反证：chart 自带的 kube-state-metrics ServiceMonitor 没有任何 relabeling，
其指标却带 `cluster="homelab"`。

**对决策无影响**（理由 1/2/3 独立成立），但据此在 opencost values 里加的
per-ServiceMonitor `metricRelabelings` 是冗余的，已移除。

**教训**：一条限定作用域的注释（"externalLabels 不影响本地查询"）不等于全局结论；
同一文件里往前翻 2 行就有 `scrapeClasses`。下结论前先查有没有别的机制在解同一个问题。

## 决策二：KRR 反过来，专门给它补 cAdvisor

KRR 只认 Prometheus，没有 collector 那种旁路，所以决策一的办法用不上。

选中：给 oracle otel 加 `prometheus/cadvisor` receiver，但 **keep 正则只留 KRR 需要的
2 个指标**。

实测：该端点共 **9223** 条 series，KRR 只需 **280** 条 —— 丢弃 97%，
跨 Tailscale 增量可忽略。做法与既有的 `prometheus/cilium-envoy` job 一致
（那个 job 也是 keep 正则丢掉 ~5000 条 Envoy 内部指标）。

额外 drop `container=""` 的 Pod 级汇总：KRR 的查询永远带真实 container 名。

> 这批指标**不足以**支撑 OpenCost 的 Prometheus 数据源 —— 后者还需要
> `container_fs_*` / `container_network_*`。所以决策一不因此翻案。

### RBAC：必须显式给 `nodes/metrics`

kubelet 自己做 SubjectAccessReview，走 `metrics` 子资源，只给 `nodes` 不够。

> ⚠️ **`kubectl auth can-i get nodes/metrics --as=<sa>` 在这里会误报 `yes`。**
> 用该 SA 起 Pod 直连 kubelet 实测返回 **HTTP 403**。
> can-i 判断的是 API server 的视角，kubelet 走的是另一条授权路径 —— 以实际请求为准。

## 决策三：不部署 krr-enforcer

Robusta 提供 `krr-enforcer`（Helm chart），能把推荐值自动 patch 到工作负载上。**不用。**

它与 ArgoCD 的 `automated.selfHeal: true` 直接冲突，会形成无限循环：

```
enforcer patch requests → ArgoCD 判 OutOfSync → selfHeal 改回 git 里的值
→ enforcer 再 patch → …
```

在 GitOps 下，工作负载的 spec 真相源是 git。要采纳推荐就改 git，
让 KRR 停在「建议」这一步。

## 后果

- 两个工具对 oracle 的可用性时间不同步：OpenCost 上线即可用（collector 自采），
  KRR 要等约 **7 天** cAdvisor 历史积累后推荐值才有意义。
- oracle 的 otel-collector 现在多了两个 receiver（`prometheus/opencost`、
  `prometheus/cadvisor`），改它的 ConfigMap 后**必须手工 `rollout restart`**，
  否则静默跑旧配置。
- OpenCost 的成本历史（15d）比中枢 Prometheus（7d）长，看板只能回看 7d，
  但 OpenCost 自己的 UI/API 能看 15d。想对齐需提 retention + 扩 PVC。

## 相关文档

- [reference/cost-and-rightsizing.md](../reference/cost-and-rightsizing.md) — 落地架构与运维操作
- plans: [OpenCost](../plans/observability/2026-07-30-opencost-multicluster.md) ·
  [KRR](../plans/observability/2026-07-30-krr-rightsizing.md)
