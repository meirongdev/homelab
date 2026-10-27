# jobs-sg /daily 天天 partial：增量早停是死代码，零命中岗位永留积压

> 日期: 2026-08-05（影响 08-03~05 三天；上游 `ff5e24e` 修复）
> 影响: 上线后头三天 `/daily` 日状态全是 `partial`；每晚 ingest 扫满 300 页熔断；约 1.4k 条岗位
>       永久留在 enrich 积压、每晚被缓存重放（`llm_cached` 恒约 1.4k）。数据零丢失
> 根因: 两个独立的静默失效，fixture 与实现错得一致，CI 全绿：① MCF 的 `newPostingDate` 是纯日期
>       `"2026-08-03"`，watermark 与逐条停止条件都按 RFC3339 解析，双双静默失败；② LLM 结果全落
>       `unmapped_tech` 的岗位不写任何 `job_tech` 行，永远算积压
> 处置: `mcf.ParsePostingDate`（纯日期优先、RFC3339 回退）；新表 `enrich_done` 记「这层跑过」，
>       积压口径改成双 NOT EXISTS；手工清理 4 条孤儿 `running` 行。现状见
>       [reference/jobs-sg.md](../reference/jobs-sg.md)

## 经过

### 增量早停是死代码

日期解析失败让增量的早停条件永远不成立，每晚扫满 300 页触发熔断（`ErrCircuitOpen`），记
`errors=1` + `partial`。修复后实测：增量 130 页 / 6m48s / success（修复前 300 页 / 8m46s /
partial）。

### 零命中岗位永留积压

`llm_cached ≈ backlog` 是这个 bug 的指纹：这些岗位每晚都被 `enrich_cache` 重放一遍，却从不
落下任何 `job_tech` 行。修复是新表 `enrich_done`（Migrate 幂等建），`writeTech` 同事务恒写；
积压口径改为 `NOT EXISTS job_tech AND NOT EXISTS enrich_done`，存量免回填。部署后首个 enrich
run 53s / cached=1425 / calls=0，`jobs_sg_enrich_backlog` 1425 → 0。

## 为什么数据没丢

300 页窗口实际回溯约 8 天（MCF 日新帖约 5k，周末约 1.4k），新帖按 `sortBy=new_posting_date`
永远在前几十页；加上 08-03 的 baseline 全量，头三天每条岗位都归档过（多数重复多次）。

## 遗留

- 08-03~05 的 partial 不追溯变绿：run 状态是当时事实，日状态取当天最差 run，08-06 起才是第一个
  可能全绿的行。
- 08-03 另有 4 条回填实验被 kill 留下的孤儿 `running` 行（只写了 StartRun、`ended_at` 全
  NULL）。08-05 确认集群无活跃 run 后，在节点上用 python3 直删
  `DELETE FROM ingest_run WHERE status='running' AND ended_at IS NULL`（删前备份到节点
  `/tmp/jobs.db.bak-20260805`，重启即失效，只是临时保险）。
