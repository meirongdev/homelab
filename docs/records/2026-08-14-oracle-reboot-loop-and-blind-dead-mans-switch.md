# oracle 每天硬重启，而死人开关在重启窗口里静默失明——查 uptime-kuma 的 5xx 查出来的

> ⚠️ **2026-09-01 更正：本文对「重启本身」的根因判断已被推翻。**
> 不是宿主层硬重置，是**内核 AppArmor 的 AF_UNIX 中介空指针**
> （`unix_fs_perm()` 不检查 `path->mnt` 就解引用）。本文那五条客场阴性结果
> （无 shutdown / 无 panic / 无 OOM / 无 crash dump / EDK II 冷启动）之所以全阴，
> 是因为 `panic_on_oops=1` 让机器在 journald 落盘前就重启了 —— 那恰恰是
> **guest 内核 panic 的标准形态**，不是宿主层的证据。真凭据在 hypervisor 侧的
> `oci compute console-history` 里（10 次 panic，签名 10/10 一致）。
> **下面关于死人开关失明的部分依然成立**，只有「重启本身」那条根因作废。
> → [2026-09-01 复盘](2026-09-01-oracle-apparmor-af-unix-panic.md)

> 日期: 2026-08-14
> 影响: oracle-k3s **6 天硬重启 6 次**（每次全集群 pod 中断 6~10 分钟）；
>       每次重启期间 homelab 的 Watchdog 心跳推不进 oracle 的 Uptime Kuma，
>       **死人开关在这段窗口内完全失明且不留痕迹**——实测 9分40秒缺口、
>       `important` 翻转 **0** 条。若 homelab 在该窗口内挂掉，无人会知道。
> 根因: ~~重启本身在 **OCI 宿主层**，客场证据已用尽。~~ **（已推翻，见文首横幅：
>       真因是内核 AppArmor `unix_fs_perm()` 空指针，证据在 OCI console history）**
>       失明则是设计前提没覆盖："死人开关是自检的"只在**接收侧活着**时成立——
>       push monitor 的检查跑在 uptime-kuma 进程内，它自己下线就没人检查。
> 结果: 新增 `NodeRebootLoop` + `DeadMansSwitchReceiverDown` 两条告警；
>       修正 3 处已被证伪/过期的注释与判断（含前一天刚写的 SLO ADR）。
> 触发: 追查 SLO ADR 里"uptime-kuma 错误率 1.376%"这个反常数字——
>       **而那个数字本身是读错的**，见下。

## 一句话根因

**oracle 每天被宿主层硬重置一次，把接收方和发送方一起打掉；
而死人开关的自检兜底恰好只能检测"发送方挂了"这一种。**

## 起点：一个被读错的数字

前一天的 [SLO ADR](../decisions/slo-availability-targets.md) 记了一条"反向缺口"：
uptime-kuma 5 天 134 个 5xx、错误率 1.376%，是全舰队唯一有稳定真实错误率的对外服务，
按判据最该补一条 SLO。**三点全错**：

| 初稿判断 | 实测 |
|---|---|
| 稳定 1.376% 错误率 | **6 段突发**，与 6 次节点重启逐一对齐；平时是 0 |
| 第二大真实流量后端（9742/5d） | 其中 ~9435 是**死人开关心跳**（`repeatInterval: 30s`，实测 ~45s/条，08-13 全天 1887 条），人访问只有 ~307 |
| 应该建 SLO | 不该。比率型 SLI 会把"每天 10 分钟全失败"稀释成温和的月度百分比，而真正要答的是「此刻这条链路通不通」 |

> **教训一**：`increase(...[5d])` 出来的一个百分比，读之前先看它的**时间分布**。
> 突发型故障摊平成比率后，看起来像"轻微但持续的劣化"，两者的处置完全不同。

## 时间线（2026-08-13 那次，UTC）

```
17:18:26  最后一条 Watchdog 心跳落库
17:21     oracle 节点硬重启（node_boot_time_seconds 跳变）
17:24:20  uptime-kuma 容器 terminated：exitCode 255 / reason "Unknown"
          —— 日志在 14:52 就静默了，中间 2.5h 无输出，死前无任何征兆
17:25:03  coredns 一并重建（佐证是节点级而非应用级）
17:26     网关对 uptime-kuma 的 5xx 峰值：单分钟 14 个（含 Alertmanager 重试放大）
17:26:29  容器重新启动
17:28:06  心跳恢复 —— 缺口 9 分 40 秒
```

同期 `alertmanager_notifications_failed_total{integration="webhook"}` 在 17:26 那个小时
涨了 26。**这是唯一从发送侧看得见失明的信号，而当时没有任何规则在看它。**

## 三个被推翻的判断

### 1. "死人开关是自检的" —— 只覆盖一半

`alertmanager-config.yaml` 把 `AlertmanagerFailedToSendAlerts{integration=webhook}`
路由到 null，理由（2026-08-09 写）是：

> 心跳停 → oracle 的 Uptime Kuma push monitor(60s interval) 转 DOWN
> → 它自己从 oracle 直连 Telegram 报警，完全不依赖 homelab。

该推理**只在「发送侧或链路坏、接收侧活着」时成立**。查库实证：

```
$ sqlite3 /app/data/kuma.db "SELECT time,status FROM heartbeat WHERE monitor_id=1
    AND time BETWEEN '2026-08-13 17:15' AND '2026-08-13 17:35' ORDER BY time;"
17:18:26|1     ← 最后一条
17:28:06|1     ← 下一条，中间空了 9分40秒
$ sqlite3 ... "SELECT count(*) FROM heartbeat WHERE monitor_id=1
    AND important=1 AND time LIKE '2026-08-13%';"
0              ← 当天零次状态翻转
```

interval 是 60s，缺口 580s，**却没转 DOWN**。因为检查逻辑跑在 uptime-kuma 进程内，
它自己下线就没人做检查；重启回来 ~45s 内新推送已到，看上去"一直 UP"。

反证这不是 monitor 坏了：库里 08-08 与 08-10 各有正常的 DOWN→UP 翻转
（那几次是链路/发送侧问题、接收侧活着），机制本身没问题。

> **教训二**：2026-08-09 的验证做的是「配置正确 + 正在收心跳」，
> **没有做「制造一个真实缺口、看它会不会转 DOWN」**。
> 安全网只能用**触发它**来验证，查配置查不出这类前提缺口。

### 2. "NodeRebooted 没覆盖到" —— 覆盖了，响了 21 次

一开始怀疑是告警盲区。实测 `ALERTS{alertname="NodeRebooted"}` 在 08-10~08-13
对 oracle 有 **21 个 firing 样本**，Telegram 也确实发了。

所以这次**不是缺信号，是缺模式**：逐次告警读不出"这台机在反复重启"。
更早的证据也在仓库里——2026-08-09 加 NodeRebooted 时，注释里记的就已经是
"oracle 5 天重启 5 次，其中三次没有对应的 shutdown 记录"。
到 2026-08-14 复查是 **6 天 6 次**，即这条慢性故障已持续 **9 天以上**，
每次只留一条 warning 混在日常噪声里，从没被当成一件事看。

> 与 2026-08-13 的 V4-Flash 事故（实录在 `prometheus-rules.yaml` 的
> `dgx-spark-inference` 组注释里）那类"告警响过却没人动"同型：
> 可操作性与**聚合视角**比多加一条规则更重要。

### 3. "journald 是 volatile，事后无法复盘" —— 早已持久化

`NodeRebooted` 的 description 写着 oracle 的 journald 是 volatile、上次启动的日志
重启就没了，并给了一串启用持久化的命令。**实测 `/var/log/journal` 已存在**，
`journalctl --list-boots` 能看到 6 个历史 boot，`-b -1` 读得到崩溃现场。
过期的排障指引比没有更糟——它会让人以为证据不存在而放弃查。

## 重启本身：客场证据已用尽 ⚠️ 结论已作废（2026-09-01）

> 下面五条实测都属实，但**推论错了**：它们是 guest panic 后 journald 来不及落盘的
> 表现，不是宿主层重置的证据。正确根因见 [2026-09-01 复盘](2026-09-01-oracle-apparmor-af-unix-panic.md)。

```
$ last -x reboot                       # 6 次，全部同一内核版本，全部无 shutdown 记录
$ journalctl -b -1 -n 25               # 末行是正常业务日志，戛然而止，无关机序列
$ journalctl -b -1 | grep -iE "panic|oom|hung task|soft lockup"   # 无
$ ls /var/crash/                       # 空
$ journalctl -b 0 | head               # 每次都从 EDK II / BOCHS 固件冷启动
$ cat /proc/pressure/cpu               # some avg300=13.1，未见异常
$ free -m                              # available 4855MB，未见压力
```

内核版本 6 次重启全程未变，`Unattended-Upgrade::Automatic-Reboot` 全是注释状态
（未启用）→ **不是内核升级链**。无 panic、无 OOM、无 crash dump、无干净关机
→ **宿主层硬重置**。重启间隔无周期性（22.4h / 4.6h / 53.6h / 11.6h / 5.1h），
不像定时任务。客场只剩韧性可做，根因要去 OCI 控制台查该实例的 Work Requests / 维护事件。

顺带记录一个恢复期的放大因素：重启后 pod 集中重建时，
cilium-cni 会返回 `[PUT /endpoint/{id}][429] putEndpointIdTooManyRequests`，
形成 endpoint 创建风暴、拉长恢复时间（08-13 20:22 那批可查）。本次未处理。

## 修复

**新增两条告警**（`k8s/helm/manifests/monitoring/alerts/prometheus-rules.yaml`）：

```promql
# NodeRebootLoop — 补"模式"视角，逐次告警读不出反复重启
changes(node_boot_time_seconds{job=~"node-exporter|node-exporter-metal-nodes|node-exporter-dgx-spark"}[24h]) >= 3

# DeadMansSwitchReceiverDown — 从发送侧看见失明窗口
increase(alertmanager_notifications_failed_total{integration="webhook"}[5m]) >= 5
```

⚠️ 后者的阈值**按仓库规矩对线上 5 天数据两向实测**过：

| 应触发 | 结果 |
|---|---|
| 5 次硬重启（08-10 14:22 / 19:00、08-13 00:39 / 12:18 / 17:22 UTC） | **全部命中**，条件真实持续 9.5~11 分钟（30s 步长实测），`for: 5m` 稳过 |

| 不应触发 | 结果 |
|---|---|
| 08-10 04:26 的 9 次/时、08-11 03:26 的 5 次/时、08-12 16:26 的 2 次/时、08-13 18:26 的 7 次/时 | **一律不触发** |

这一点很关键：2026-08-09 之所以把这类告警整个静默掉，正是因为当时用的是
**1.6% 失败率**这种比率阈值，被链路抖动打满。改成"5 分钟内全量失败"后，
抖动与"接收方真的没了"就分得开了，所以**那条 null 路由保持不变**，两者不冲突
（alertname 不同，不会被一并丢弃）。

**修正 3 处文本**：

- `NodeRebooted` 的 journald 说明（已过期 → 改成实际可用的 `journalctl -b -1 -n 25`，
  并写明"末行是正常日志且无 shutdown 序列 = 宿主层硬重置，客场查不出更多"）
- `alertmanager-config.yaml` 的"自检兜底"论证（补上本次反例与适用边界，不删原判断）
- [SLO ADR](../decisions/slo-availability-targets.md)：改掉被推翻的 uptime-kuma 判断，
  并给 D2 判据补第三类——**承载性机器流量**（错误有后果，但该用定向告警而非 SLO）

## 遗留（刻意不做）

- ~~**根因修不了**。宿主层重置只能从 OCI 侧查~~ —— **2026-09-01 更正**：方向是对的，
  但只查了维护事件（阴性）就停了；真证据在同一个 API 的 console history 里。
  根因已定位（内核 AppArmor bug，上游未修），已设 `panic_on_oops=0` 止血。
- **失明窗口仍然存在**。两条新告警只让它**可见**，没有消除它：接收端仍是单点，
  oracle 一重启死人开关必然瞎几分钟。彻底解决要第二个独立接收端
  （如外部 healthchecks.io），那会引入新的外部依赖与密钥，**本次不做**——
  先让它可见，观察新告警的信噪比再决定是否值得。
- **cilium-cni 429 endpoint 风暴**未处理（只拉长恢复时间，不改变结果）。

## 教训

- **突发中断被比率型指标稀释后会伪装成"轻微持续劣化"**。看到异常百分比，
  先看时间分布再下判断——这次差点因此给一个不该有 SLO 的服务建 SLO。
- **安全网只能靠触发来验证**。"配置正确 + 正在工作"证明不了"故障时会响"；
  这次和 2026-08-12 的 NaN 面板是同一类：**兜底路径缺少针对自身的检验**。
- **逐次告警 ≠ 模式可见**。信号在、也送达了，但 9 天里没人把 6 条孤立 warning
  连成"这台机坏了"。做告警时要问一句：**它需要被聚合才有意义吗？**
- **过期的排障指引比没有更糟**。它让人以为证据不存在，直接放弃排查。
