# 成本归因与资源右尺寸

> Date: 2026-07-31
> Status: Production

两套互补的工具：**OpenCost** 回答「钱花在哪」（常驻，出指标 → Grafana），
**KRR** 回答「该给多少」（周期跑，出报告 → Telegram）。

| | OpenCost | KRR |
|---|---|---|
| 形态 | 常驻 Deployment（每集群一份） | CronJob（每集群一份，周一 09:00 / 09:15） |
| 数据源 | **自带 collector**，直读 kubelet stats/summary，不查 Prometheus | 查中枢 Prometheus（cAdvisor 指标） |
| 产物 | Prometheus 指标 → Grafana 面板 `opencost-multicluster-overview` | 文本表格 → Telegram 附件 |
| 版本 | chart `opencost-2.5.28` | `robustadev/krr:v1.29.0` |
| 是否改集群 | 否 | 否（ClusterRole 全 get/list/watch） |

数据源选型的取舍见 [decisions/opencost-krr-data-sources.md](../decisions/opencost-krr-data-sources.md)。

## OpenCost

### 部署拓扑

```
homelab OpenCost ──(ServiceMonitor)───────────────┐
   ↑ 直读本地 kubelet                              ├─→ 中枢 Prometheus ─→ Grafana
oracle OpenCost ──(otel prometheus/opencost)─────┘        按 cluster 聚合
   ↑ 直读本地 kubelet    经 Tailscale remote-write
```

| 项 | homelab | oracle-k3s |
|---|---|---|
| Application | `argocd/applications/opencost.yaml` | `argocd/applications/opencost-oracle.yaml` |
| values | `k8s/helm/values/opencost.yaml` | `k8s/helm/values/opencost-oracle.yaml` |
| namespace | `opencost`（App 自建） | `opencost`（由 oracle kustomize 树持有） |
| 指标进中枢 | ServiceMonitor（需 `release: kube-prometheus-stack` 标签） | otel `prometheus/opencost` receiver |

**collector 数据源**（`collectorDataSource.enabled: true`）经 apiserver proxy 读
`/api/v1/nodes/<node>/proxy/stats/summary`，chart 的 ClusterRole 已含 `nodes/proxy`。
自带 10m/1h/1d 三级 rollup（保留 6h / 2d / **15d**），状态落在 2Gi PVC 上跨重启保留。

### 定价模型（`provider: custom`）

两个集群都不在 OpenCost 的云账单集成范围内，全部手工定价。
**定价值必须写成 YAML 字符串**，否则会被渲染成科学计数法（`0.0000018` → `"1.8e-06"`）。

| | homelab | oracle-k3s |
|---|---|---|
| 依据 | 实测功耗 + 硬件摊销 | OCI Ampere A1 牌价**影子定价** |
| CPU | `0.0018` /vCPU-hr | `0.01` /vCPU-hr |
| RAM | `0.00024` /GiB-hr | `0.0015` /GiB-hr |
| 月度合计 | ~$12.7 | ~$54.8（实付 $0） |

oracle 用牌价而非 0：看板的价值是「工作负载该放哪个集群」的比较决策，填 0 会让 oracle 永远赢。

> ⚠️ 当前 homelab 单价是**占位推导值**（假设整机 45W），尚未用实测功耗校准。
> 校准步骤见下方「运维操作」。

### 指标语义（写 PromQL 前必读）

源码 `pkg/costmodel/metrics.go`：

```go
totalCost := cpu*cpuCost + ramCost*(ram/1024/1024/1024) + gpu*gpuCost
```

- `node_cpu_hourly_cost` / `node_ram_hourly_cost` 是**单价**（$/vCPU-hr、$/**GiB**-hr），不是节点总额
- `node_total_hourly_cost` 才是节点总额
- 换算内存用 **1073741824**（GiB），不是 1e9
- `container_cpu_allocation` / `container_memory_allocation_bytes` 是 max(request, usage)

**导出的成本指标自身不带 `cluster` 标签**（label 集只有
`instance/node/instance_type/region/provider_id/arch/uid`）。标签由采集侧补：
homelab 靠 `scrapeClasses` 默认类，oracle 靠 otel target label + remote-write external_labels。

### 看板

`k8s/helm/manifests/opencost-dashboard.yaml` → Grafana `Platform` 文件夹，
uid `opencost-multicluster-overview`。

**刻意只用 OpenCost 自身的指标，不掺 kube-state-metrics** —— 闲置率不走
`kube_node_status_capacity`，而是：

```
已分配 = Σ(container_cpu_allocation × node_cpu_hourly_cost)
       + Σ(container_memory_allocation_bytes / 1073741824 × node_ram_hourly_cost)
闲置率 = 1 - 已分配 / Σ node_total_hourly_cost
```

`$cluster` 变量取自 `label_values(node_total_hourly_cost, cluster)`，天然只返回跑了
OpenCost 的两个集群，不会混入 `dgx-spark` / `macbook` 这类外部 node-exporter 目标。

> 单节点集群闲置率天然偏高（实测两边都约 **63–64%**）—— 闲置容量确实在烧电/占额度，
> 属真实情况而非归因失败。

## KRR

### 部署拓扑

| 项 | homelab | oracle-k3s |
|---|---|---|
| manifest | `k8s/helm/manifests/krr.yaml` | `cloud/oracle/manifests/monitoring/krr.yaml` |
| 时间 | 周一 09:00 | 周一 09:15（错峰） |
| Prometheus | 集群内 `kube-prometheus-stack-prometheus:9090` | 中枢，经 Tailscale `100.94.186.7:31090` |
| bot token | 复用 `monitoring/alertmanager-telegram` | 自建 ExternalSecret `krr-telegram` |

每集群各跑一个，因为 KRR 需要同时访问 Prometheus（历史用量）**和** K8s API
（枚举工作负载与当前 requests），而 K8s API 只能看本集群。

Pod 结构 `initContainers: [krr]` → `containers: [notify]`：同 Pod 的多个 container
是并行启动的，不能当流水线用，必须用 initContainer 保证 KRR 先跑完。

### 依赖的指标

KRR 只查两个（`robusta_krr/core/integrations/prometheus/metrics/{cpu,memory}.py`）：

```promql
max(rate(container_cpu_usage_seconds_total{namespace=…,pod=~…,container=…}[step])) by (container, pod, job)
max(container_memory_working_set_bytes{namespace=…,pod=~…,container=…})            by (container, pod, job)
```

始终按**真实 container 名**过滤，所以 cAdvisor 的 `container=""` Pod 级汇总序列用不到。

oracle 的这两个指标由 otel `prometheus/cadvisor` receiver 提供（见
[observability-multicluster.md](observability-multicluster.md#metrics-pipeline)）。

### 参数约定

| 参数 | 含义 | 易错点 |
|---|---|---|
| `--prometheus-label` | 标签**键**（`cluster`） | 与下一行容易搞反 |
| `-l` / `--prometheus-cluster-label` | 标签**值**（`homelab`） | **短选项不支持 `-l=value`**，会被当成值 `"=homelab"`，必须拆成两个 argv 项 |
| `--cluster` / `-c` | kubeconfig context | 集群内跑时用不上 |
| `--history-duration` | 小时数 | 默认 336(14d) > Prometheus retention 7d，**不传不会报错、只会静默用不足的数据**，故显式传 `168` |
| `--width` | 输出宽度 | 180 会把 namespace 截断成 `personal…`；附件不是终端，用 300 |

## 运维操作

### 校准 homelab 定价（首次上线后 / 硬件变更后）

```bash
# 1. 取近 7 天 RAPL 实测功耗（CPU package + DRAM）
kubectl --context k3s-homelab -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
curl -s --get --data-urlencode \
  'query=avg_over_time(rate(node_rapl_package_joules_total{cluster="homelab"}[5m])[7d:])' \
  http://127.0.0.1:9090/api/v1/query
```

2. 整机墙上功率 ≈ RAPL + 15–20W（NVMe / 风扇 / 电源损耗）
3. 按下式回推，改 `k8s/helm/values/opencost.yaml` 的 `customPricing.costModel`：

```
月成本 = 功率W/1000 × 730h × 电价 + 硬件价/摊销月数
节点小时成本 = 月成本 / 730
CPU 单价 = 节点小时成本 × 0.825 / 8      # 82.5:17.5 按 AWS 单价对本规格反推
RAM 单价 = 节点小时成本 × 0.175 / 12.66
```

4. `git push` → ArgoCD 同步；在看板「节点成本与单价明细」表核对单价列是否与 values 一致
   （不一致说明 ConfigMap 没被 OpenCost 读到）

### 采纳 KRR 推荐

KRR **只读不改**，采纳需手工改 git（`krr-enforcer` 刻意未部署，原因见 decisions）。

1. 看 Telegram 附件里 `CPU DIFF` / `MEMORY DIFF` 列
2. 忽略标 `(No data)` / `(Not enough data)` 的行 —— 那是当前没有运行 Pod 的 Job/CronJob
3. 改对应 values / manifest 的 `resources`，push
4. 内存推荐是「窗口内 max + 15%」，**7d 窗口会漏掉跨周尖峰**（如每周备份 CronJob），
   给这类工作负载留额外余量

### 手工触发一次 KRR

```bash
kubectl --context k3s-homelab create job --from=cronjob/krr krr-manual -n monitoring
# ⚠️ 会真发 Telegram。只想验证 KRR 本身则单独起 Pod 跑 initContainer 的命令，跳过 notify
```

## 排障

### 看板 `sum by (cluster)` 出现空标签序列

采集侧没打上 `cluster`。homelab 检查 `prometheusSpec.scrapeClasses` 默认类是否还在；
oracle 检查 otel `prometheus/opencost` receiver 的 `static_configs[].labels`。

### oracle 的成本/用量指标消失

八成是 otel-collector 跑着旧配置 —— 改 ConfigMap **不会**触发 DaemonSet 重启，
且 ArgoCD 全程显示 Synced/Healthy。见
[observability-multicluster.md](observability-multicluster.md#otel-collector-配置改了不生效)。

### KRR 报 `Label =xxx does not exist`

`-l=xxx` 写法错误（值里混进了 `=`）。拆成两个 argv 项。

### KRR 大量 `(Not enough data)`

窗口内没有足够历史。oracle 侧的 cAdvisor 采集自 2026-07-30 才启用，
**上线后约 7 天推荐值才有意义**。

## 相关文档

- [decisions/opencost-krr-data-sources.md](../decisions/opencost-krr-data-sources.md) — 数据源选型取舍
- [k8s-qos-resource-management.md](k8s-qos-resource-management.md) — QoS 类别与 CPU limit 档位约定
- [observability-multicluster.md](observability-multicluster.md) — 指标管道与 cluster 标签策略
- plans: [OpenCost](../plans/observability/2026-07-30-opencost-multicluster.md) ·
  [KRR](../plans/observability/2026-07-30-krr-rightsizing.md)
