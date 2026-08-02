# K8s 资源管理与 QoS 策略

> Last updated: 2026-08-02
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
- **oracle-k3s**（Oracle Cloud A1.Flex 4 OCPU / 24GB）— 公网无状态 + 告警面

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

### ⚠️ QoS 只排到类，类内排序看 Pod Priority（当前全缺）

上表决定的是**跨类**次序。homelab 39/47 个运行 pod 全是 `Burstable`，所以真到节点内存
压力时，起决定作用的是 kubelet 的**类内**判据 —— 先看 **Pod Priority**，再看
「用量超出 request 的幅度」。

**现状（2026-08-02 核实）**：全 repo `priorityClassName` **零命中**，53 个 pod 全在
priority 0；集群里只有 k3s 自带的 `system-cluster-critical` / `system-node-critical`
（4+3 个系统 pod）。等价于：**Vault、ArgoCD、Prometheus 与 calibre-web 同级**，
谁超 request 超得多谁先被驱逐。

这是**加固项而非救火**：7d 最低 `MemAvailable` 3.31G / 12.66G，离节点驱逐还远
（真正咬人的是**容器自身 limit** 被顶爆，见下）。开放项见 [ROADMAP #12](../ROADMAP.md)。

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
- [plans/architecture/2026-07-06-resource-optimization.md](../plans/architecture/2026-07-06-resource-optimization.md) — 2026-07-06 那轮调整的推导（历史快照，非当前值）
- [observability-multicluster.md](observability-multicluster.md) — 多集群监控架构
- [Kubernetes QoS 官方文档](https://kubernetes.io/docs/tasks/configure-pod-container/quality-service-pod/)
