# Trivy 扫描队列静默停摆：Complete 的扫描 Job 占着并发槽，oracle 首扫停在 7/46

> 日期: 2026-08-03（oracle 首次部署 trivy-operator 当天；修复提交 `a499efd`，08:21 +08）
> 影响: oracle 46 个工作负载只产出 7 份漏洞报告（覆盖约 15%），`trivy_image_vulnerabilities{cluster="oracle-k3s"}`
>       恒为 0 的假阴性，没有任何告警。homelab 29 个工作负载对着 24 次/天的扫描上限已经顶格，
>       再加几个负载就会出现"报告先过期、轮不上重扫"的盲区
> 根因: Complete 状态的扫描 Job 在被 `scanJobTTL` 回收前一直占着 `scanJobsConcurrentLimit` 的槽，
>       吞吐上限 = limit ÷ TTL。两集群当时都是 `TTL=1h`：homelab（limit 1）1 个镜像/小时，
>       oracle（limit 2）2 个镜像/小时，46 个负载要 23 小时扫完
> 处置: 两集群 `scanJobTTL` 1h → 5m；`scanJobsConcurrentLimit` 不动（散热约束由它独立保证，与 TTL 正交）

## 经过

- oracle 首次部署后扫描停在 7/46：没有活动 Job、没有报错，operator 日志 45 分钟一行不出。
- 先怀疑并发不够。oracle 那份 values 当初把 limit 从 1 抬到 2 时，注释写着能"顺带缓解滞留 Job 占槽"；
  实测证否：滞留的 Complete Job 一样占满 2 个槽，抬并发只是把停摆门槛从 1 个滞留抬到 2 个。
- 查到是 Complete Job 占槽后，按 limit ÷ TTL 算两边吞吐，homelab 同样已经没有余量
  （叠加报告 24h TTL，过期的报告要排队重扫）。
- 两集群 TTL 改 5m，同一提交更正了 oracle values 文件头 §2 的错误说法。

## 为什么没有告警

`TrivyImageCriticalVulnerabilities` 只数现存报告里的 Critical，`TrivyOperatorMetricsAbsent` 只在序列
整体消失时才响。覆盖率塌到 15% 两头都不占：缺报告按 0 计入，"漏扫"与"已清零"外观一致。

## 教训

- `scanJobTTL` 不只是清理时间，它决定扫描吞吐。两份 values 都写了"别改回 1h"。
- 改它有两段延迟：env 来自 `configMapRef`，要 operator 重启（chart 的 `checksum/config` 注解让 ArgoCD
  同步时自动滚动）；`ttlSecondsAfterFinished` 在 Job 创建时写入，旧 Job 按旧 TTL 滞留，回收完吞吐才提上来。
- 代价可接受：失败的 Job 也在 5m 内回收，但 trivy-operator 会把扫描容器的报错原文抄进自己的日志。
- 判据是报告数 vs 工作负载数，不是告警。体检命令见
  [reference/trivy-cve-ops.md](../reference/trivy-cve-ops.md)。
