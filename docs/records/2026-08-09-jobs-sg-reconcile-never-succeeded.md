# jobs-sg 全量 reconcile 从来没成功过：2770 条过期岗位一条没关

> 日期: 2026-08-09（`JobsSgIngestStale` 06:49Z 触发；18:18Z 手工补跑；上游 `4af8944`、`4b91fe8`
>       于 08-10 修复）
> 影响: `JobsSgIngestStale` 告警，而那轮数据其实已完全刷新；上线以来关闭流程一次没跑过，11580 条
>       岗位 `closed_at` 全为 NULL，其中 2770 条早已过 `expiry_date`，在架数与岗位寿命口径失真
> 根因: ① 偏差拿全程峰值 `max(page.Total)` 比逐页累加的 scanned，量纲不对；② 偏差高时连按
>       `expiry_date` 的关闭也一起停；③ 跳闸算进 `errors++`，整轮标 partial，不盖新鲜戳
> 处置: `Total` 改取最后一页读数、另存 min/max；闸门改读覆盖率 ≥ 80%，偏差降为纯遥测；按
>       `expiry_date` 关闭不再门控；干净的对账轮照常盖 incremental 新鲜戳；手工 `--reconcile`
>       一次关闭 2738 条。现状见 [reference/jobs-sg.md](../reference/jobs-sg.md)

## 经过

那轮数据其实完全刷新了（856 页 / scanned 85487 / new 81 / updated 8977），是被判定逻辑标成
partial 的，所以排查方向不该从「抓取停了」开始。

症状：`jobs_sg_last_success_timestamp_seconds{kind="full_reconcile"}` 这条 series 从来不存在；
`ingest_run` 全表只有一次 reconcile（08-08，partial）。关闭流程一次都没跑过（前一天的诊断见
[plans/2026-08-08-jobs-sg-three-defect-diagnosis.md](../plans/2026-08-08-jobs-sg-three-defect-diagnosis.md)
§1：`closed` 恒为 0 是因为只有周日那轮关岗位）。

告警时间点对得上到秒，可以当排查模板：最后一次 incremental 成功 `08-07T18:19:53Z` + 36h =
`08-09T06:19:53Z` + `for: 30m` = `08-09T06:49:53Z`，实际 `startsAt` = `08-09T06:49:57Z`
（差 4s 是抓取间隔对齐）。

## 三个根因

1. **偏差拿峰值比累加和**（真正的 bug）。`mcf.Summary.Total` 取全程 `max(page.Total)`，而
   `Jobs` 是逐页累加；扫描要 25 分钟，`total` 在底下一直动，任何瞬时抬升都被永久固化。那轮
   算出 `dev=4.5%`（85487 vs 早已回落的 89531），≥ 2% 阈值，拒绝关闭。平静时段实测 MCF 的
   `total` 精确可信：page 864 满 100 条、page 865 剩 10 条、page 866 空，865×100+10 = 86510 =
   `total`，且 100 秒采样纹丝不动。所以那 4.5% 不是常态。
2. **偏差高时把到期关闭也一起停了**。`expiry_date` 是 MCF 自己公布的下架日期，不是从「没见到」
   推断出来的，本就不该受扫描完整度门控。
3. **跳闸算进了 `errors++`**，污染 `jobs_sg_ingest_errors_total`（那条告警的语义是「MCF 字段
   形状变了」），让谨慎但健康的一晚和真坏了的一晚长得一样。

## 补救

08-09 18:18Z 手工 `--reconcile`，24 分钟：`full_reconcile` 第一次 `status=success`，关闭
2738 条，`errors=0`、`close_skipped=false`，`scanned=82987 / total_reported=82987`。库里
11645 条 → closed 2738 / open 8907；仍开着但已过期的从 2770 降到 21（这 21 条本轮见到了，
「在架」压过「过期日」，是设计要的行为）；114 条未见但未到期只记 `miss_count=1`。
`JobsSgIngestStale` 随即消失。

但这一轮证明不了修复是必需的：那晚 `total_max=83003`、最终 82987，按旧代码算偏差只有
0.019%，照样能过闸。真正值钱的读数是 `total_min=75255`：同一次扫描里 total 在
75255↔83003（约 9.3% 带宽）之间摆。旧实现会不会被咬，取决于峰值落在最终值之上多少：08-08
落在上面（89531 vs 85487）就炸了，这晚差 16 就没炸。修复消掉的是这枚硬币，不是某一次具体的
数值。

## 残留风险的收敛（08-10 晚，`4b91fe8`）

修完第一版后还剩「向下凹陷落在最后一页仍会反向误跳」。当时设想用「翻到空页」判，但这个判据对
这个闸门恒真：对账从不早停，干净扫描的唯一出口就是空页，熔断和页错误早已进 partial。真正剩下
的威胁只有「API 中途假空页截断板子」，探测器是覆盖率 `scanned / max(total)`，下限刻意放宽到
80%：total 噪声带实测 ±10%，而真截断是断崖式的；放过去的零头落进 `miss_count` 两周判定 +
reopen 自愈。偏差降为纯遥测（`deviation_ratio` 保留），新增
`jobs_sg_reconcile_scan_coverage_ratio` 暴露闸门的真实输入。

同批第二处：干净扫描的对账轮（errors=0，含 close_skipped）照常盖 incremental 新鲜戳
（`store.LastSuccess` 特例），`full_reconcile` 的戳仍扣住。两条告警从此解耦：
`JobsSgIngestStale` 管数据新不新，`JobsSgReconcileStale` 管生命周期对没对账。

以前证据只在一行容器日志里，事后只能上节点翻 gzip。同批给 `ingest_run` 加了 `jobs_scanned` /
`total_reported` / `total_min` / `total_max` / `close_skipped`，指标加了
`jobs_sg_reconcile_scan_deviation_ratio` 与 `jobs_sg_reconcile_close_skipped_total`。
