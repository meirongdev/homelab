# multica frontend 按「空载实测」收上限 → OOM 崩循环；CPU 500m 让图片优化拖慢首页

> 日期: 2026-08-18
> 影响: `multica.meirong.dev` 的 frontend 进入 OOMKilled 崩循环——13 分钟内重启 3 次，
>       cgroup 累计 `oom_kill 6` / `oom_group_kill 3`。公网首页间歇性 4.5s+ 才出内容。
>       ⚠️ **对外仍是 HTTP 200**：崩循环期间从公网探 `/` 拿到的一直是 200
>       （只是慢），所以任何「看状态码」的探测都不会变红。
> 根因: 两条，同一个病因——**上限是按空载采样定的，而这个容器的负载是突发型的**。
>       ① memory：`5f9e4a0` 把 frontend 上限 768Mi→512Mi，依据写的是"空载 workingSet
>       177.1Mi，仍留 3 倍余量"。但 Next.js 的 `/_next/image` 优化器（sharp）单个并发任务
>       实测 **+68Mi**（144Mi→212Mi，做完立刻释放），空载采样看不见这一段；静息 ~150Mi
>       上叠几个并发就过 512Mi。② CPU：上限 500m（初次部署 `fbb4502` 就带的，不是右尺寸
>       改的）实测 **125 个周期里 82 个被 throttle（66%）**，单张图优化 2.3s，并发时把
>       SSR 的 `/` 从 0.21s 拖到 0.77s。
> 结果: 两个上限均回到 **chart 上游默认**（cpu 1000m / memory 1Gi），`96ee0c2`。
>       requests 不动（静息实测 113–150Mi）。postgres / backend 的 cgroup 查过，
>       `max` 与 `oom_kill` 全 0，未动。

## 时间线（UTC）

| 时刻 | 事件 |
|------|------|
| 05:59 | frontend Deployment 建立（revision 1，上限 768Mi / 500m），运行 8 小时无 OOM |
| ~14:20 | `5f9e4a0` 的 512Mi 经 ArgoCD 落地 → revision 2 滚出，pod 重建 |
| 14:30–14:32 | 连续 3 次 OOMKilled（`BackOff` x3 over 2m16s），`memory.peak` 顶死 512Mi 整 |
| 14:33 | 用户报「服务好像有问题」，开始排查 |
| 14:5x | `96ee0c2` push，ArgoCD 同步回 1Gi / 1000m |

## 证据（都是这次实测，不是推断）

**memory 顶死在上限**——`memory.peak` 与 `memory.max` 完全相等，说明峰值是被上限截断的，
不是"刚好够用"：

```bash
# 在 k8s-node 上；CG=/sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod<pod-uid 下划线形式>.slice
sudo cat $CG/memory.peak    # 536870912  = 512Mi 整
sudo cat $CG/memory.max     # 536870912
sudo cat $CG/memory.events  # max 697   oom 5   oom_kill 6   oom_group_kill 3
```

`max 697` 是**撞上限后被迫回收**的次数——它在 OOM 之前就已经累计了几百次，是比 `oom_kill`
更早的信号。

**单个图片优化 +68Mi 且做完就释放**（每 0.5s 采一次 `memory.current`，中间打一发
`/_next/image?...&w=2048&q=85`）：

```
144 144 144 144 144 148 205 212 210 209 151 150 150 ...   # 单位 Mi
```

所以**空载采样必然漏掉这 68Mi**——它只在优化那 2 秒内存在。

**CPU 被 throttle 掉 66%**（判据是比例，不是 `kubectl top`——`top` 在这里只报个位数 m）：

```bash
sudo grep -E 'nr_periods|nr_throttled' $CG/cpu.stat
# nr_periods 125   nr_throttled 82        → 65.6%
```

**慢是 CPU 不是网络**（集群内 `curl`，绕开 Cloudflare + 隧道）：

| 目标 | 无竞争 | 有 1 个 sharp 任务在跑 |
|------|--------|----------------------|
| `multica-frontend:3000/` | 0.21s | 0.33 / 0.39 / **0.77s** |
| `multica-backend:8080/api/config` | 0.0017s | — |
| `/_next/image?w=1200&q=85` | **2.27s** | — |

`/` 在集群内只要 0.21s，公网那 4.5s 是「首页渲染 + 图片优化抢同一份 500m 配额」的结果。

## 为什么没有告警

三件事叠在一起，各自都是**有意为之**，但合起来是盲区：

1. `monitoring.prometheusRule` 刻意关闭（backend `/metrics` 返回 404，开了就是永不触发的
   规则）——所以没有容器级 OOM/重启告警。
2. Uptime Kuma 那条公网探测看的是可达性；崩循环期间 `/` 始终 200，**探测不会红**。
3. chart **完全没有 probe 配置项**（`helm show values` 里 probe/readiness/liveness 一个都没有），
   所以 frontend 没有 readinessProbe——Kyverno 的 `require-probes` 一直在报
   `PolicyViolation`（audit）。没有 readinessProbe 意味着容器一起来就被派流量，
   重启期间请求直接打到还在启动的实例上。

⚠️ 这三条现在都没改。**这个服务目前只有"域名还通"这一层保障**，容器反复重启是看不见的。

## 教训：这类服务该怎么量

- **突发型负载不能用空载采样定上限。** 判断一个容器是否突发型，看它有没有「按请求分配大块内存」
  的路径：图片/视频转码、PDF 渲染、模板编译、压缩。有就必须**在负载下量**。
- **`memory.peak == memory.max` 是"上限偏小"的判决书**，不是"刚好够"。同理先看
  `memory.events` 的 `max` 计数，它比 `oom_kill` 早得多。
- **上游 chart 的默认值是有信息量的**——厂商按这个镜像的真实负载给的。比它低就得有实测理由，
  而"空载 x3 倍"不算理由。
- 与 [k8s-qos-resource-management.md](../reference/k8s-qos-resource-management.md) 一致：
  CPU 看 `throttled_periods` 比例，内存看 `rssBytes`/cgroup，都别看 `kubectl top`。

## 修复后实测（2026-08-18，1Gi / 1000m）

冷缓存下并发打全部 8 个 srcset 宽度 + 3 个首页请求（比真实流量更凶——浏览器只取
srcset 里的一个变体）：

| 指标 | 修复前（512Mi/500m） | 修复后（1Gi/1000m） |
|------|--------------------|-------------------|
| `memory.peak` | **512Mi 顶死** | **420Mi**（占上限 41%） |
| `memory.events max` / `oom_kill` | 697 / 6 | **0 / 0** |
| 稳态 throttle 比例 | 66% | **23%** |
| 首页 `/`（公网，稳态） | 间歇 4.5s | 0.31–0.55s（一次 3.4s 离群） |
| `/_next/image` 热缓存 | — | 0.51s（冷 2.3s） |

⚠️ **注意 420Mi 这个数**：它已经是旧上限 512Mi 的 82%。也就是说旧值不是"略紧"，而是
基本没有余量——真实流量只要比这次测试再密一点就必然 OOM，这与当晚的现象一致。

## 遗留（已知、未修）

- **突发并发下 CPU 仍会 throttle**：8 路冷缓存优化时 88 个周期里 100→79 个被 throttle（90%），
  首页退化到 3.7–7.4s。没有继续抬 CPU，理由有两条：1000m 已是 chart 上游默认，再往上是拍脑袋；
  且控制面是热笔记本（[homelab-host-power-thermal.md](../reference/homelab-host-power-thermal.md)），
  抬 CPU 有实际热代价。这个代价是**每个 pod 生命周期内每个图片变体只付一次**（之后走磁盘缓存），
  可以接受。
- **`.next/cache/images` 没有持久卷**：pod 每次重启都要重新付冷缓存成本。崩循环期间因此
  症状自我放大。没加 PVC——它会触发 H4（新增 PVC 必须有备份归属），而这只是可重算的缓存。
- **frontend 没有 readinessProbe，且 chart 不提供该配置项**。Kyverno `require-probes` 会一直
  报 audit 违规。要修得等上游 chart 支持。
- **容器级 OOM/重启仍然没有告警**（见上「为什么没有告警」）。这次是靠用户报障发现的。

## 相关

- [reference/k8s-qos-resource-management.md](../reference/k8s-qos-resource-management.md) — QoS / 资源判据
- [reference/cost-and-rightsizing.md](../reference/cost-and-rightsizing.md) — 右尺寸方法
- [runbooks/multica-install.md](../runbooks/multica-install.md) — multica 安装 runbook
- [decisions/cluster-placement-for-new-services.md](../decisions/cluster-placement-for-new-services.md) — 落点判据
