# KRR 双集群资源右尺寸周报

**日期：** 2026-07-30
**状态：** ✅ 已部署（2026-07-30 双集群冒烟通过；oracle 推荐值需等约 7 天历史）
**范围：** homelab + oracle-k3s，`robustadev/krr:v1.29.0`
**结论：** 每集群一个 CronJob（周一 09:00 / 09:15），结果以文本附件推 Telegram；
顺带给 oracle 补上 cAdvisor 采集（keep 正则只留 KRR 需要的 2 个指标）。

## 背景 / 问题

KRR 用 Prometheus 里的历史用量推荐 requests/limits。落到本环境有三件事要先厘清。

### 1. KRR 是 CLI，不是常驻服务

它只输出 table/json/yaml/csv/html，**不导出 Prometheus 指标** —— 所以不像 OpenCost
那样能做 Grafana 面板，报告本身就是产物。因此选型为「定期 Job + 推送报告」而非常驻组件。

### 2. oracle 侧没有 cAdvisor，KRR 是瞎的

KRR 只查两个指标（`robusta_krr/core/integrations/prometheus/metrics/{cpu,memory}.py`）：

```promql
max(rate(container_cpu_usage_seconds_total{namespace=…,pod=~…,container=…}[step])) by (container, pod, job)
max(container_memory_working_set_bytes{namespace=…,pod=~…,container=…})        by (container, pod, job)
```

中枢 Prometheus 实测（2026-07-30）：

| 指标 | homelab | oracle-k3s |
|---|---|---|
| `container_cpu_usage_seconds_total` | 144 | **0** |
| `container_memory_working_set_bytes` | 144 | **0** |
| KSM 系列（requests/limits/pod_owner/replicaset_owner） | ✅ | ✅ |

缺前两个时 KRR 官方行为是「仍能运行，但只考虑当前运行的 Pod」——没有历史，推荐值无意义。
这与 OpenCost 当初绕开的是同一个缺口（见 `2026-07-30-opencost-multicluster.md`），
但 OpenCost 能改用 collector 数据源规避，KRR 不能——它只认 Prometheus。

### 3. retention 7d vs KRR 默认 14d

KRR `simple` 策略默认取 **336h**，而 homelab Prometheus retention 是 **7d**。
不传参数它不报错，只会静默用不足的数据（内存推荐是「窗口内 max + 15%」，窗口短会低估周级尖峰）。

## 方案

### oracle cAdvisor 补齐 —— keep 正则丢 97%

给 oracle otel-collector 加 `prometheus/cadvisor` receiver，直连 kubelet
`https://10.0.0.26:10250/metrics/cadvisor`。实测该端点共 **9223** 条 series，
KRR 只需其中 **280** 条，keep 正则丢掉 97%，跨 Tailscale 增量可忽略
——做法与既有的 `prometheus/cilium-envoy` job 一致。

额外再 drop 掉 `container=""` 的 Pod 级汇总序列：KRR 的查询永远带真实 container 名
（见上面 PromQL），这批用不到。

**RBAC 必须加 `nodes/metrics`。** kubelet 自己做 SubjectAccessReview，走 `metrics`
子资源，只给 `nodes` 不够。

> ⚠️ `kubectl auth can-i get nodes/metrics --as=<sa>` 在这里会**误报 yes**。
> 实测（用该 SA 起 Pod 直连 kubelet）返回 **HTTP 403**。以实际请求为准，别信 can-i。

### KRR CronJob —— 每集群一个

KRR 需要同时访问 Prometheus（历史用量）**和** K8s API（枚举工作负载与当前 requests）。
K8s API 只能看本集群，所以每集群各跑一个，与 falco / opencost 的双集群模式一致。

| | homelab | oracle-k3s |
|---|---|---|
| Prometheus | 集群内 `kube-prometheus-stack-prometheus:9090` | 中枢，经 Tailscale `100.94.186.7:31090`（实测 HTTP 200） |
| `-l` | `homelab` | `oracle-k3s` |
| 时间 | 周一 09:00 | 周一 09:15（错峰） |
| bot token | 复用 `monitoring/alertmanager-telegram` | 自建 ExternalSecret（跨集群读同一 Vault 路径，同 falcosidekick） |

Pod 结构：`initContainers: [krr]` → `containers: [notify]`。
用 initContainer 而不是两个 container，是因为同 Pod 的 containers 并行启动、不能当流水线用。
notify 走 Telegram `sendDocument`，把表格作为 `.txt` 附件发到「🚨 Homelab 告警」话题
（thread 2，与 Alertmanager 同一目的地）。

**参数易错点**：`--prometheus-label` 是标签**键**（`cluster`），`-l` /
`--prometheus-cluster-label` 是标签**值**（`homelab`）。两者容易搞反。
`--cluster` / `-c` 是 kubeconfig context，在集群内跑时用不上。

`--history-duration=168` 显式对齐 7d retention。retention 提上去后同步改回 336。

## 落地清单

| 文件 | 动作 |
|---|---|
| `cloud/oracle/manifests/monitoring/otel-collector.yaml` | ClusterRole 加 `nodes/metrics`；加 `prometheus/cadvisor` receiver + `metrics/cadvisor` pipeline |
| `cloud/oracle/manifests/monitoring/krr.yaml` | 新增：ExternalSecret + SA/CR/CRB + CronJob |
| `cloud/oracle/manifests/kustomization.yaml` | 加 `- monitoring/krr.yaml` |
| `k8s/helm/manifests/krr.yaml` | 新增：SA/CR/CRB + CronJob |
| `argocd/applications/monitoring-dashboards.yaml` | `directory.include` 追加 `krr.yaml` |

## 部署与验证

| # | 步骤 | 验证点 |
|---|------|--------|
| 1 | push → ArgoCD 同步 | 两个 CronJob 出现，oracle ExternalSecret Ready |
| 2 | **`kubectl rollout restart daemonset/otel-collector -n monitoring`**（oracle） | 见下 ⚠️ |
| 3 | 确认 cAdvisor 指标到位 | `count by (cluster) (container_cpu_usage_seconds_total)` 出现 `oracle-k3s` |
| 4 | 各跑一次一次性 Job 冒烟 | KRR 正常退出、`/out/krr.txt` 非空 |
| 5 | 端到端（会真发 Telegram） | 群里收到两份附件 |

> ⚠️ **步骤 2 不能省。** otel-collector 的 DaemonSet pod template 没有 config checksum
> 注解，改 ConfigMap 不会触发重启，而 ArgoCD 全程显示 Synced/Healthy —— 静默失败。
> 上一个方案（OpenCost）已经踩过一次。

**oracle 的推荐值要等约 7 天才有意义** —— cAdvisor 从步骤 2 起才开始积累历史。
在那之前 KRR 能跑通、但样本不足，别照着改 requests。

## 部署实测（2026-07-30）

| 验证 | 结果 |
|---|---|
| oracle cAdvisor 入库 | ✅ `container_cpu_usage_seconds_total{cluster="oracle-k3s"}` 51 条（homelab 144 条）；`container=""` 汇总已丢弃 0 条 |
| homelab KRR 冒烟 | ✅ 53 个工作负载出推荐，`using 4 metrics` |
| oracle KRR 冒烟 | ✅ 经 Tailscale 连中枢成功，44 个工作负载 |

### 部署时踩到的两件事

1. **`-l=homelab` 会被解析成值 `=homelab`。** 短选项不支持 `=` 语法，KRR 直接
   `CRITICAL Label =homelab does not exist` 退出。必须拆成两个 args 项（`- -l` / `- homelab`）。
   长选项（`--prometheus-label=cluster`）用 `=` 没问题。
   —— 冒烟测试抓到的；纯 YAML/schema 校验发现不了。
2. **`--width=180` 会把列截断**成 `personal…` / `kyverno-…`。输出是附件不是终端，
   放宽到 300 后正常。

## 风险与注意事项

- **只读，不自动改。** KRR 的 ClusterRole 全是 get/list/watch，`krr-enforcer` 未部署。
  刻意不上 enforcer：它会主动 patch 工作负载的 requests/limits，与 ArgoCD 的
  `selfHeal: true` 直接冲突（enforcer patch → ArgoCD 判 OutOfSync → 改回 git 值 →
  enforcer 再 patch，无限循环）。要采纳推荐就手工改 git。
- **Job 失败不会推 Telegram**（notify 在 initContainer 之后）。失败可见性依赖
  kube-prometheus-stack 内置的 `KubeJobFailed` 告警规则。
- **Kyverno 策略全是 Audit 模式**，`docker.io/*` 在 `restrict-image-registries` 白名单内，
  不阻断。但 `require-probes` 会给 Job Pod 记一条 audit 违规（Job 本就不该有探针），
  属预期噪音。
- **镜像必须锁版本**：`robustadev/krr:v1.29.0` 提供 linux/arm64（oracle 是 Ampere A1），
  但 `:latest` 是单架构 manifest，在 oracle 上会拉不动。
- **7d 窗口的固有局限**：内存推荐取窗口内 max，跨周的尖峰（如每周备份 CronJob）可能落在
  窗口外而被低估。真要准就把 Prometheus retention 提到 14d 并把参数改回 336。

## 参考

- [robusta-dev/krr](https://github.com/robusta-dev/krr)
- [KRR in-cluster job 官方范例](https://github.com/robusta-dev/krr/blob/main/docs/krr-in-cluster/krr-in-cluster-job.yaml)
- 关联方案：[2026-07-30-opencost-multicluster.md](2026-07-30-opencost-multicluster.md)
