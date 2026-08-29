# `ContainerMemoryNearLimit` 报 Prometheus 99.45%：峰值 87% 是页缓存，容器顶死 limit 也不会 OOM

> 日期: 2026-08-30（告警始于 2026-08-29 15:49 UTC）
> 影响: **无服务影响**。一条 warning 告警持续投递 Telegram，按 4h `repeat_interval`
>       将连报至 2026-09-05，约 40 条。无 OOM、无重启、无查询降级
> 根因: 规则用 `container_memory_working_set_bytes`，该指标 = `memory.current − inactive_file`，
>       **含页缓存**。容器重启后读 TSDB 文件把 2652Mi 页缓存计入分子 → 99.45%；
>       同一时刻 Go 堆（RSS）只有 408Mi，换算成 RSS 口径是 **26.4%**
> 结论: **告警在测一个不构成 OOM 风险的量**，且该读数主要由**节点页缓存冷热**决定 ——
>       对照实验：同容器/同数据/同 limit 的三次重启，峰值 **3072Mi(99.45%) → 2153Mi(70.1%)
>       → 728Mi(23.7%)**，跨度 5 倍。本次未改规则（见文末「未做」），只归档分析与判据
> 触发: 按 [runbooks/proxmox-host-upgrade.md](../runbooks/proxmox-host-upgrade.md)
>       做宿主内核升级（`7.0.0-28` → `7.0.0-30`），k8s-node 于 15:08 / 15:35 两次重启

全文时刻均为 **UTC**。

## 直接证据：那个容器不是被杀的

经历 3055Mi 峰值的就是这个容器，它自己的终止状态：

```json
{ "startedAt": "2026-08-29T15:09:21Z", "finishedAt": "2026-08-29T15:33:22Z",
  "exitCode": 0, "reason": "Completed" }
```

`exitCode 0 / Completed` —— 它活过了峰值，24 分钟后随第二次重启正常退出。
后续所有分析都建立在这一条之上：**顶到 limit 但没被杀**。

## 现场：峰值拆开看

15:09:21 容器拉起。30s 采样（Mi）：

| 时刻 | working_set | **rss** | **cache** | usage |
|---|---|---|---|---|
| 15:08:00（重启前） | 990 | 631 | 1160 | 1829 |
| **15:10:30（峰值）** | **3055（99.45%）** | **408（26.4%）** | **2652** | **3072（=limit）** |
| 15:11:30 | 791 | 686 | 1800 | 2517 |
| 15:35:00（稳定后） | 1147 | 615 | 2103 | 2767 |

**RSS 在峰值时刻反而是全窗口最低的 408Mi** —— 新进程刚起来，堆还没长起来。
3055 里约 87% 是 cache。

## ☠️ 容器**确实顶死了 limit**，而且什么都没发生

```
container_memory_usage_bytes      15:10:30 → 3072 Mi（15:12:30 又顶一次）
container_memory_max_usage_bytes  15:10:30 → 3072 Mi，此后一直钉在这里
resources.limits.memory                     3 Gi = 3072 Mi
```

`usage` **精确等于 `memory.max`**。cgroup 触到上限、内核跑了回收 —— 丢掉干净的
file page 就完事，没有 OOM kill（上一节的 `exitCode 0` 是证据）。
干净的 file page 永远可回收，内核在 OOM 之前一定先回收它们。

## ⚠️ 但「working_set 塌下去」≠「内存被回收」——两个机制别搞混

第二次重启（15:38:30 拉起）是天然的对照组，它**没有**顶到 limit，却同样出现
working_set 断崖：

| 时刻 | working_set | rss | cache | usage |
|---|---|---|---|---|
| 15:41:30 | **2054** | 651 | 1425 | 2084 |
| 15:42:00 | **660** | 652 | 1396 | 2055 |

**working_set 掉了 1394Mi，而 `usage` 只掉 29Mi、cache 只掉 29Mi、rss 纹丝不动。**
什么都没被回收 —— 掉的是 `active_file`：刚读进来的文件页先挂在 **active LRU**，
约两分钟无人再引用就被降级到 `inactive_file`，而 `working_set = usage − inactive_file`，
于是账面上凭空少一大截。

所以本次两次重启是**两个不同机制，都会把 working_set 顶起来**：

| | 第一次（15:09） | 第二次（15:38） |
|---|---|---|
| 峰值 working_set | 3055 Mi | 2054 Mi |
| `usage` 是否触顶 | ✅ 精确到 3072 = limit | ❌ 最高 2084 |
| 回落原因 | **真回收**（usage 从 3072 降到 2767） | **LRU 降级**（usage 几乎不变） |

☠️ **别拿「working_set 掉下来了」推断「压力解除了」** —— 第二次那种情况下内存一点没还，
只是换了个 LRU 链表。

## 峰值的来源：不只是 WAL replay

磁盘实测（`local-path` PVC，节点上 `du`）：

```
总计         6.2 G
├─ chunks    5280 MiB（22 个 block）
├─ index      701 MiB（22 个 block）
├─ wal        272 MiB
└─ chunks_head 70 MiB
```

⚠️ **WAL 只有 272Mi，单靠「WAL replay 读文件」解释不了 2652Mi 的 cache。**
Prometheus 启动时还会打开全部 22 个 block 并 mmap 其 index（701Mi），
日志可见 `Replaying on-disk memory mappable chunks` + `WAL replay completed`
（`wal_replay_duration=17.1s`，第二个容器的日志；**第一个容器的日志已随容器销毁**，
它的 replay 细节无法回溯）。

### ❌ 一个曾经写进本文、后被自己数据推翻的推断

一度据此推断「cache 被 limit 封顶而非被数据量封顶 → 抬 limit 会等量抬高峰值 → 抬 limit
是无效动作」（理由是磁盘 6.2G 可缓存数据远多于 limit 能装下的量，而 `usage` 精确停在 3072Mi）。

**这条不成立，反证来自同一次事件的第二个容器**：

```
第二个容器（15:38 拉起，跑满 6.5h，含完整启动 + WAL replay + 全部规则组冷评估）
  生涯峰值 usage = 2153 Mi / 3072 Mi = 70.1%      ← 从没接近过 limit
  稳态 cache 近 6h 平在 1206–1452 Mi，无向 3072 爬升的趋势
```

若「cache 会涨到接近 `memory.max` 才回收」成立，它也该顶到 3072。它没有。
**页缓存在本例中并非 limit-bound。** 抬 limit 会不会抬高峰值 —— **未知，本次数据答不了**，
要答只能做「改 limit 复测」的对照实验。

## 对照实验 A（2026-08-30 22:31）：热缓存下重启，峰值只剩 23.7%

为验证「峰值由节点页缓存冷热决定」这个假设，在**不改任何配置**的前提下重启一次 pod
（`kubectl delete pod`），用节点上直读 cgroup 采样（不依赖 Prometheus 自采集，
避开它重启期间的空档）：

```
容器启动 22:31:20 · WAL replay 11.1s · 22:31:32 ready · 采样覆盖启动后 255s
  22:31:21  cur=334  anon=119  file=216
  22:32:54  cur=724  anon=503  file=218
  22:33:10  peak=728 Mi = 23.70%        ← 全程最高
  22:35:36  cur=723  anon=502  file=218  ← 无迟到尖峰（重启2 的峰值出现在启动后 180s）
```

### 三次重启横向对比

| 重启 | 节点页缓存状态 | 峰值 `usage` | %limit | 该容器 `file` |
|---|---|---|---|---|
| 1 · 15:09 | 刚开机，**全冷** | **3072 Mi** | **99.45%** | 2652 Mi |
| 2 · 15:38 | 29 分钟后，**半热** | 2153 Mi | 70.1% | ~1425 Mi |
| 3 · 22:31 | 7 小时后，**全热** | **728 Mi** | **23.70%** | **218 Mi** |

**`anon`（Go 堆）三次都在 400–550Mi 量级，唯一变的是 `file`：2652 → 1425 → 218 Mi。**

☠️ **同一容器、同样的数据、同样的 limit，峰值跨度 5 倍，85% 阈值被穿过两次方向。**
这条告警的读数与容器实际需要多少内存无关，取决于**它重启那一刻节点页缓存冷不冷**。

机制：cgroup v2 只对自己从磁盘 fault 进来的页计费。旧容器死后它那份页缓存并不立刻消失，
新容器读到已常驻的页是「搭便车」，不重复计费 —— 所以越晚重启、缓存越热，账面越小。

> ⚠️ **实验前的预测是 ~70%，实测 23.7%，预测失准。** 原因是拿重启 2 当锚，
> 而重启 2 本身只是半热（距冷启动仅 29 分钟）。方向对、量级错。

### ⚠️ 顺带撞到的取证陷阱：旧容器序列会污染聚合

实验中 cAdvisor 报 `usage` 2035Mi，与 cgroup 直读的 728Mi 对不上。拆开 `id` 标签才看清是两条序列：

```
id…0b63c4d8fb（旧容器，已销毁）  2035 Mi   ← 仍在 5 分钟 staleness 回看窗内
id…89eef1b8a4（新容器）           720 Mi   ← 与 cgroup 直读 cur=697/peak=728 吻合
```

告警规则写的是 `max by (cluster, namespace, pod, container)`，**把 `id` 聚合掉了** ——
**每次容器重启后的 5 分钟，规则读到的是上一个容器的值。**
与 [observability-alerting-slo.md](../reference/observability-alerting-slo.md) 里
「换 pod 后旧 `instance` 陈旧值仍在回看窗内」同类，但发生在容器 `id` 维度，此前未记录。

## 规则的四个结构性问题

线上规则（`manifests/monitoring/alerts/prometheus-rules.yaml`）：
`max_over_time(container_memory_working_set_bytes[7d]) / limit > 0.85`，`for: 30m`。

| # | 问题 | 说明 |
|---|---|---|
| ① | **指标含页缓存** | 对 mmap/文件重的负载不是 OOM 风险的代理量。改 RSS 口径同一容器是 **26.4%** |
| ② | **读数由页缓存冷热决定** | 见上节实验 A：三次重启 99.45% / 70.1% / 23.70%，**跨度 5 倍**，与容器内存需求无关。拿它做 85% 判断是在测节点缓存状态 |
| ③ | **`for: 30m` 是装饰品** | 分子是 7d 的 max，顶上去就是平台期，`for` 起不到去抖作用，只把首次投递推迟 30min。实际持续时间由窗口长度决定 = 7 天 |
| ④ | **窗口与 doc 不一致** | [k8s-qos-resource-management.md](../reference/k8s-qos-resource-management.md) 给的排查查询用 `[2d]`，线上规则是 `[7d]` |

⚠️ 本形状**不同于** 2026-08-24 记的 grafana「峰值跟着 limit 走」（那次是 chart 把
`GOMEMLIMIT` 硬接成 `limits.memory`，抬 limit 确证无效）。本例**没有**这种绑定关系，
别把那边的结论搬过来。已作为**第四种形状**补进
[k8s-qos-resource-management.md](../reference/k8s-qos-resource-management.md)。

## 影响面：机制普遍，但当前只有这一个容器踩线

⚠️ 两件事要分开说，别混为一谈。

**（a）页缓存主导 working_set 是普遍现象**（当前 `cache / working_set`，>100% 是因为分母扣掉了
`inactive_file`）：

```
vault/vault 258%   kube-system/coredns 254%   personal-services/nakama 210%
jobs-sg/web 209%   trivy-system/trivy-server 162%   monitoring/alertmanager 157%
monitoring/prometheus 149%   kube-system/apiserver 135%
```

**（b）但当前没有第二个容器逼近阈值**（7d working_set 峰值 / limit，双集群 top 6）：

```
homelab     monitoring/prometheus            99.4%   ← 唯一 >85%
oracle-k3s  monitoring/kube-state-metrics    83.7%
oracle-k3s  opencost/opencost                79.5%
oracle-k3s  trivy-system/trivy-operator      77.8%
oracle-k3s  argocd/application-controller    73.9%
homelab     vault/vault                      73.1%
```

即 (a) 说明**这类假阳性随时可能在别的容器上复现**，但不能据此说「现在有一堆误报」。

## ☠️ 改规则的坑：oracle 侧做不了这套拆解

直觉改法是 `and` 一条 RSS 条件把页缓存假阳性滤掉。**这样会让 oracle 侧这条告警彻底失效**：

```
container_memory_working_set_bytes  homelab 162 条 · oracle-k3s  58 条   ← 唯一入库的
container_memory_rss                homelab 162 条 · oracle-k3s   0 条
container_memory_cache              homelab 162 条 · oracle-k3s   0 条
container_memory_usage_bytes        homelab 162 条 · oracle-k3s   0 条
container_memory_max_usage_bytes    homelab 162 条 · oracle-k3s   0 条
```

`cloud/oracle/manifests/monitoring/otel-collector-config.yaml:280` 的 keep 正则是
`container_(cpu_usage_seconds_total|memory_working_set_bytes)`。
**oracle 唯一到达中枢 Prometheus 的容器内存指标，恰好就是有误导性的那一个** ——
那边根本做不了本文这套拆解，只能 SSH 上节点读 `/sys/fs/cgroup/.../memory.stat`。
直接 `and` 上去会让 oracle 侧该告警**恒不触发**，外观与「没超阈值」完全一致。

要改必须先决定顺序：**先把 `container_memory_rss` 加进 oracle 的 keep 正则**
（+58 条 series，成本可忽略），再改规则；或规则里用 `cluster="homelab"` 限定 RSS 那半、
oracle 维持现状并把这个不对称写进注释。

## ⚠️ 取证更正：`container_memory_failcnt` 在 cgroup v2 上是废指标

排查中一度引用 `container_memory_failcnt = 0` 作为「没触到上限」的证据，**这是错的**
（而且结论也反了 —— 实际顶到了）：

- 节点是 **cgroup v2**（`stat -fc %T /sys/fs/cgroup` → `cgroup2fs`）；
- `failcnt` 是 cgroup **v1** 的 `memory.failcnt`，v2 无对应文件，cAdvisor 恒报 0；
- 恒 0 与「真的没触到」外观完全一致 —— 与 oracle「指标未采集 vs 值为 0」同类陷阱。

v2 上的正确判据：容器活着时读 `memory.events` 的 `max`/`oom`/`oom_kill`，
或可回溯的 `container_memory_max_usage_bytes`（**仅 homelab 采集**）。
当前容器（15:38 起）的读数：

```
memory.events:  low 0   high 0   max 0   oom 0   oom_kill 0
memory.stat:    anon 512Mi   file 1433Mi   inactive_file 1029Mi   active_file 404Mi
```

⚠️ 15:09 那个容器的 cgroup 随容器销毁已不存在，**它的 `memory.events` 无法回溯**。
「顶死 limit」的结论来自 cAdvisor 的 `usage`/`max_usage`，「没被杀」的结论来自
容器 `exitCode 0`。

## 「内存能不能还给系统」——前提是错的

**`limits.memory` 不预留任何内存。** 只有 `requests` 参与调度算术；limit 是「最多能用到」，
不是「占住」。节点侧的硬证据：**尖峰那一分钟（15:10）k8s-node `MemAvailable` = 9299 Mi**，
是整个窗口的最高值（刚重启、缓存冷）。节点全程零压力。

| 想压的部分 | 旋钮 | 本例适用吗 |
|---|---|---|
| Go 堆峰值 | `GOGC` 调低 | ❌ `go_memstats_heap_inuse` 只有 414Mi/3Gi，GC 无压力。grafana GOGC=40 那次是堆真撑满 |
| Go 堆峰值 | `GOMEMLIMIT` | ❌ 同上；且 doc 已记 env 渲染顺序坑 |
| 页缓存峰值 | 降 `limits.memory` | ❓ 效果未知（见「峰值的来源」：cache 在本例中并非 limit-bound，第二个容器峰值只到 70%）。且**收益本就是假的**：页缓存本就计入节点 `MemAvailable` |
| 调度层份额 | `requests` | ✅ 已经对了：稳态 RSS 504Mi vs requests 512Mi |

Go 1.16+ 在 Linux 默认 `MADV_DONTNEED`，GC 释放的 span 当场还给内核 —— 匿名内存这侧
本来就不存在「占住不放」。实测 RSS 全程在 330–690Mi 区间，从未爬升。

## 证据强度自查

| 结论 | 强度 | 依据 |
|---|---|---|
| 峰值 87% 是页缓存 | **实测** | `rss` / `cache` / `usage` 三指标同时刻交叉 |
| 顶到了 `memory.max` | **实测** | `usage` = `max_usage` = 3072Mi = limit，两次 |
| 没有 OOM | **实测** | 该容器 `exitCode 0 / Completed` |
| working_set 断崖 ≠ 回收 | **实测** | 对照组：ws −1394Mi 而 usage −29Mi |
| 峰值由页缓存冷热决定 | **实测（对照实验 A）** | 三次重启 3072 / 2153 / 728 Mi，同容器同数据同 limit |
| 旧容器序列污染 `max by` 聚合 5 分钟 | **实测** | 拆 `id` 标签后两条序列 2035 vs 720 Mi |
| ~~cache 被 limit 封顶~~ | **❌ 已被自己数据推翻** | 第二个容器跑满 6.5h 峰值仅 70%、稳态 cache 无爬升 |
| 抬 limit 是否有效 | **未知** | 仍需「改 limit 复测」对照实验；实验 A 只改变缓存冷热、未动 limit |
| 第一次尖峰为何比第二次高 1Gi | **有解释未闭环** | 缓存冷热可解释（实验 A），但该容器日志已销毁，无法直接验证 |

## 未做（留待后续）

本次**只归档，不动配置**：

- [ ] 未建 Alertmanager 静默。该告警按 4h 重投，7d 窗口滚过前（约 2026-09-05 15:10 UTC）
      不会自灭。⚠️ 静默是运行时状态、不在 git 里
- [ ] 未改告警规则（指标口径 / 窗口 `7d→2d` / annotation 补当前值）
- [ ] 未给 oracle 的 otel-collector keep 正则加 `container_memory_rss`
- [x] ~~对照实验 A（热缓存下重启）~~ —— 2026-08-30 22:31 已做，见上文
- [ ] 未做「改 limit 复测峰值」的对照实验 —— 「抬/降 limit 有没有用」因此**仍是未知**
- [ ] 未做实验 B（`drop_caches` 后重启，预期复现 95%+）—— ⚠️ 它会把 7d 窗口从实验当天重新计时
- [ ] Prometheus 的 `resources` 未动 —— 结论是**不该动**

⚠️ 2026-08-18 曾为同一条告警建过 7 天静默（那次是砍 series 造成的窗口错位），
`k8s/helm/values/kube-prometheus-stack.yaml` 里写着「到期后仍然报，别再续一条，去查为什么」。
本次查了，**原因与上次不同**：上次是分子分母的时间窗错位，这次是指标口径本身选错。
