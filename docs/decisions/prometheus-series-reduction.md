# Prometheus 指标瘦身：砍 series，而不是继续抬 limit

> 日期: 2026-08-18
> 状态: ✅ 已实施

## 上下文

`ContainerMemoryNearLimit` 自 2026-08-16 17:30 起连续两天为 Prometheus 告警，
每 4h 往 Telegram 重复投递一次。当时的实测负载：

| 指标 | 值 |
|---|---|
| active series | 234,532 |
| 摄入速率 | 7,562 samples/s |
| TSDB on disk | 3.68 GiB（retention 7d / retentionSize 4608MB） |
| 7d 内存峰值 | **2,715Mi / 3,072Mi = 88%** |

当天的第一反应是抬 limit 3Gi→4Gi，并在 values 里写下「**下一步不该继续抬，而是砍
series**」。之所以不能一直抬：Prometheus 是那台 12GB 笔记本 VM 上**最大的单一内存
消耗者**，而宿主 pve 的 available 只剩 ~0.6G（VM 已吃掉 13312MB），物理内存见底。

更重要的是同一天的教训：`multica-frontend` 因为按空载采样收 limit 而 OOM 崩循环
（[复盘](../records/2026-08-18-multica-frontend-idle-rightsizing-oom.md)）。limit 是
**上限不是解法**——抬上去只是把撞墙时间往后推，真正要动的是产生内存的东西本身。

## 发现：k3s 把同一批指标抓了两遍

k3s 把 apiserver 与 kubelet 跑在**同一个进程**里，kubelet 的 `/metrics` 端点因此把
整个进程的 registry 全吐出来，**包含全套 `apiserver_*` / `etcd_*`**。它们与
`job="apiserver"` 抓到的是同一批指标的第二份副本（标签不同，故是两批独立 series）。

| 位置 | series | 占比 |
|---|---|---|
| `job="kubelet"` 里的 `apiserver_*` | 62,616 | 26.7% |
| `job="kubelet"` 里的 `etcd_*` | 11,858 | 5.1% |
| —— 小计，占 kubelet 这个 job 全部 93,056 条的 | **74,474** | **80%** |
| `job="apiserver"` 侧无人使用的 7 族 histogram | 30,035 | 12.8% |
| **合计可丢** | **104,509** | **44.6%** |

即：**这个集群里近一半的 series 是重复的或没人看的**。

## 决策一：砍 series，被否决的替代方案

| 选项 | 结论 |
|---|---|
| 继续抬 limit（4Gi→更多） | ❌ 节点物理内存见底；且不解决成因，只推迟 |
| 缩短 retention | ❌ **retention 管的是磁盘不是内存**。head 内存由 active series 决定，砍 retention 不改变它；且 7d 是 KRR `--history-duration 168` 的对齐前提，动它会连带弄坏右尺寸（见 [cost-and-rightsizing.md](../reference/cost-and-rightsizing.md)） |
| 关掉 kubelet job | ❌ 会连 cAdvisor 与真正的 kubelet 指标一起丢 |
| 两个 job 都整族丢 `apiserver_*` | ❌ 会丢掉 `apiserver_request_sli_duration_seconds_bucket`，`kube-apiserver-histogram.rules` 的两条 recording rule 直接哑掉 |
| **按 job 分别 drop**（采纳） | ✅ kubelet 侧整族丢重复副本；apiserver 侧只丢无人引用的 7 族 |

## 决策二：为什么「可以」这么砍——三层证据，不是「看着没用」

这是本决策的核心。判据**不是**"这个指标名眼生"，而是三层独立验证：

**① 规则层**：把所有 loaded rule 的表达式拉出来逐条搜指标名。结果：引用这两族的
规则**全部写死 `job="apiserver"`**，无一条用 `job="kubelet"`。唯一仍在使用的是
`cluster_quantile:apiserver_request_sli_duration_seconds:histogram_quantile`
（两条，`job="apiserver"`）——所以 sli 那族的 apiserver 副本必须留，kubelet 副本可丢。

**② 看板层**：扫全部 **42 个 `grafana_dashboard` ConfigMap**。这两族指标
**没有任何 panel 用 `job="kubelet"` 查**；实际上连带显式 job 的查询都没有——
面板消费的是 **recording rule 的输出**（`cluster_quantile:...`），不碰原始 bucket。
> ⚠️ 顺带纠正一处旧认知：values 里曾写「apiserver 看板依赖
> `apiserver_request_duration_seconds_bucket`」。**不准确**——最大单项那个（28,016 条）
> 无 rule 无 panel 使用，真正被用的是 **sli 版**。

**③ 改完在抓取层验证**（不是看配置文件，是看实际留下多少样本）：

| job | 改动前 kept/scrape | 改动后 |
|---|---|---|
| kubelet | 92,702 | **18,228** |
| apiserver | 57,357 | **27,322** |

每轮少留 **104,509** 个样本，与①②算出的数字分毫不差——这才算证明生效。

**另外两道防呆**：

- **正则锚定回归**：要丢 `apiserver_request_duration_seconds_bucket` 却必须留
  `apiserver_request_sli_duration_seconds_bucket`。Prometheus 的 relabel 正则是
  **全锚定**的，拿 13 个指标名跑过一遍回归，确认 sli 在 apiserver 侧存活、
  仅在 kubelet 侧作为副本被丢。
- **chart 默认值必须原样保留再追加**：`kubelet` 与 `kubeApiServer` 两个
  `metricRelabelings` 的 chart 默认值**不是空的**（分别 drop csi/storage 分桶与一串
  `le` 分桶）。☠️ YAML 里 list 是**整体覆盖**——直接写自己的会把默认那条弄丢，
  **series 反而变多，且不会有任何报错**。故默认值是用脚本从 chart values 里读出来
  原样抄的（当前抄自 **87.6.0**），再 `helm template` 验证渲染结果：
  apiserver/kubelet 的 `/metrics` 各 2 条，`/metrics/cadvisor` 的 8 条默认值未被波及。

## 决策三：limit 收回 3Gi 的依据是**单调性**

砍完 series 后把 limit 从 4Gi 收回 3Gi。依据不是"感觉够了"——同一天 multica 正是
靠感觉收 limit 崩的——而是：

> **3Gi 这个值在 234,532 series 的更重负载下已经跑过**（7d 峰值 2,715Mi = 88%，
> 从未 OOM）。现在负载严格更小，回到 3Gi 必然比当时更宽裕。

这是**回到一个已被验证的值**，不是押一个没验过的新值。两者的风险性质完全不同。

## 结果

| | 改动前 | 改动后 |
|---|---|---|
| active series | 234,532 | **109,566**（−53%） |
| 摄入速率 | 7,562 samples/s | **2,879**（−62%） |
| Prometheus limit | 4Gi | **3Gi** |
| cgroup peak | 2,002Mi | **758Mi**（占上限 24%） |
| 节点 available | 5,016Mi | **5,344Mi** |

降幅比预估的 44.6% 更大（53%），因为重启时 WAL 回放顺带清掉了其它陈旧序列。

改动后核对「必须活着的」：sli bucket 5,040 条 · 那两条 recording rule 输出 71 条 ·
cAdvisor 220 条 · 61 个 target 全 `up` · Grafana `database: ok`。

## 后果与代价

- **原始 bucket 不能再 ad-hoc 查**（Grafana Explore 里也没有了）。面板不受影响，
  因为它们走 recording rule 输出。需要原始分位时只能临时把 drop 摘掉重抓。
- ⚠️ **若重新打开 `defaultRules` 的 `kubeApiserverBurnrate` / `Slos` / `Availability`**
  （当前三条都是 `false`），**必须回来复核 kubeApiServer 那条 drop**——它们可能需要
  这里丢掉的族。
- ⚠️ **升 kube-prometheus-stack 时必须重新比对**两个 key 的默认 `metricRelabelings`
  有没有变（当前抄自 87.6.0）。默认值变了而我们没跟，等于悄悄回退了 chart 的优化。
- 📌 **有一条 7 天期 Alertmanager 静默在跑**（2026-08-18 建，到期 **2026-08-26**，
  matchers: `alertname=ContainerMemoryNearLimit` · `container=prometheus` ·
  `cluster=homelab`）。原因是规则的**窗口错位**：分子 `max_over_time[7d]` 一周内仍记着
  砍 series 之前的 2,715Mi，分母却已是新的 3,072Mi → 算出 88% 的**伪阳性**，而实测
  peak 只有 758Mi。静默是 Alertmanager 运行时状态、**不在 git 里**，到期自动失效。
  **到期后若仍报就是真的，别再续一条**。
- ⚠️ **想再往 3Gi 以下收，必须等 7d 窗口滚完后重新测峰值**——此刻的低读数是假象；
  head series 也要等 head compaction（约 2h）才掉下来。

## 复核触发条件

出现下列任一情况，回头重跑本文①②③三层验证：

- 升 kube-prometheus-stack（默认 `metricRelabelings` 可能变）
- 重新启用上面那三条 `defaultRules`
- 新增消费 apiserver/etcd 原始 bucket 的看板或规则
- k3s 改变 apiserver/kubelet 的进程模型（本优化的前提就是"同进程导致重复暴露"）

## 相关

- [reference/observability-multicluster.md](../reference/observability-multicluster.md) — 采集架构（生效事实）
- [records/2026-08-18-multica-frontend-idle-rightsizing-oom.md](../records/2026-08-18-multica-frontend-idle-rightsizing-oom.md) — 同日的反面教材：按空载采样收 limit 导致 OOM
- [reference/k8s-qos-resource-management.md](../reference/k8s-qos-resource-management.md) — QoS / 资源判据
- [decisions/opencost-krr-data-sources.md](opencost-krr-data-sources.md) — 同样是"按消费者裁剪采集面"的思路
