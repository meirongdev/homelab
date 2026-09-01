# OTel 2026 对齐：homelab collector 首次落地 + oracle collector 现代化

> 日期: 2026-07-31
> 状态: ✅ 已实施

## 上下文

仓库的 OTel 现状（2026-07-31 盘点）：

- **homelab 没有 collector**：`values/opentelemetry-collector.yaml`（2026-03）从未随任何
  helm release 生效过（实测：无 release、无 pod、Loki 里只有 `cluster="oracle-k3s"`）。
  （曾据"旧 values 写了 `otlp_http`"推断配置本身跑不通。**该推断撤回**：0.156 起组件
  规范名恰好迁到了下划线风格，`otlp_http` 成了新规范名、`otlphttp` 转为弃用别名，
  旧名在当年版本是否有效已不可考，也无关紧要。"从未部署"的铁证是集群状态，不是组件名。）
- **oracle 有一份能跑的裸 DaemonSet**（contrib 0.120.0，kustomize 管理），承载 oracle 全部
  日志/指标/追踪跨 Tailscale 推到 homelab；配置质量不错，但按 2026 标准有四个实质差距（见下）。

用户要求按 2026 OTel 最佳实践对齐。原则：**采纳能改变故障行为或删除代码的实践，
拒绝只是"名字更标准"的破坏性改动**。

## 采纳的实践

| 实践 | 落点 | 改变了什么 |
|---|---|---|
| `container` operator | 双侧 filelog | 取代 oracle ~60 行手写 router/regex/move 链；**修复 CRI 分段长行不重组的真 bug**（>16KB 日志此前被拆成多条）；自动识别 docker/containerd/CRI |
| `file_storage` checkpoint | 双侧 filelog | 此前 oracle `start_at: end` 且无 checkpoint：**每次重启丢掉停机窗口的全部日志**；现在断点续读 |
| 持久化发送队列 | oracle `otlphttp`/`otlp/tempo` | 跨 Tailscale 出口，collector 重启或断链时缓冲不丢，恢复续传（bbolt 落 `/var/lib/otelcol` hostPath） |
| `otel/opentelemetry-collector-k8s` 发行版 | homelab | k8s 场景官方裁剪版，组件面比 contrib 小一个量级（更小攻击面/镜像）。oracle 必须留 contrib：`prometheusremotewrite` exporter 不在裁剪版里 |
| Helm chart + presets | homelab | `logsCollection`（container operator + `storeCheckpoints`）与 `kubernetesAttributes` preset 生成 RBAC/挂载/接线，不再手写 |
| `k8s.cluster.name` semconv | 双侧 resource processor | 与运营标签 `cluster` **并存**（见"拒绝"表第 2 行） |
| 双侧同版本 0.156.0 | 双侧 | oracle 0.120.0 → 0.156.0（落后 36 个版本）；升级纪律：两侧同 appVersion 一起动 |
| collector 自身遥测 | homelab ServiceMonitor | queue 深度/丢弃计数/export 失败率进 Prometheus（管道自己的健康信号） |
| 组件命名 | 双侧 | 0.156 的规范名已迁往下划线风格（`otlp_http`/`k8s_attributes`/`file_log`/`prometheus_remote_write`），旧名成弃用别名（启动仅 warn）。**双侧暂留别名**：homelab chart preset 生成的就是别名，只迁手写侧会造成两集群风格分裂：待 chart 跟进后一起切 |

（曾计划新增 `OracleTelemetryPipelineDown` 断流告警，复核发现 `prometheus-rules.yaml` 的
`OracleTelemetryAbsent`（critical，`absent(up{cluster="oracle-k3s"})`，for 15m）早已覆盖
同一故障面。重复规则已撤销，此缺口本就是关着的。）

部署形态：homelab = ArgoCD `otel-collector` App（多源 chart 0.165.0 + `$values`，全新部署
故 `fullnameOverride` 合法。与采纳现存 release 的场景区分，见
`manual-helm-to-argocd-adoption.md` 决策三）；oracle = 维持 kustomize 树内的裸 DaemonSet
（它承载 8 条 metrics 抓取管道喂 KRR/OpenCost/SLO，重写进 chart values 风险大于收益）。

## 拒绝的实践（及理由）

| 实践 | 为什么不做 |
|---|---|
| OTel Operator + `OpenTelemetryCollector` CR | 单节点 homelab 用 operator 管一个 DaemonSet 是纯增熵；auto-instrumentation 注入目前无需求 |
| `cluster` 标签改名 `k8s_cluster_name` | 全部 dashboard/PrometheusRule/SLO/KRR 查询都写着 `cluster=`：为名字标准化打断整个查询面不值。折中：semconv 属性**加**上、运营标签**不动** |
| Prometheus 原生 OTLP 摄入（替代 PRW） | PRW 工作正常；oracle→homelab 是推模式刚需，换协议零收益。`otlp-write-receiver` feature flag 留着（kps values 已开，别人可用） |
| PRW exporter 加 WAL | 上游仍标 experimental 且有已知数据丢失 issue；指标断点在下个抓取周期自愈，容忍度远高于日志/追踪 |
| homelab metrics 管道 | kube-prometheus-stack 原生抓取（ServiceMonitor + additionalScrapeConfigs，含 cloudflared）是正确工具；collector 重复采集只会双份序列 |
| spanmetrics / servicegraph connector | Tempo metrics-generator 领域，当前无消费方 |

## 验证方法（部署前）

1. `helm template` 渲染审查（管道/挂载/RBAC/镜像/命令名）；
2. **用 0.156.0 真实二进制 `validate` 双侧最终配置**（docker 跑 contrib 与 k8s 两个镜像，
   模拟 pod 环境：SA token / `K8S_NODE_NAME` / `/var/lib/otelcol`）：两份配置均 VALID。
   这是能做的最强预检：连"组件名不存在"这类旧 values 的死因都能拦住。

## 后果与注意

- homelab 容器日志 2026-07-31 起首次进 Loki；查询用 OTel 风格标签
  （`k8s_namespace_name` 等，不是 Prometheus 风格 `namespace`）。
- oracle collector 换镜像 + 换 ConfigMap 会重启一次 pod：`start_at: end` 下这次重启
  仍会跳过窗口内日志（checkpoint 从本次才开始生效），属一次性代价。
- 双侧 collector 以 root 运行（读 `/var/log/pods` + 写 hostPath state 的节点代理惯例，
  monitoring ns 本就是 PSA privileged）。
- 升级纪律：chart pin（App）与 oracle contrib 镜像 tag 同 appVersion 一起升；
  justfile 的 `otel_collector_version` 只服务 LEGACY 逃生配方。
- homelab 新增负载实测预算：requests 50m/128Mi、limits 200m/256Mi、
  memory_limiter 160MiB；Loki `retention_period: 168h` 已有界，节点盘余 ~46 GiB。
