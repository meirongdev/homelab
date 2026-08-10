# KRR 报告分诊与采纳

> Last updated: 2026-08-10
> Status: 生效 SOP
> 触发条件：周一收到 KRR 推送到 Telegram 的两份报告（homelab 09:00 / oracle-k3s 09:15）；
> 或改 shape、加服务、扩容之后主动跑一次核对。
> 成功判定：报告里每一行都被归入下面五类之一并有处置结论（含「刻意不动」）；
> 改动落地后**在集群里实测确认生效**（见 §5），不是「push 了就算」。
> 回滚：所有改动都是 `resources` 字段。回滚 = `git revert` 后按 §4 的归属重新下发；
> 抬 limit 的改动可原地保留（抬高不会致害），降 request 的若引发 Pending 需立即回滚。

KRR 部署拓扑、依赖指标、命令行参数见
[reference/cost-and-rightsizing.md § KRR](../reference/cost-and-rightsizing.md#krr)。
本文只讲**拿到报告之后做什么**。

---

## 0. 先破除一个误读

报告末尾那个 `NN points - D` 是 KRR 按「你的配置离我的推荐有多远」算的分，
**不等于"浪费严重"**。2026-08-10 那轮两份报告都是 D，但实测：

- homelab 节点 CPU requests 只占 20%、内存 39% —— 没有任何可省的必要
- 真正值钱的信息藏在最不起眼的 `unset -> 10m` 行里（那是 BestEffort，见 §2 分类 B）

**分数低不代表要减配，分数高也不代表安全。** 报告的价值在分类，不在总分。

同理，`MEMORY DIFF` 那列的 `+XXX Mi` 很容易被读成"要多给内存"，
但它常常是在说**这个容器已经贴着自己的 limit 了**（见分类 C）。

---

## 1. 三条读数前提

| 前提 | 数值 | 后果 |
|---|---|---|
| CPU 推荐 = **p95** | — | 对批处理 CronJob 无意义（见分类 E） |
| 内存推荐 = 窗口内 **max + 15%** | — | 可反推峰值：`峰值 ≈ 推荐值 ÷ 1.15` |
| **内存有 100Mi 地板、CPU 有 10m 地板** | 100Mi / 10m | 任何恰好等于地板的推荐**都不是测量结果** |

地板值这条最容易骗人。2026-08-10 实测对照：

| 容器 | KRR 推荐 | 实测 7d 峰值 | 虚高 |
|---|---|---|---|
| kube-state-metrics | 100Mi | 52Mi | ~2× |
| node-exporter | 100Mi | 29Mi | ~3× |
| external-dns(homelab) | 100Mi | 82Mi | 轻微 |

**凡是推荐值等于 100Mi / 10m 的行，按实测值填，别抄报告。** 查实测：

```bash
# 在仓库根目录；Prometheus 在 homelab，两集群数据都在里面
kubectl --context k3s-homelab -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090 &
# 7d 内存峰值（改 cluster 标签切集群）
curl -s --data-urlencode 'query=max by (namespace,container) (max_over_time(container_memory_working_set_bytes{cluster="oracle-k3s",container!=""}[7d]))' \
  http://localhost:19090/api/v1/query | jq -r '.data.result[] | "\((.value[1]|tonumber/1048576)|floor)Mi \(.metric.namespace)/\(.metric.container)"' | sort -rn | head -20
```

---

## 2. 五类分诊

拿到报告后**逐行**归入下面五类。每类的处置方式不同。

### A. `(No data)` / `(Not enough data)` — 直接忽略

当前没有运行 Pod 的 Job/CronJob。2026-08-10 两份报告里合计 21 行属于此类。
不是问题，不要为它们改任何东西。

### B. `unset -> 10m` / `unset -> 100Mi` — **最高优先级**

这不是"少配了一点"，是**该容器完全没有 resources → Pod 是 BestEffort**。

为什么最要紧：kubelet 驱逐先按「用量是否超 request」分桶、再按 Pod Priority 排序。
BestEffort 的 request 恒为 0，**永远落在"超"那一桶**，于是排在守规矩的 `bulk`(-10)
应用**前面**被驱逐 —— 与 [k8s-qos-resource-management.md](../reference/k8s-qos-resource-management.md)
的分档意图正好相反。2026-08-10 最刺眼的例子：external-dns 的 values 里写着
`priorityClassName: high`(900)，却是 BestEffort，那行 priority 根本轮不到生效。

处置：按 §1 查实测值 → 补 `resources` → 按 §4 下发 → 按 §5 验证。

⚠️ **一个重要例外：先看 Pod Priority，再决定值不值得补。**
「BestEffort 排第一档」说的是**同一驱逐桶内**的事——kubelet 先按「用量是否超 request」
分桶，桶内**下一个排序键就是 Pod Priority**。所以带 `system-node-critical`(2000001000)
或 `system-cluster-critical`(2000000000) 的 Pod 无论 QoS 如何都排在**最后**，
它们的 BestEffort 基本无害。

```bash
kubectl --context <ctx> -n <ns> get pod <pod> \
  -o custom-columns='QOS:.status.qosClass,PRIO:.spec.priority,CLASS:.spec.priorityClassName'
```

2026-08-10 据此**放弃**了 oracle 侧的 cilium 全家（agent/envoy/operator 都是
system-*-critical）：补 requests 会把 oracle 内存 requests 从 85% 推到 **95%**
（+896Mi / 9080Mi allocatable），把新服务的调度空间吃光，换来的驱逐收益却接近零。
同一集群里真正裸奔的是 `hubble-relay` / `hubble-ui`（priority **0**、无 class），
但那是纯观测组件，掉了不影响服务——于是也一并搁置。

**判据一句话**：BestEffort + priority 0 + 掉了会出事 = 必补；
BestEffort + system-critical = 可以不补；BestEffort + priority 0 + 纯观测 = 看余量再说。

⚠️⚠️ **补 resources 时给不给 CPU limit，要单独判断——给错会引入原本不存在的问题。**
BestEffort 容器此前**没有任何 CPU limit，不可能被节流**；补上就可能被节流。
2026-08-10 实测：给 node-exporter 配 `limits.cpu: 200m` 后节流率 **31%**，
`CPUThrottlingHigh` 当场告警——而它 1m 粒度的峰值只有 **3m**。

原因是**采集/抓取型组件的负载是亚秒级突发**：CFS 按 100ms 周期发配额，
瞬时需求远超均值，1m 粒度的 rate 完全看不见这件事。同批加了同样 200m limit 的
kube-state-metrics 实测节流 **0%**（它维护状态、不突发）——所以这不是普遍规律，
**必须逐个实测**，不能按组件类别想当然。

- **抓取/导出型**（node-exporter 一类）：只给 memory limit，**CPU limit 留空**。
  仓库既有原则同此：`namespace-guardrails.yaml` 写着「不设 cpu limit 以避免 CPU 节流」。
- **常驻服务型**：给 CPU limit 没问题，但补完隔天回来查一次节流率。

```bash
# 判据只有这个；kubectl top 与 1m 粒度 rate 都看不出来（均值极低）
curl -s --data-urlencode 'query=sum by (namespace,container) (rate(container_cpu_cfs_throttled_periods_total{cluster="homelab",container!=""}[1h])) / sum by (namespace,container) (rate(container_cpu_cfs_periods_total{cluster="homelab",container!=""}[1h]))' \
  http://localhost:19090/api/v1/query \
  | jq -r '.data.result[] | select((.value[1]|tonumber)>0.02) | "\((.value[1]|tonumber*100)|floor)% \(.metric.namespace)/\(.metric.container)"' | sort -rn
```

> ⚠️ 同 §2-F：**这条查询在 oracle 上返回空结果**（无 cAdvisor 指标），
> 与「节流率为 0」外观完全一致。oracle 上补 CPU limit 无法用这个方法验证。

⚠️ **补完 BestEffort 后节点的 requests 百分比会上涨，这是正确的**，不是变差。
那些 Pod 本来就在用这些资源，只是之前对调度器隐身。2026-08-10 oracle 实测
CPU 76%→83%、内存 66%→86%。上涨后要顺手做分类 D 把 CPU 收回来。

### C. `MEMORY DIFF` 为正、且推荐值 > 100Mi — 查是不是在逼近 limit

先反推峰值（`推荐 ÷ 1.15`），再和**当前 limit** 比。判据取
[k8s-qos-resource-management.md 的 >80% 规则](../reference/k8s-qos-resource-management.md)。

一次性查全集群（比逐行手算快得多）：

```bash
curl -s --data-urlencode 'query=max by (cluster,namespace,container) (max_over_time(container_memory_working_set_bytes{container!=""}[7d])) / on (cluster,namespace,container) max by (cluster,namespace,container) (kube_pod_container_resource_limits{resource="memory"})' \
  http://localhost:19090/api/v1/query \
  | jq -r '.data.result[] | select((.value[1]|tonumber) > 0.8) | "\((.value[1]|tonumber*100|floor))% \(.metric.cluster)/\(.metric.namespace)/\(.metric.container)"' | sort -rn
```

> ⚠️ 两侧都必须先 `max by(...)` 聚合，否则报 `many-to-one matching must be explicit`；
> 分组键必须带 `cluster`，否则两集群同名 ns 会串味。

处置：**抬 limit**（limit 不占调度预算，抬高是免费的）。
只在「稳态用量明显高于 request」时才一起抬 request —— 那会吃掉调度余量。

这类问题不会自己暴露：容器撞 limit 被 OOMKill 后**干净重启、不进 CrashLoopBackOff**，
`KubePodCrashLooping` 结构上抓不到。集群已有三条规则兜底（`ContainerOOMKilled` /
`ContainerOOMKilledCadvisor` / `ContainerMemoryNearLimit`），说明见
[k8s-qos-resource-management.md § 检测 OOMKill](../reference/k8s-qos-resource-management.md)。
**但告警是兜底，不是替代**——周报分诊要在告警响之前发现它。

### D. `CPU DIFF` 为负 — 只在 oracle 上值得做

homelab 的 CPU requests 长期在 20% 左右，回收没有收益，改动反而是风险。

oracle 不同：allocatable 只有 **1800m**（不是 2 OCPU 整数，k3s 预留 200m），
requests 是那里真正稀缺的东西。逐容器按实测 p95 下调，能一次回收数百 m。

⚠️ 两类**刻意不降**：

- **DNS / 延迟敏感组件**（coredns）：request 是 CPU 竞争时的 shares 底线，
  省那几十 m 不值得拿 DNS 延迟换。
- **CPU 真在干活的安全组件**（falco）：降过头会在事件尖峰被邻居挤掉，
  与「fail-open」的本意相反。

⚠️ **k3s 内置组件（coredns / metrics-server / local-path-provisioner）不在本仓库**，
`grep` 不到。要改得在节点上覆盖 `/var/lib/rancher/k3s/server/manifests/`，
且会被 k3s 重启覆写 —— 收益通常不值这个复杂度，报告里看到它们直接跳过。

### E. 批处理 CronJob 的 CPU 建议 — 忽略

对一次性任务取 p95 没有意义。2026-08-10 报告里 `enrich` 建议
`100m → 501m`、`calibre-metadata-backfill` 建议 `100m → 158m`，且那行还标着 `(0 pods)`。
批处理的 request 应按「不饿死、不挤占」定，不按分位数定。

### F. `CPU LIMITS: unset` 整列 — 不采纳

KRR 无条件建议移除所有 CPU limit。本环境两个理由都不接受：

- **homelab** 是 5600H 热笔记本，CLAUDE.md 的硬约束是「所有安全组件 fail-open + 控 CPU」
- **oracle** 只有 2 OCPU，limits 已超卖 1200%+，那是唯一阻止单个 Pod 吃满整机的护栏

真要判断该不该放宽 limit，看**节流率**而不是听 KRR：

```bash
curl -s --data-urlencode 'query=sum by (namespace,container) (rate(container_cpu_cfs_throttled_periods_total{cluster="homelab"}[24h])) / sum by (namespace,container) (rate(container_cpu_cfs_periods_total{cluster="homelab"}[24h]))' \
  http://localhost:19090/api/v1/query | jq -r '.data.result[] | select((.value[1]|tonumber)>0.02) | "\((.value[1]|tonumber*100)|floor)% \(.metric.namespace)/\(.metric.container)"'
```

> ⚠️⚠️ **oracle 上这个查询会骗你**：oracle **没有 cAdvisor 节流指标**
> （`container_cpu_cfs_throttled_*` homelab 41 条 / oracle **0 条**），
> 查询返回**空结果**，与「节流率为 0」外观完全一致。2026-08-10 就据此误下过
> 「oracle 无节流」的结论。在 oracle 上只能看 limit 与 p95 的比值 + 应用日志时序。

---

## 3. 报告看不见的东西

KRR 只报「当前 spec 的数值」与「实测用量」的差。有三类问题它**结构上照不出来**，
但恰恰会被它的输出**间接暴露**——看到下面这些信号时要往深查一层。

| 报告里的信号 | 可能的真问题 | 怎么确认 |
|---|---|---|
| values 里明明写了 resources，报告却显示 `unset` | **配置写错层级被 chart 静默忽略** | `helm template <chart> --version <ver> -f <values>` 看渲染出的容器 spec 是不是 `resources: {}` |
| git 里有 resources，集群里没有 | **改了但从没部署**（manual-helm 组件） | `helm get values <release> -n <ns> --kube-context <ctx>` 与 git 对比；再比 commit 时间和 `helm list` 的 UPDATED |
| ns 有 LimitRange，个别 Pod 仍 BestEffort | **Pod 早于 LimitRange**（只在准入时注入，不追溯） | 比 Pod 的 `creationTimestamp` 与 LimitRange 的；修法是 `rollout restart` |

三种都在 2026-08-10 实际命中过。第一种最隐蔽：
`kubeStateMetrics.resources` 写在了父 chart 的开关键下（正确位置是子 chart 别名
`kube-state-metrics.resources`），chart 静默忽略、不报错，配置在 git 里躺了几个月。

**这就是 KRR 真正的作用**——它不只是省钱工具，是**唯一会持续复读「集群里实际是什么」
的东西**，所以它能照出「文档/配置说了什么」和「集群实际怎样」之间的漂移。

---

## 4. 改哪里 / 怎么下发

同一个组件在两个集群可能归属不同。**下发方式搞错 = 改了不生效**。

```bash
# 判据只有一个：对象上有没有 ArgoCD tracking-id
kubectl --context <ctx> -n <ns> get deploy <name> \
  -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}'
```

| 结果 | 归属 | 下发方式 |
|---|---|---|
| 非空 | ArgoCD | 改 values/manifest → `git push`（3 分钟轮询；急用 `kubectl -n argocd patch app <app> --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'`） |
| 空 | 手动 helm | 改 values → 跑对应 `just deploy-*`；**git push 不生效** |

⚠️ **别用 `helm list` 判断归属**：ArgoCD 接管之前装过的 release 会一直留在那里。
2026-08-10 就因此把 kube-prometheus-stack 误判成手动 helm（它其实是 ArgoCD 管的）。

⚠️ 手动 helm 的 recipe 跑之前**先确认它带 `--version` pin**。2026-08-10 一次只为改
resources 的 `just deploy-cilium`，因为 oracle 那份 recipe 缺 pin，把 Cilium 从 1.19.1
静默升到了 1.20.0，并连带冲掉 ClusterMesh 的跨集群 CA 信任。
Cilium 相关的额外必跑步骤见 `k8s/cilium/values.yaml` 与
`cloud/oracle/values/cilium-values.yaml` 的文首注释。

---

## 5. 验证（这一步不能省）

**「push 了」和「生效了」是两回事**，本轮三种失效模式全都命中过（见 §3）。
每次改完必须实测：

```bash
# 1) 目标容器的 QoS 与实际生效的 requests（BestEffort 说明没生效）
kubectl --context <ctx> -n <ns> get pods -o json | jq -r \
 '.items[] | select(.status.phase=="Running") | .metadata.name as $n | .status.qosClass as $q |
  .spec.containers[] | "\($q)  \($n)  \(.name)  req=\(.resources.requests // "❌无")"'

# 2) 两集群还剩多少 BestEffort（分类 B 的收敛判据）
for ctx in oracle-k3s k3s-homelab; do
  printf "%-12s " "$ctx"
  kubectl --context $ctx get pods -A -o json | jq '[.items[]|select(.status.phase=="Running" and .status.qosClass=="BestEffort")]|length'
done

# 3) 节点账面（补完 BestEffort 后 requests 上涨是正常的，见分类 B）
kubectl --context <ctx> describe node | sed -n '/Allocated resources/,/Events/p'
```

⚠️ **内存余量不要看 `kubectl top node`**，它报 workingSet（含可回收页缓存）会虚高到
90%+。2026-08-10 实测 oracle `top` 报 96%，而节点 `free -m` 的 **available** 还有 3.5GB。
判余量看 `free -m` 的 available：

```bash
kubectl --context <ctx> -n kube-system exec ds/cilium -c cilium-agent -- sh -c "free -m | head -2"
```

---

## 6. 一轮完整分诊的产出长什么样

2026-08-10 那轮（homelab 42 行 + oracle 70 行）的归类与结果，作为颗粒度的参照。
下表只列**实测确认过**的数字：

| 类 | 结果 |
|---|---|
| A 忽略 | 29 行（homelab 8 + oracle 21），无动作 |
| B BestEffort | Pod 数 oracle **15→5**、homelab **9→3**；剩下的是 cilium 全家与 k3s 内置组件 |
| C 逼近 limit | 抬了 11 个（grafana 98% / kyverno ×2 / prometheus 93% / redpanda 94% / karakeep / opencost / argocd ×2 / trivy / uptime-kuma / restic / otel-homelab）；**剩 4 个刻意留到下一轮**——cilium-operator 与 cilium-agent（改它们要再跑一轮 `deploy-cilium` + `connect-clustermesh`）、oracle 的 otel-collector、restic（CronJob，limit 已改但要等下次运行才反映到指标）。同批补上**事前**告警 `ContainerMemoryNearLimit` |
| D CPU 回收 | 只做 oracle：requests **83%→71%**（补完 B 之后的 83% 起算） |
| E/F 不采纳 | 记录理由，不改 |

顺带照出 3 个「配置在 git 里但从未生效」的问题（§3），这部分的价值超过资源本身。

---

## 相关文档

- [reference/cost-and-rightsizing.md](../reference/cost-and-rightsizing.md) — KRR 部署拓扑、依赖指标、参数（本文的事实来源）
- [reference/k8s-qos-resource-management.md](../reference/k8s-qos-resource-management.md) — QoS/驱逐/OOMKill 判据与原则
- [runbooks/oracle-k3s-shape-downsize.md](oracle-k3s-shape-downsize.md) — 改 shape 时的 requests 右尺寸前置（本文分类 D 的一次实战应用）
