# opencost 启动重放 5.5GB WAL 超出探针预算 → 节点重启后永久崩循环，烧掉 oracle 1.1/2 核 24h

> 日期: 2026-08-19（故障始于 2026-08-18 15:04，节点重启后 5 分钟）
> 影响: oracle-k3s 全节点 CPU 65%→90%+ 持续 24h（opencost 一个 pod 占 1.1/2 核 +
>       每轮冷读 4.3GB 把页缓存打穿，节点持续 ~15MB/s 盘读）；oracle 成本采样断流；
>       253 次重启、7,578 次探针失败。KubePodNotReady 有响但没人把它读成崩循环
> 根因: collector 模式每 30s 写一个 ~250KB 的 .bingen WAL 到 emptyDir，清理线 =
>       最长 retention（我们配了 retention1d: 15 → 保 15 天）；启动时**全量重放完才
>       bind :9003**。9 天积压 23,950 个/5.5GB → 重放需 3m43s，探针预算只有
>       160s+30s 宽限 → 每轮杀在 ~70%，从头再来
> 结果: scrapeInterval 30s→2m、retention1d 15→7、startupProbe failureThreshold
>       30→120，撤掉从未被写过的 2Gi PVC；两集群同改

## 一句话根因

**opencost collector 的 WAL 重放是启动的硬前置（重放完才起 HTTP server），而重放时长
随 retention 窗口线性增长、探针预算是常数——参数把两条线配成了必然相交。**
节点重启只是扣扳机：进程活着时增量消化，从不冷启动，问题蛰伏 9 天。

## 机制（源码核实，opencost 1.121.0）

`modules/collector-source/pkg/metric/walinator.go`：

- 每次 scrape `Export()` 一个 `.bingen`（UpdateSet 快照，~250KB，与集群规模相关、
  与 scrape 间隔无关）到 `CONFIG_PATH/Opencost/<cluster>/collector/`。
- `CONFIG_PATH` 来自 `customPricing.configPath`（默认 `/tmp/custom-config`），chart 给它
  挂的是 **emptyDir、无 sizeLimit**。`core/pkg/storage/storefactory.go GetConfiguredStorage()`
  确认 WAL 根目录就是这里。
- `Start()` = `clean()` → `restore()`（并发全量重放窗口内所有文件）→ 周期 `clean()`。
  清理线 `limitResolution` 取三档 retention 里**窗口最长**的一档 = `retention1d`。
- **重放完成前 :9003 不 bind** → startupProbe（160s + 30s 宽限）对 /healthz 永远
  connection refused → SIGKILL → 下一轮从第 1 个文件重来。

## 时间线与证据

| 时刻 (UTC) | 事实 | 证据 |
|---|---|---|
| 08-10 06:18 | pod 创建，WAL 开始堆积（每天恰好 2880 个） | 文件名清单 |
| 08-18 14:58:00 | 最后一个 .bingen（重启前 72s） | 文件 mtime |
| 08-18 14:59:12 | 节点重启 | `node_boot_time_seconds` |
| 08-18 15:04:16 | 首轮冷启动，从此崩循环 | pod containerStatuses |
| 08-19 15:08 | 实测：启动 152s 时重放到第 ~16,342/23,950 个（68%）→ 全量需 3m43s | fdinfo 采样 |

- 每轮精确活 3m05s、exit 137：`initialDelay 10 + 30×5s = 160s` + 30s 宽限，分毫吻合。
- `/proc/PID/io`：启动 45s 已 read() 4.46GB（真实块读 4.03GB，20 万次 read）。
- 排除项（都实测过）：不是 OOM（峰值 330Mi/512Mi、`node_vmstat_oom_kill`=0）、
  不是网络（仅 1 条 apiserver 连接）、不是 Prometheus 缺失（collector 模式不用它）。
- homelab 同款炸弹引线更长：pod 08-16 重建（emptyDir 当时清零），到 08-19 已重新积
  8,537 个/1.9GB。它当时"健康"只因为引线刚点。

## 取证手法（distroless 容器、发不了 SIGQUIT 时）

1. `kubectl -n kube-system debug node/<node> --profile=sysadmin`（**默认 ns 会被 PSA
   baseline 拒**，kube-system 是 privileged）。
2. `crictl inspect --template '{{.info.pid}}' <containerID>` 拿宿主 PID。
3. `/proc/PID/io` 定性（rchar/read_bytes 判盘读）；循环采样 `/proc/PID/fd` +
   `fdinfo pos` 抓短命 fd 指向的文件。
   ⚠️ **cAdvisor 没有 `container_fs_reads_*` 序列 ≠ 没有磁盘 I/O**——本次一度因此
   错误排除了重放假设，`/proc/PID/io` 才是地面真相。

## 修复（两集群同改，values 即文档）

- `scrapeInterval: 30s → 2m`：文件量 ÷4。成本归因不需要 30s 粒度，10m rollup 每桶仍 5 样本。
- `retention1d: 15 → 7`：WAL 窗口减半。稳态 ≈ 5,040 个/1.2GB，重放 ≈50s。
- `startupProbe.failureThreshold: 30 → 120`（10min）：预算 ≈ 12× 稳态重放时长。
- 撤 `persistence`（2Gi PVC）：挂在 /mnt/export（CSV 导出目录），与 WAL 无关，
  自 07-30 建起始终 0 字节。
- 代价（已接受）：pod 重建 = emptyDir 清零 = 成本历史归零。oracle 的 9 天历史在
  本次修复 rollout 时丢弃（它锁死在打不开的 pod 里，本来就取不出了）。

## 未做项

- **WAL 持久化**：把 `customPricing.configPath` 指到持久卷理论上可行（WAL 根随它走），
  但 chart 会把 emptyDir 挂到 configPath——嵌套挂载会**遮蔽**持久卷同路径，只改 values
  大概率"看起来成功、实际还在 emptyDir"。要做必须实测挂载结果，别信渲染。
- **KubePodCrashLooping 对本故障结构性失明**：容器每轮有 ~3.5min Running，
  `waiting_reason{CrashLoopBackOff}` 序列断流，`for: 15m` 计时器被重置——实测最长连续
  9.5min，永远到不了 15m。同类坑见 records/2026-08-12-slo-nan-poisoning.md 的"短窗口
  配长 for"。本次没改 mixin 规则，值守靠 KubePodNotReady（它响了 23.5h）。
