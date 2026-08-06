# K8s 资源管理与 QoS 策略

> Last updated: 2026-08-05
> Status: 生效事实（本文只定**原则**，不存具体数值）

本文档记录 Homelab 中 CPU/Memory requests & limits 的设定**原则**。
**具体数值不在本文维护** —— 以 `k8s/helm/values/` 与集群实际为准
（`kubectl -n <ns> get deploy -o yaml`）。2026-07-06 那轮调整的推导过程见
[plans/architecture/2026-07-06-resource-optimization.md](../plans/architecture/2026-07-06-resource-optimization.md)（历史快照）。

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
| `high` | 900 | external-dns、cloudflared、otel-collector(oracle) |
| （默认） | 0 | 其余，含 **ZITADEL 应用本身** |
| `bulk` | -10 | 可牺牲的个人应用（calibre-web/stirling-pdf/karakeep/browserless 等）+ **非关键观测/扫描组件**（opencost、trivy-operator，2026-08-06 补） |

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

⚠️ **两处设不了，不是漏配**：

- **ZITADEL 应用**：chart 9.34.1 没有 `priorityClassName` 这个 values 键（逐键确认过），
  写进 `valuesContent` 会被 Helm 静默忽略——看起来像配了，实际没有，比不配更危险。
  改用相对次序保证：`bulk`(-10) 把可牺牲的应用压到它下面。
- **timeslot**：本仓库之外的手工 Helm release（chart `timeslot-0.1.0`，无 ArgoCD
  tracking-id），只能靠 ns 的 LimitRange 给默认 request，动不了它的 pod spec。

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
| 用户 Web 服务 | `500m–1000m` | calibre-web、bifrost、karakeep |
| 数据库 | `500m` | postgres |
| 可观测性 | `300m–500m` | Loki, Tempo, Prometheus, Grafana |
| 后台/轻量服务 | `100m–200m` | alertmanager, kube-state-metrics, oauth2-proxy |
| 极轻量 sidecar | `10–100m` | log-exporter, permission-fixer, argocd-image-updater |
| Batch/CronJob | `200m–300m` | restic-backup, kube-bench |
| 元数据处理 | `1000m` | calibre-metadata（每日凌晨） |

---

## 管理方式

| 方式 | 范围 | 同步策略 |
|------|------|---------|
| **ArgoCD**（raw YAML）| `k8s/helm/manifests/` 下的个人服务 | auto-sync / 120s reconciliation |
| **ArgoCD**（Helm chart）| 安全/可观测组件（kyverno、tetragon、trivy、falco、**loki、tempo、sloth**） | auto-sync / 120s reconciliation |
| **just deploy-X**（Helm）| 基础设施层（kube-prometheus-stack、vault、cilium、external-secrets）| 手动触发（bootstrapping/恢复场景） |

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
`CrashLoopBackOff`。集群当前也**没有任何规则**引用
`kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}`
（2026-08-02 核实，repo 与 live rules 皆零）。补告警是 [ROADMAP #4](../ROADMAP.md)。

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

两个读数注意事项：

- 标 `(No data)` / `(Not enough data)` 的是当前没有运行 Pod 的 Job/CronJob，忽略即可
- 内存推荐取 **7 天**窗口内的 max（对齐 Prometheus retention），跨周尖峰
  （如每周备份 CronJob）可能落在窗口外，这类工作负载要自行留余量

---

## 相关文档

- [cost-and-rightsizing.md](cost-and-rightsizing.md) — OpenCost 成本归因 + KRR 右尺寸
- [runbooks/oracle-k3s-shape-downsize.md](../runbooks/oracle-k3s-shape-downsize.md) — 改 A1 shape 的 SOP（本文那套原则的一次实战应用）
- [plans/architecture/2026-07-06-resource-optimization.md](../plans/architecture/2026-07-06-resource-optimization.md) — 2026-07-06 那轮调整的推导（历史快照，非当前值）
- [observability-multicluster.md](observability-multicluster.md) — 多集群监控架构
- [Kubernetes QoS 官方文档](https://kubernetes.io/docs/tasks/configure-pod-container/quality-service-pod/)
