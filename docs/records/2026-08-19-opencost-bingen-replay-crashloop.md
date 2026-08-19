# opencost 启动重放超出探针预算：节点重启后崩溃循环 24 小时

> 日期: 2026-08-19（故障始于 2026-08-18 15:04 UTC，节点重启后 5 分钟）
> 影响: oracle-k3s 节点 CPU 从日常 ~34% 升至 65–95% 并持续 24 小时，其中 opencost
>       一个容器占约 1.1 核（节点共 2 核），每轮重启额外产生约 4.3GB 磁盘读；
>       oracle 集群成本采样中断；累计重启 253 次、探针失败 7,578 次
> 根因: collector 模式把每次采样写成一个 ~250KB 的 .bingen 文件（WAL），存在 emptyDir
>       里，保留窗口等于最长一档 retention（当时配置 retention1d: 15，即保留 15 天）。
>       启动时必须把窗口内全部文件重放完才监听 :9003。9 天累计 23,950 个文件（5.5GB），
>       重放需约 3 分 43 秒，超过 startupProbe 预算（160 秒 + 30 秒宽限），
>       因此每次启动都被杀掉重来
> 结果: 调整采样间隔与保留窗口、提高探针预算、删除未使用的 PVC（commit d04593b）。
>       两集群已恢复：新 pod 启动 1.4 秒完成，opencost CPU 降至 0.6%

## 根因概述

opencost 的 collector 数据源用 WAL 文件在重启后重建内存中的统计数据。重放是启动的
前置步骤：重放完成前 HTTP 服务不启动，/healthz 无法应答。重放时长随保留窗口内的
文件数线性增长，而 startupProbe 的预算是固定的。配置 `retention1d: 15` 后，只要
累积超过约 7 天就会出现"重放时长 > 探针预算"。进程持续运行时只做增量写入、不冷启动，
所以问题在 8 月 10 日部署后一直没有暴露，直到 8 月 18 日节点重启才触发。

## 机制（依据 opencost 1.121.0 源码）

关键文件 `modules/collector-source/pkg/metric/walinator.go`：

- 每次采样调用 `Export()`，写一个 `.bingen` 文件到
  `CONFIG_PATH/Opencost/<cluster>/collector/`。文件约 250KB，大小取决于集群规模，
  与采样间隔无关。
- `CONFIG_PATH` 由 chart 的 `customPricing.configPath` 决定（默认 `/tmp/custom-config`），
  chart 在该路径挂载的是 **emptyDir，且没有 sizeLimit**。`storefactory.go` 的
  `GetConfiguredStorage()` 确认 WAL 根目录就是这个路径。
- `Start()` 的顺序是：`clean()` → `restore()`（重放窗口内全部文件）→ 周期性 `clean()`。
  清理界限取三档 retention 中窗口最长的一档，即 `retention1d`。
- 重放完成前不监听 :9003，startupProbe 对 /healthz 的探测始终 connection refused，
  到达 failureThreshold 后 kubelet 杀掉容器，下一次启动从第一个文件重新开始。

另外两点与本次故障相关：

- chart 的 `persistence`（PVC）挂载在 `/mnt/export`，那是 CSV 导出目录，与 WAL 路径
  无关。我们配置的 2Gi PVC 从 2026-07-30 创建到删除始终是 0 字节。08-16 的一次检查
  已发现 PVC 为空，但当时的结论"rollup 在进程内存里"不完整——数据在 emptyDir 的 WAL 里。
- homelab 集群配置相同，pod 于 08-16 重建（emptyDir 清空），到 08-19 已重新累积
  8,537 个文件（1.9GB）。当时未出问题只是因为积累时间短，重放仍在预算内。

## 时间线

| 时刻 (UTC) | 事件 | 依据 |
|---|---|---|
| 08-10 06:18 | pod 创建，WAL 开始累积（每天 2,880 个，与 30s 采样间隔一致） | 文件名清单 |
| 08-18 14:58:00 | 最后一个 .bingen 写入（重启前 72 秒） | 文件 mtime |
| 08-18 14:59:12 | 节点重启 | `node_boot_time_seconds` |
| 08-18 15:04:16 | 第一次冷启动，此后持续崩溃循环 | pod containerStatuses |
| 08-19 15:08 | 实测：启动后 152 秒重放到第 ~16,342/23,950 个文件（68%），推算全量需 3 分 43 秒 | fdinfo 采样 |
| 08-19 15:27 | 修复 rollout，新 pod 启动 1.4 秒完成 | 容器日志 |

## 证据与排除项

- 每轮容器存活恰好 3 分 05 秒、exit code 137：与 `initialDelay 10s + 30×5s = 160s`
  加终止宽限 30s 一致。
- `/proc/PID/io`：启动 45 秒内 read() 4.46GB，其中真实块设备读 4.03GB，约 20 万次
  read 调用——这是"重放大量文件"的直接证据。
- 排除 OOM：内存峰值 330Mi，limit 512Mi；`node_vmstat_oom_kill` 24h 为 0。
- 排除网络问题：进程只有 1 条到 apiserver 的正常连接，无重试风暴。
- 排除 Prometheus 依赖：collector 模式不查询 Prometheus，env 中的
  `PROMETHEUS_SERVER_ENDPOINT` 是 chart 无条件写入的默认值，此模式下不使用。

## 修复与验证（commit d04593b，两集群相同）

| 配置 | 旧值 → 新值 | 说明 |
|---|---|---|
| `scrapeInterval` | 30s → 2m | 文件量降为 1/4（720 个/天）；10m 一档 rollup 每桶仍有 5 个样本 |
| `retention1d` | 15 → 7 | 即 WAL 重放窗口。稳态约 5,040 个文件 / 1.2GB，重放约 50 秒 |
| `startupProbe.failureThreshold` | 30 → 120 | 预算 10 分钟，约为稳态重放时长的 12 倍；只影响启动阶段 |
| `persistence` | 2Gi PVC → 删除 | 挂载点与 WAL 无关，始终为空 |

已接受的代价：pod 重建时 emptyDir 清空，成本历史归零。本次 rollout 丢弃了 oracle
的 9 天历史（它保存在无法启动的 pod 里，实际上已不可读取）。

验证结果（2026-08-19 15:27 rollout 后实测）：

- 两集群新 pod 2/2 Running、0 重启；oracle 新 pod 从进程启动到
  `HTTP server starting on port 9003` 用时 1.4 秒。
- 部署中的 env 与探针确认为 2m / 7 / failureThreshold 120。
- 两集群的 opencost PVC 已被 ArgoCD prune。
- opencost CPU 从 ~55%（1.1/2 核）降至 0.6%；节点 CPU 从 65–95% 回落至 ~44%
  并继续向日常水平收敛。

## 遗留事项

1. **WAL 未持久化**：跨 pod 重建保留成本历史需要把 `customPricing.configPath` 指向
   持久卷。注意 chart 会在 configPath 挂载 emptyDir，嵌套挂载会遮蔽持久卷的同名路径，
   只改 values 可能"渲染成功但数据仍写进 emptyDir"。如果以后做，必须登节点确认实际
   挂载结果。
2. **KubePodCrashLooping 无法覆盖这类故障**：容器每轮有约 3.5 分钟处于 Running，
   `kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}` 序列随之中断，
   `for: 15m` 计时器被重置。实测该表达式最长连续成立 9.5 分钟，达不到 15 分钟。
   本次未修改 mixin 规则；实际起到通知作用的是 KubePodNotReady（持续触发 23.5 小时）。
   同类问题（短窗口配长 for）见 2026-08-12-slo-nan-poisoning.md。

## 附：distroless 容器的取证方法

opencost 镜像无 shell，无法 exec；HTTP 服务未启动，也没有 pprof。本次使用的只读手法：

1. `kubectl -n kube-system debug node/<node> --profile=sysadmin` 建调试 pod。
   注意默认 namespace 会被 PSA baseline 拒绝，kube-system 是 privileged。
2. 用 `crictl inspect --template '{{.info.pid}}' <containerID>` 取宿主机 PID。
3. 读 `/proc/PID/io` 判断 I/O 类型（rchar / read_bytes 区分缓存读与真实块读）；
   循环采样 `/proc/PID/fd` 与 `fdinfo` 的 pos，捕捉短生命周期 fd 指向的文件。
4. 教训：cAdvisor 没有 `container_fs_reads_*` 序列不代表没有磁盘 I/O（本次一度因此
   排除了重放假设）。`/proc/PID/io` 才是可靠依据。
