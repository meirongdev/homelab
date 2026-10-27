# Grafana 与 Prometheus 在 NFS 上 CrashLoop：sqlite 锁与 TSDB 重放卡死

> 日期: 2026-07-04（当天修复；Grafana 此前已 CrashLoop 8 天）
> 影响: Grafana 连续 CrashLoop 8 天，仪表盘不可用；Prometheus 重启后 CrashLoop，TSDB 历史数据放弃
> 根因: 两者的 PVC 都在 `nfs-client`（106 的 NFS）上。Grafana 的 sqlite 走 `fcntl` 字节锁 + 同步小写，
>       NFS 的 NLM 锁让一次 DB 写阻塞分钟级，叠加启动期对 grafana.com 的联网调用，拖过 160s 的
>       liveness；Prometheus 重启时 head/WAL 读挂在僵死的 NFS client 上，拖过 operator 的启动窗口
> 处置: 两者的 PVC 改 `local-path`；Grafana 放宽 liveness、关掉启动期插件联网；Prometheus 走
>       paused CR 重建 StatefulSet

## 经过

**Grafana。**每次启动都卡在 "Loading plugins..."（写插件状态到 DB）约 159s、零日志，随后被
liveness 探针 kill，形成自维持的 CrashLoop，持续 8 天。默认 liveness 窗口是
initialDelay 60 + failureThreshold 10 × period 10 = 160s。同一条 DB migration 在 NFS 上跑了
3m48s、下一步又挂 9 分钟以上，本地盘上是毫秒级。

另一半原因在网络：Grafana 13 启动时会对随镜像装好的 4 个 app 插件做 preinstall 与更新检查，
要连 grafana.com。pod 内 grafana.com 只解析到 IPv6，集群没有 IPv6 出网，dial 长时间挂起。

**Prometheus（同日）。**TSDB 在 `nfs-client` 上。重启时 head/WAL 的读请求挂在僵死的 NFS
client 上，线程 `D` 状态、零进展，与 operator 约 900s 的 startup probe 竞态，进入 CrashLoop。

## 修复

- Grafana（`k8s/helm/values/kube-prometheus-stack.yaml`，注释里有完整现象）：
  - `grafana.persistence.storageClassName: local-path`
  - liveness 放宽到 initialDelay 120 + 30 × period 15，约 570s 宽限（chart 不暴露 startupProbe）
  - `grafana.ini` 的 `plugins.check_for_plugin_updates: false` + `preinstall_disabled: true`，
    启动不再联网
- Prometheus：operator 管的 StatefulSet 改 SC 会碰上 `volumeClaimTemplate` 不可变，流程是
  Prometheus CR `spec.paused: true` → 强删卡住的 pod → 删 STS + 旧 PVC → unpause →
  operator 用新 SC 重建。历史数据放弃（metrics 是 P2，可弃）。
  `maximumStartupDurationSeconds: 1800` 留作无害兜底。

## 教训

- NFS 有两种死法：sqlite / PG 的 lock + fsync 模式慢到分钟级；客户端僵死时，任何启动要读盘的
  服务都会挂在 `D` 状态。大顺序写（Loki chunk 类）对前一种耐受度高得多。
- 数天后 106 宕机 3 天（07-08→07-11），NFS 随即整体退出读写路径。现行约束见
  [reference/storage.md](../reference/storage.md)。
