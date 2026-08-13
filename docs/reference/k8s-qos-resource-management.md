# K8s 资源管理与 QoS 策略

> Last updated: 2026-08-13
> Status: 生效事实（本文只定**原则**，不存具体数值）

本文档记录 Homelab 中 CPU/Memory requests & limits 的设定**原则**。
**具体数值不在本文维护** —— 以 `k8s/helm/values/` 与集群实际为准
（`kubectl -n <ns> get deploy -o yaml`）。2026-07-06 那轮调整的推导过程见
[plans/archive/2026-07-06-resource-optimization.md](../plans/archive/2026-07-06-resource-optimization.md)（历史快照）。

> 延伸阅读：[K8s CPU 配置：QoS、Throttling 与驱逐策略](https://meirong.dev/posts/k8s-cpu-qos-resource-management/)

---

## 背景

Homelab 由两个集群组成：
- **homelab**（Proxmox K3s, 5600H, 12GB VM）— 有状态/数据面服务
- **oracle-k3s**（Oracle Cloud A1.Flex **2 OCPU / 12GB**，2026-08-05 由 4/24 缩容）— 公网无状态 + 告警面

日常用户约 1–2 人，偶发突发至 ~10 人。

### 目标

- **节省资源**：requests 反映常态负载，不过度预留
- **支撑突发**：limits 给足 burst 空间
- **防止饥饿**：补全所有缺失的 CPU limit，避免单 pod 独占 CPU

---

## QoS 类别

所有工作负载使用 **Burstable**（requests ≤ limits）：

| 类别 | 条件 | 驱逐优先级 |
|------|------|-----------|
| **Guaranteed** | requests == limits | 最后被驱逐 |
| **Burstable** | 设置了 requests 或 limits，但不完全相等 | 中等 |
| **BestEffort** | 均未设置 | 最先被驱逐 |

`Burstable` 兼顾稳态预留和空闲时 burst，适合单节点家用场景。

### ⚠️ QoS 只排到类，类内排序看 Pod Priority

上表决定的是**跨类**次序。两集群绝大多数运行 pod 都是 `Burstable`，所以真到节点内存
压力时，起决定作用的是 kubelet 的**类内**判据 —— 先看 **Pod Priority**，再看
「用量超出 request 的幅度」。

> **2026-08-10 补两条实测推论**，处理 KRR 报告时反复用到：
>
> 1. **BestEffort 的危害取决于 Pod Priority**。kubelet 先按「用量是否超 request」分桶
>    （BestEffort 的 request 恒为 0，**永远在"超"那一桶**），桶内下一个键才是 Priority。
>    所以带 `system-node-critical`(2000001000) / `system-cluster-critical`(2000000000)
>    的 Pod 即使是 BestEffort 也排在最后 —— oracle 的 cilium-agent/envoy/operator 属此类，
>    **刻意不补 requests**（补了会把该节点内存 requests 从 85% 推到 95%，收益却接近零）。
>    反过来，`priority: 0` 且无 class 的 BestEffort 才是真裸奔。
>
> 2. **BestEffort 会让 `priorityClassName` 完全失效**。2026-08-10 实测：external-dns 的
>    values 里写着 `priorityClassName: high`(900)，但它没有 resources → BestEffort →
>    落在"超 request"桶，而守规矩、用量在 request 之内的 `bulk`(-10) 应用落在另一桶，
>    结果 high 的先死。**声明了优先级就必须同时声明 resources，否则那行是装饰。**

四档（定义：`cloud/oracle/manifests/base/priorityclasses.yaml` 与 homelab 侧
`k8s/helm/manifests/namespace-guardrails/priorityclasses.yaml`，两边取值一致）：

> **2026-08-06 改名（已完成）**：`meirong-critical/high/bulk` → 无前缀的
> `critical`/`high`/`bulk`。三步走：加新 class → 改全部引用（33 处）→ 删旧 class。
>
> 分步是必须的：PriorityClass 与引用它的工作负载分属不同 ArgoCD App、**同步无先后
> 保证**；引用先于 class 生效时 API server 直接拒绝建 pod，而旧 pod 已被滚动删除 →
> 静默下线。当天 21:57 就这样让 homelab 的 opencost/trivy 下线 25 分钟。
>
> 收尾时有**三处不跟着 GitOps 滚**，各需单独处理（均已完成）：
>
> | 对象 | 为什么不滚 | 怎么切的 |
> |---|---|---|
> | `vault-0` + `vault-agent-injector` | Vault 是 manual-helm，**且 STS 是 `OnDelete`**——`helm upgrade` 只改 spec，pod 不动 | `just deploy-vault` 后**手动删 pod**；重启后 lifecycle hook 从 `vault-auto-unseal` 自动解封（实测 Sealed=false） |
> | ArgoCD 全家 ×5 | 刻意不自管自己 | `just deploy-argocd`（STS 是 RollingUpdate，自动滚完） |
> | `zitadel-pg-1` | Cluster spec 已改，但 **CNPG 不把 `priorityClassName` 变更当作需要滚动的理由** | 删 pod，operator 按当前 spec 重建 |
>
> ⚠️ **遗留影响**：改名前创建的 ReplicaSet 修订版本里仍写着 `meirong-*`
> （`revisionHistoryLimit` 保留的历史，desired 均为 0，实测 homelab 5 个 / oracle 25 个）。
> 对这些 Deployment 执行 `kubectl rollout undo` 回滚到那些修订会**建不出 pod**。
> 往前修，别回滚；这些旧 RS 也会随后续发布自然淘汰出保留窗口。
>
> ⚠️ 为什么必须分步：PriorityClass 与引用它的工作负载分属不同的 ArgoCD App，**同步无先后
> 保证**。引用先于 class 生效时 API server 直接拒绝建 pod，而旧 pod 已被滚动删除 →
> 静默下线。2026-08-06 21:57 就这样让 homelab 的 opencost/trivy 下线 25 分钟
> （当时是 homelab 侧漏了 `meirong-bulk` 定义），ArgoCD 全程显示 **Synced**、只有 health
> 是 Degraded。恢复后 ReplicaSet 的失败退避还会再拖几分钟，删掉卡住的 RS 可立即重置。

| 档 | 值 | 谁在里面 |
|---|---|---|
| `critical` | 1000 | Vault、ArgoCD 全家、zitadel-pg |
| `high` | 900 | external-dns、cloudflared、otel-collector（**两集群**）+ **Prometheus、Alertmanager**（2026-08-10 补，homelab 侧） |
| （默认） | 0 | 其余，含 **ZITADEL 应用本身**、**Grafana**、ESO、kube-state-metrics、node-exporter |
| `bulk` | -10 | 可牺牲的个人应用（calibre-web/bentopdf/karakeep/browserless/open-notebook/jobs-sg-web 等）+ **非关键观测/扫描组件**（opencost、trivy-operator，2026-08-06 补；**tetragon ×2、kyverno ×4**，2026-08-10 补） |

**Prometheus/Alertmanager 归 high、Grafana 留默认的理由**（2026-08-10）：前两者分别是
**指标源**与**告警投递**，掉了不只是丢图，是所有告警一起哑（dead-man's switch 也走同一条路）；
Grafana 只是 UI——真出事可以直接查 Prometheus，且它是 monitoring ns 里内存最大的一个。

**kyverno 全家归 bulk 的理由**（2026-08-10）：实测 webhook failurePolicy —— 唯一管
**工作负载准入**的 `kyverno-resource-validating-webhook-cfg` 是 **Ignore**，其余 `Fail` 的
只管 Kyverno 自己的 CR（policy/exception/cleanup）。所以它掉线**不会挡住 pod 创建**，
是真 fail-open，与 trivy-operator 同理。tetragon 同此判据。

**opencost / trivy-operator 归 bulk 的理由**（2026-08-06）：两者此前无 `priorityClassName`，
落在默认档 0 —— 比标了 `bulk`(-10) 的个人应用还高，与「谁该先被牺牲」的直觉相反。
opencost 是纯观测组件，掉线只丢一段成本采样；trivy-operator 掉线只是报告变旧，
不影响任何运行时管控 —— 后者与 CLAUDE.md「所有安全组件 fail-open + 控 CPU」的硬约束一致，
**被驱逐正是 fail-open**。

⚠️ trivy-operator 有 **三个**互不相干的键，层级各不相同，漏一个就留一个 priority 0 的缺口
（chart 0.33.1 逐键确认 + `helm template` 实证，2026-08-06）：

| 键 | 作用对象 | 渲染到哪 |
|---|---|---|
| 顶层 `priorityClassName` | operator 本体（常驻，内存小头） | Deployment |
| `trivyOperator.scanJobPodPriorityClassName` | **扫描 Job pod** —— 真正的瞬时内存消费者 | **ConfigMap** |
| `trivy.priorityClassName` | **trivy-server**（builtInTrivyServer 的 StatefulSet） | StatefulSet |

- 第二个渲染进 ConfigMap 的 `scanJob.podPriorityClassName`，**不在任何 Deployment 里**，
  `kubectl get deploy -o yaml` 看不到，别据此判断没生效 —— 看实际 Job pod 的 `.spec.priority`。
- 第三个最容易漏：只设前两个的话，一个**纯粹为 operator 服务**的组件反而比 operator 优先级高。
- ⚠️ `trivy:` 段在两份 values 里**都已存在**（装着 severity / ignoreUnfixed / accepted-risk 列表），
  必须插进现有段内。另起一个 `trivy:` 块 = YAML 重复键 = 后者静默覆盖前者，
  那批 CVE 抑制会无声消失。

⚠️ **三处设不了，不是漏配**：

- **ZITADEL 应用**：chart 9.34.1 没有 `priorityClassName` 这个 values 键（逐键确认过），
  写进 `valuesContent` 会被 Helm 静默忽略——看起来像配了，实际没有，比不配更危险。
  改用相对次序保证：`bulk`(-10) 把可牺牲的应用压到它下面。
- **timeslot**：本仓库之外的手工 Helm release（chart `timeslot-0.1.0`，无 ArgoCD
  tracking-id），只能靠 ns 的 LimitRange 给默认 request，动不了它的 pod spec。
- **sloth**（2026-08-10 补）：chart 0.16.0 里顶层与 `sloth.` 下**都不存在**
  `priorityClassName`（逐键确认 + `helm template --set` 双重实证），写进去被静默忽略。
  代偿同 ZITADEL：把可牺牲的应用压到 `bulk`(-10)，sloth 留在默认档 0 已在它们之上。

`bulk` 是 2026-08-05 oracle 缩容到 12GB 时加的——内存峰值从占 24GB 的 43%
变成占 12GB 的 ~70% 后，「谁先死」第一次成为真问题。

### 节点级预留：调度器看不见的那一块

kubelet 的 `allocatable` = `capacity` − `kube-reserved` − `system-reserved` −
`eviction-hard`。**不声明 reserved，调度器就认为整机内存都能分给 pod**，而
k3s-server 进程自己就要 ~2GiB（实测 RSS 2021Mi）+ containerd 240Mi。

oracle-k3s 在 2026-08-05 之前一条都没配（`capacity − allocatable` 的差额恰好等于
那 2GiB hugepages，是巧合不是预留），24GB 上没暴露问题，缩到 12GB 就是必然 OOM。
现值在 `cloud/oracle/ansible/playbooks/setup-k3s.yaml` 的 `kubelet-arg`。

> 另一类静默损耗：**OCI Ubuntu 镜像带的 microk8s 装机残留**
> `/etc/sysctl.d/20-microk8s-hugepages.conf` 把 2GiB 锁成 hugetlb 并直接从
> allocatable 扣掉，而集群里没有任何 pod 申请 hugepages。查法：
> `kubectl get node <n> -o jsonpath='{.status.capacity.hugepages-2Mi}'` 非 0
> 且 `grep HugePages_Free /proc/meminfo` == Total。

---

## CPU Limit 档位

| 类型 | CPU Limit | 代表服务 |
|------|-----------|---------|
| 入口流量（cloudflared × 2 副本）| `200m` | cloudflared（2026-07-06 下调） |
| 用户 Web 服务 | `500m–1000m` | calibre-web、karakeep |
| 数据库 | `500m` | postgres |
| 可观测性 | `300m–500m` | Loki, Tempo, Prometheus, Grafana |
| 后台/轻量服务 | `100m–200m` | alertmanager, kube-state-metrics, oauth2-proxy |
| 极轻量 sidecar | `10–100m` | log-exporter, permission-fixer |
| Batch/CronJob | `200m–300m` | restic-backup, kube-bench |
| 元数据处理 | `1000m` | calibre-metadata（每日凌晨） |

---

## 管理方式

| 方式 | 范围 | 同步策略 |
|------|------|---------|
| **ArgoCD**（raw YAML）| `k8s/helm/manifests/` 下的个人服务 | auto-sync / 120s reconciliation |
| **ArgoCD**（Helm chart）| 安全/可观测组件（kyverno、tetragon、trivy、falco、**loki、tempo、sloth**、**kube-prometheus-stack**、**external-dns**×2） | auto-sync / 120s reconciliation |
| **just deploy-X**（Helm）| 基础设施层（vault、cilium、external-secrets、ArgoCD 自身）| 手动触发（bootstrapping/恢复场景） |

> **2026-08-10 修正**：kube-prometheus-stack 早已迁入 ArgoCD（`argocd/applications/kube-prometheus-stack.yaml`，
> 多源 chart+values），本表却仍把它列在「手动 helm」那行。判据别看 `helm list`——ArgoCD 接管前
> 装过的 release 会一直留在那里；看**对象上的 tracking-id**：
> `kubectl -n <ns> get deploy <name> -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}'`
> 非空即 ArgoCD 管（改 values 后 `git push` 即可，别手动 `helm upgrade`）。

loki、tempo、sloth、restic-backup 已从 Helm/kubectl 管理迁入 ArgoCD（2026-07-06）。

---

## 验证 QoS

```bash
# 查看某 pod 的 QoS
kubectl get pod <pod-name> -n <namespace> -o jsonpath='{.status.qosClass}'

# 批量查看所有 pod
kubectl get pods -A -o custom-columns=\
'NAMESPACE:.metadata.namespace,NAME:.metadata.name,QOS:.status.qosClass'
```

## 检测 CPU Throttling

```bash
# CFS 配额统计
cat /sys/fs/cgroup/cpu,cpuacct/kubepods/burstable/<cgroup-id>/cpu.stat
# PromQL
rate(container_cpu_cfs_throttled_seconds_total[5m])
  / rate(container_cpu_cfs_periods_total[5m])
```

## 检测 OOMKill（容器顶爆自身 limit）

单节点上更常咬人的**不是**节点驱逐，而是单个容器撞到自己的 memory limit 被内核杀掉
（`exitCode 137`）。它**不影响邻居**，也因此很容易长期没人发现。

```bash
# 谁最近被 OOM 杀过（--context 换 oracle-k3s 查另一集群）
kubectl --context k3s-homelab get pods -A -o json | jq -r '
  .items[] | .metadata as $m | .status.containerStatuses[]? |
  select(.lastState.terminated.reason=="OOMKilled") |
  "\($m.namespace)/\($m.name) [\(.name)] restarts=\(.restartCount) at \(.lastState.terminated.finishedAt)"'

# 逼近 limit 的容器（>80% 就该抬 limit 或查泄漏）—— 双集群一起出
# ⚠️ 两侧都必须先 max by(...) 聚合掉 id/image/job 等多余标签，否则
#    直接除会报 "many-to-one matching must be explicit"；分组键要带 cluster，
#    否则两集群同名 ns/pod 会串味
max by (cluster,namespace,pod,container) (max_over_time(container_memory_working_set_bytes{container!=""}[2d]))
  / on (cluster,namespace,pod,container)
max by (cluster,namespace,pod,container) (kube_pod_container_resource_limits{resource="memory"})
```

`max_over_time` 是关键——尖峰型负载看瞬时值会整个漏掉（`argocd-application-controller`
被杀时的瞬时读数只有 0.67G，2d 窗口才照出 94%）。

⚠️ **`KubePodCrashLooping` 抓不到这类事件** —— 容器 OOM 后干净重启，从不进
`CrashLoopBackOff`。

> **2026-08-10 更新**（本段原先说「集群没有任何规则引用 OOMKilled，补告警是 ROADMAP #4」，
> 两处都已过期）：`ContainerOOMKilled` 早在 2026-08-02 就补上了
> （`manifests/monitoring/alerts/prometheus-rules.yaml`），ROADMAP #4 现在指的是
> prometheus-operator CRD 补升，与 OOM 无关。同日新增两条补齐剩下的缺口：
>
> | 规则 | 时机 | 覆盖 |
> |---|---|---|
> | `ContainerOOMKilled` | 事后 | 双集群（kube-state-metrics） |
> | `ContainerOOMKilledCadvisor` | 事后 | **仅 homelab**（kubelet 内嵌 cAdvisor 的 OOM 计数器；oracle 侧该指标未被采集），用来交叉验证上一条的标签值拼写 |
> | `ContainerMemoryNearLimit` | **事前**（7d 峰值 >85% limit） | 双集群 |
>
> ⚠️ `ContainerOOMKilled` 的 `reason="OOMKilled"` **至今未经实测证实** —— 30d 窗口内
> 两集群只出现过 `Unknown`/`Error`/`Completed`，没有任何 OOMKilled 样本。第一次真实
> OOM 时务必确认它真的响了；没响就查 `count by (cluster,reason) (kube_pod_container_status_last_terminated_reason == 1)`。
>
> ⚠️ **没有独立部署 cAdvisor**——`container_*` 指标全部来自 **kubelet 内嵌 cAdvisor**：
> homelab 经 kube-prometheus-stack 全量入库；oracle 的 otel-collector
> `prometheus/cadvisor` receiver 的 keep 正则只保留 `container_(cpu_usage_seconds_total|
> memory_working_set_bytes)`（为 KRR）。所以 `container_oom_events_total`（homelab 116 条 /
> oracle 0 条）与 `container_cpu_cfs_throttled_*`（homelab 41 条 / oracle 0 条）
> 在 oracle 侧**不进入中枢 Prometheus**，查询返回**空结果**，与「值为 0」外观完全一致 ——
> 2026-08-10 就据此误下过「oracle 无 CPU 节流」的结论。在 oracle 上判断 CPU 是否吃紧，
> 只能看 limit 与 p95 的比值 + 应用日志时序。

> **2026-08-11 更新**：`ContainerMemoryNearLimit` 的口径从「每个 pod 的峰值 ÷ **该 pod 自己的**
> limit」改成「每个 pod 的峰值 ÷ 该工作负载 **当前**的 limit」（分母降到
> `(cluster,namespace,container)` 取 max，`group_left` 多对一）。
>
> 起因：CronJob 每晚换新 pod，改 limit 只影响新 pod，**旧 pod 的 spec 不可变**，
> 老 limit 会继续参与计算直到 `successfulJobsHistoryLimit` 把它挤掉。backup 的 768Mi
> 08-10 已生效（新 pod 峰值 148Mi = 19%），告警却仍按 08-09 那个 512Mi 的残留 pod
> 报 90.03%。**每次给 CronJob 抬 limit 都会复现 2~3 晚假阳性**，不是偶然。
>
> ⚠️ 反向代价：limit **调小**时会对着旧的大 limit 比，短暂漏报（Deployment 滚完即恢复，
> CronJob 最多 3 晚）。抬 limit 远比压 limit 常见，认这个取舍；**别为了修漏报改回按 pod
> join**，那样 CronJob 假阳性立刻回来。

**判读**：先看 7d 曲线形状再动手 —— 稳定爬升是泄漏（该查代码），
在基线上下震荡+偶发尖峰是**头寸不够**（该抬 limit）。
2026-08-02 的 `argocd-application-controller` 属后者：基线 0.54–0.68G、尖峰 0.85G+、limit 1Gi
（[ROADMAP #3](../ROADMAP.md)）。控制面组件的峰值随**被管对象规模**增长（App 数、CRD 大小），
不随流量——扩容后要回头复查这类 limit。

---

## requests/limits 该填多少？

不靠拍脑袋 —— **KRR 每周一出推荐报告**推到 Telegram（CPU 取 p95，内存取窗口内 max + 15%）。
双集群均已部署，见 [cost-and-rightsizing.md](cost-and-rightsizing.md#krr)。

采纳流程：KRR **只读不改**（`krr-enforcer` 刻意未部署，会与 ArgoCD selfHeal 死循环），
看完报告手工改 git 里的 `resources`。

**完整分诊 SOP → [runbooks/krr-report-triage.md](../runbooks/krr-report-triage.md)**：
五类分诊（忽略 / BestEffort / 逼近 limit / CPU 回收 / 不采纳）、两类系统性误读
（100Mi–10m 地板值、oracle 空结果冒充零值）、报告照不出但会间接暴露的三种
「配置在 git 里却从未生效」，以及改完怎么实测确认。

两个读数注意事项：

- 标 `(No data)` / `(Not enough data)` 的是当前没有运行 Pod 的 Job/CronJob，忽略即可
- 内存推荐取 **7 天**窗口内的 max（对齐 Prometheus retention），跨周尖峰
  （如每周备份 CronJob）可能落在窗口外，这类工作负载要自行留余量

⚠️ **内存余量别看 `kubectl top node`**：它报的是 workingSet（含可回收页缓存），会虚高到 90%+
让人误判要驱逐。判余量看节点 `free -m` 的 **available**（或 Prometheus 按容器 `rssBytes`
聚合）——2026-08-06 实测 top 报 92% 时 available 还有 4.3GB / 11.9GB、requests 仅 69%，
离驱逐阈值很远。

---

## 相关文档

- [cost-and-rightsizing.md](cost-and-rightsizing.md) — OpenCost 成本归因 + KRR 右尺寸
- [runbooks/oracle-k3s-shape-downsize.md](../runbooks/oracle-k3s-shape-downsize.md) — 改 A1 shape 的 SOP（本文那套原则的一次实战应用）
- [plans/archive/2026-07-06-resource-optimization.md](../plans/archive/2026-07-06-resource-optimization.md) — 2026-07-06 那轮调整的推导（历史快照，非当前值）
- [observability-multicluster.md](observability-multicluster.md) — 多集群监控架构
- [Kubernetes QoS 官方文档](https://kubernetes.io/docs/tasks/configure-pod-container/quality-service-pod/)
