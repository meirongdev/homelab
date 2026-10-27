# 成本归因与资源右尺寸

> Last updated: 2026-10-28
> Status: 生效事实

两套互补的工具：**OpenCost** 回答「钱花在哪」（常驻，出指标 → Grafana），
**KRR** 回答「该给多少」（周期跑，出报告 → Telegram）。

| | OpenCost | KRR |
|---|---|---|
| 形态 | 常驻 Deployment（每集群一份） | CronJob（每集群一份，周一 09:00 / 09:15） |
| 数据源 | 自带 collector，直读 kubelet stats/summary，不查 Prometheus | 查中枢 Prometheus（cAdvisor 指标） |
| 产物 | Prometheus 指标 → Grafana 面板 `opencost-multicluster-overview` | 文本表格 → Telegram 附件 |
| 版本 | chart `opencost-2.5.28` | `robustadev/krr:v1.30.0` |
| 是否改集群 | 否 | 否（ClusterRole 全 get/list/watch） |

数据源选型的取舍见 [decisions/opencost-krr-data-sources.md](../decisions/opencost-krr-data-sources.md)。
实际数值（单价、retention、资源）以 values 与清单为准，本文只写原则与判据。

## OpenCost

### 部署拓扑

两边各自直读本地 kubelet，指标汇进中枢 Prometheus，Grafana 按 `cluster` 聚合：

| 项 | homelab | oracle-k3s |
|---|---|---|
| Application | `argocd/applications/opencost.yaml` | `argocd/applications/opencost-oracle.yaml` |
| values | `k8s/helm/values/opencost.yaml` | `cloud/oracle/values/opencost.yaml` |
| namespace | `opencost`（App 自建） | `opencost`（由 oracle kustomize 树持有） |
| 指标进中枢 | ServiceMonitor（需 `release: kube-prometheus-stack` 标签） | otel `prometheus/opencost` receiver，经 Tailscale remote-write |

**collector 数据源**（`collectorDataSource.enabled: true`）经 apiserver proxy 读
`/api/v1/nodes/<node>/proxy/stats/summary`，chart 的 ClusterRole 已含 `nodes/proxy`。
自带 10m/1h/1d 三级 rollup，状态是 emptyDir 里的 WAL，重建即归零。☠️ 启动时要全量重放 WAL 才
bind :9003，重放窗口 = 最长那档 retention（`retention1d`），所以 retention、抓取间隔与 startupProbe
预算是联动的，改之前读两份 values 的注释与
[复盘](../records/2026-08-19-opencost-bingen-replay-crashloop.md)。

### 定价模型（`provider: custom`）

两个集群都不在 OpenCost 的云账单集成范围内，全部手工定价，单价写在各自 values 的
`customPricing.costModel`：homelab 按实测功耗 + 硬件摊销，oracle 按 OCI Ampere A1 牌价影子定价（实付 $0）。
**定价值必须写成 YAML 字符串**，否则会被渲染成科学计数法（`0.0000018` → `"1.8e-06"`）。

- oracle 用牌价而非 0：看板的价值是「工作负载该放哪个集群」的比较决策，填 0 会让 oracle 永远赢。
- 单价不随节点数或 shape 变，**月度合计会变**（oracle 缩 shape 后看板上它的优势跟着缩水，这是有意的：
  余量确实少了，见 [runbooks/oracle-k3s-shape-downsize.md](../runbooks/oracle-k3s-shape-downsize.md)）。
  别把合计当常量，现取：`sum by (cluster)(node_total_hourly_cost) * 730`。
- ⚠️ homelab 单价是占位推导值（按整机 45W 估算，偏保守；实测空闲功耗更低，见
  [homelab-host-power-thermal.md](homelab-host-power-thermal.md)）。校准步骤见下方「运维操作」。

### 指标语义（写 PromQL 前必读）

源码 `pkg/costmodel/metrics.go`：

```go
totalCost := cpu*cpuCost + ramCost*(ram/1024/1024/1024) + gpu*gpuCost
```

- `node_cpu_hourly_cost` / `node_ram_hourly_cost` 是**单价**（$/vCPU-hr、$/GiB-hr），不是节点总额
- `node_total_hourly_cost` 才是节点总额
- 换算内存用 1073741824（GiB），不是 1e9
- `container_cpu_allocation` / `container_memory_allocation_bytes` 是 max(request, usage)

**导出的成本指标自身不带 `cluster` 标签**（label 集只有
`instance/node/instance_type/region/provider_id/arch/uid`）。标签由采集侧补：
homelab 靠 `scrapeClasses` 默认类，oracle 靠 otel target label + remote-write external_labels。

### 看板

`k8s/helm/manifests/monitoring/dashboards/opencost-dashboard.yaml` → Grafana `Platform` 文件夹，
uid `opencost-multicluster-overview`。

**刻意只用 OpenCost 自身的指标，不掺 kube-state-metrics**：闲置率不走
`kube_node_status_capacity`，而是：

```
已分配 = Σ(container_cpu_allocation × node_cpu_hourly_cost)
       + Σ(container_memory_allocation_bytes / 1073741824 × node_ram_hourly_cost)
闲置率 = 1 - 已分配 / Σ node_total_hourly_cost
```

`$cluster` 变量取自 `label_values(node_total_hourly_cost, cluster)`，天然只返回跑了
OpenCost 的两个集群，不会混入 `dgx-spark` / `macbook` 这类外部 node-exporter 目标。

小集群闲置率天然偏高。闲置容量确实在烧电/占额度，属真实情况而非归因失败。

## KRR

### 部署拓扑

| 项 | homelab | oracle-k3s |
|---|---|---|
| manifest | `k8s/helm/manifests/monitoring/krr.yaml` | `cloud/oracle/manifests/monitoring/krr.yaml` |
| 时间 | 周一 09:00 | 周一 09:15（错峰） |
| Prometheus | 集群内 `kube-prometheus-stack-prometheus:9090` | 中枢，经 Tailscale `100.94.186.7:31090` |
| bot token | 复用 `monitoring/alertmanager-telegram` | 自建 ExternalSecret `krr-telegram` |

每集群各跑一个，因为 KRR 需要同时访问 Prometheus（历史用量）和 K8s API
（枚举工作负载与当前 requests），而 K8s API 只能看本集群。

Pod 结构 `initContainers: [krr, mem-profile]` → `containers: [notify]`：同 Pod 的多个 container
是并行启动的，不能当流水线用，必须用 initContainer 保证报告先生成完。

### 依赖的指标

KRR 只查两个（`robusta_krr/core/integrations/prometheus/metrics/{cpu,memory}.py`）：

```promql
max(rate(container_cpu_usage_seconds_total{namespace=…,pod=~…,container=…}[step])) by (container, pod, job)
max(container_memory_working_set_bytes{namespace=…,pod=~…,container=…})            by (container, pod, job)
```

始终按真实 container 名过滤，所以 cAdvisor 的 `container=""` Pod 级汇总序列用不到。
oracle 的这两个指标由 otel `prometheus/cadvisor` receiver 提供（见
[observability-multicluster.md](observability-multicluster.md#metrics-pipeline)）。

### 参数约定

| 参数 | 含义 | 易错点 |
|---|---|---|
| `--prometheus-label` | 标签键（`cluster`） | 与下一行容易搞反 |
| `-l` / `--prometheus-cluster-label` | 标签值（`homelab`） | **短选项不支持 `-l=value`**，会被当成值 `"=homelab"`，必须拆成两个 argv 项 |
| `--cluster` / `-c` | kubeconfig context | 集群内跑时用不上 |
| `--history-duration` | 小时数 | 默认 336(14d) > Prometheus retention 7d，**不传不会报错、只会静默用不足的数据**，故显式传 `168` |
| `--width` | 输出宽度 | 180 会把 namespace 截断成 `personal…`；附件不是终端，用 300 |

### 内存构成附表（RSS / PSS / USS）

KRR 的内存基准 `working_set` **含页缓存**，定 request 时会系统性高报。
`krr.yaml` 的 `mem-profile` initContainer 因此在报告尾部追加一张构成表
（源 `k8s/helm/manifests/monitoring/krr-mem-profile.py`，两集群共用、E1 管一致性）。

> **怎么读、什么时候该采纳** → [runbooks/krr-report-triage.md § 1](../runbooks/krr-report-triage.md)
> （含实测的高报幅度对照表）。本节只讲它怎么产生的。

- 列：WS / RSS / PSS / USS / 页缓存占比 / 按 RSS 重算的建议值 / Δ
- 排序按「要改动的绝对量」，**不按页缓存占比**（后者会把 2Mi 的容器顶到最前）
- 只列**当前存在**的容器（与 `kube_pod_container_info` 取交集）：不过滤的话 `max_over_time[7d]`
  会把已消亡的 Trivy 扫描 Job 算进来，而它们的容器名取自被扫的工作负载（`trivy-system/jellyfin`…），
  残影能占到一半行数
- **fail-open**：查不到指标只留一行说明，绝不让周报发不出去
- 跑在 KRR 自己的镜像里（它本来就是 python 镜像）→ 零新镜像、零新 registry 拉取

### PSS/USS 采集器

cAdvisor **不导出 PSS/USS**，由 `node-mem-profile` DaemonSet 补（两集群
`manifests/monitoring/node-mem-profile.yaml`，读 `/proc/<pid>/smaps_rollup` → 写 node-exporter 的
textfile 目录；两集群 node-exporter 都已开着 `--collector.textfile.directory`，**不需要改它**）。
开销可忽略（一轮全扫百毫秒级 CPU，5 分钟一轮）。

☠️ 三个必须的条件，缺任何一个都是**静默漏采**（表里显示 `—`，不报错不告警；实测数字在清单注释里）：

- `hostPID: true`：缺了只看得见采集器自己那几个进程。
- `runAsUser: 0` + `CAP_SYS_PTRACE`：**root 单独不够**，容器 root 默认不带这个 capability，大部分进程读不到。
- `appArmorProfile: Unconfined`：privileged 容器（cilium-agent / tetragon / falco）跑在 unconfined 下，
  受限 profile 的进程 ptrace 不了它们。

⚠️ 指标标签是 `k8s_namespace` / `k8s_pod_name` / `k8s_container_name`，**刻意不叫**
`namespace`/`pod`/`container`：后者会与抓取 node-exporter 时注入的目标标签撞名，被改写成
`exported_*`，表现为 series 数正确、表里却全是 `—`。

自身健康看 `node_mem_profile_last_success_timestamp_seconds` / `node_mem_profile_containers`
（textfile 的旧值会一直被吐出去，进程活着 ≠ 在采）。

## 运维操作

### 校准 homelab 定价（首次上线后 / 硬件变更后）

RAPL 查询为空时先看 `node_scrape_collector_success{collector="rapl"}`（`energy_uj` 是 root-only，
修法见 [homelab-host-power-thermal.md](homelab-host-power-thermal.md) 的「监控」节）；
历史不足 7 天时 `[7d:]` 换短窗口。

```bash
# 1. 取近 7 天 RAPL 实测功耗（CPU package + DRAM）
#    cluster="homelab" 同时命中两台宿主，按 nodename（proxmox-pve / storage-106）区分
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

KRR 只读不改，采纳需手工改 git（`krr-enforcer` 刻意未部署，原因见 decisions）。
推荐值口径：CPU 取 p95；内存取窗口内 max + 15%（`峰值 ≈ 推荐 ÷ 1.15`）；内存 100Mi、CPU 10m 有地板，
**恰好等于地板的推荐不是测量结果**。内存窗口 7d（对齐 Prometheus retention），跨周尖峰会落在窗外
（如每周备份 CronJob），这类工作负载要自行留余量。

**拿到报告之后怎么处理 → [runbooks/krr-report-triage.md](../runbooks/krr-report-triage.md)**
（口径详解、五类分诊、哪些刻意不采纳、改哪里怎么下发、改完怎么验证真的生效）。

### 手工触发一次 KRR

```bash
kubectl --context k3s-homelab create job --from=cronjob/krr krr-manual -n monitoring
# ⚠️ 会真发 Telegram。只想验证 KRR 本身则单独起 Pod 跑 initContainer 的命令，跳过 notify
```

## 排障

| 症状 | 原因与处理 |
|---|---|
| 看板 `sum by (cluster)` 出现空标签序列 | 采集侧没打上 `cluster`。homelab 查 `prometheusSpec.scrapeClasses` 默认类是否还在；oracle 查 otel `prometheus/opencost` receiver 的 `static_configs[].labels` |
| oracle 的成本/用量指标消失 | 八成是 otel-collector 跑着旧配置：改 ConfigMap **不会**触发 DaemonSet 重启，且 ArgoCD 全程 Synced/Healthy。见 [observability-multicluster.md](observability-multicluster.md#otel-collector-配置改了不生效) |
| KRR 报 `Label =xxx does not exist` | `-l=xxx` 写法错误（值里混进了 `=`），拆成两个 argv 项 |
| KRR 大量 `(Not enough data)` | 窗口内历史不足（新工作负载，或 cAdvisor 采集刚启用），约 7 天后推荐值才有意义 |

## 相关文档

- [decisions/opencost-krr-data-sources.md](../decisions/opencost-krr-data-sources.md) — 数据源选型取舍
- [k8s-qos-resource-management.md](k8s-qos-resource-management.md) — QoS 类别与 CPU limit 档位约定
- [observability-multicluster.md](observability-multicluster.md) — 指标管道与 cluster 标签策略
- plans: [OpenCost](../plans/2026-07-30-opencost-multicluster.md) ·
  [KRR](../plans/2026-07-30-krr-rightsizing.md)
