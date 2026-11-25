# jobs-sg — 分类与技术栈：口径与重算

> Last updated: 2026-11-25
> Status: 生效事实
> Scope: 分类结论与规则层技术栈怎么来、怎么离线重算（`jobs-sg-reclassify` / `jobs-sg-retech` / `report --week`）、
> 别名表规则与 `work_mode` 口径。2026-11-25 从 [jobs-sg.md](jobs-sg.md) 拆出；部署形态、备份、告警等仍在那篇。

## 重放归档重算分类（`jobs-sg-reclassify`）

分类结论（`is_swe` / `role_family` / `seniority` / `work_mode` / `company_type`）是 ingest 当时
算好存在行上的。修了分类器，只有管线再次看见的岗位会被修正，已下架的岗位永远保留错误结论。
分类规则是归档 JSON 的纯函数，所以整段历史可以离线重算：零 API 调用，覆盖每一条归档过的岗位
（含已下架）。强制 reconcile 要约 867 页 × 1.5s、20–25 分钟，且只覆盖还在架的。

```sh
# 1) 先 dry-run：只报告 old->new 迁移矩阵，不写库
kubectl --context k3s-homelab -n jobs-sg create job reclassify-dry --dry-run=client -o yaml \
  --image=ghcr.io/meirongdev/jobs-sg@sha256:<当前digest> -- \
  /usr/local/bin/jobs-sg-reclassify --data-dir /data > /tmp/j.yaml
# 补上 PVC 挂载后 apply（PVC: jobs-sg-data，挂 /data，可写）
# 2) 看完矩阵再决定是否加 --apply 重跑一次
```

1. 默认 dry-run，`--apply` 才写。`is_swe` 的增减移动的是所有指标的统计口径，先看矩阵。
2. ☠️ 只写派生列。`closed_at` / `last_seen_at` / `first_seen_at` / `miss_count` 在 SQL 里不出现：
   重放归档说明不了岗位是否还在架，碰 `last_seen_at` 会悄悄撤销一次关闭。
3. 归档里有、库里没有的 uuid 只计数不插入（没有诚实的 `first_seen_at` 可填）。这个计数就是
   「partial 那几轮漏了几条」的答案。
4. 不重跑 LLM，也不动技术栈；`job_tech` 用 `retech`。

## 重放规则层重算技术栈（`jobs-sg-retech`）

enrich 的积压口径是 `NOT EXISTS job_tech AND NOT EXISTS enrich_done`，做过的永远不重算。所以改了
`tech_taxonomy` 别名表或匹配逻辑，已富化的岗位保留旧结论，`/tech`、`/pay` 和周报的技术栈趋势
一直错着。`retech` 扫归档、用当前别名表重算规则层、重写 `job_tech`：零 API 调用，只碰
`source='rule'`（`source='llm'` 没有模型重放不出来，读都不读）。

```sh
# 1) dry-run：报告哪些 slug 增减了多少条，不写库
kubectl --context k3s-homelab -n jobs-sg create job retech-dry --dry-run=client -o yaml \
  --image=ghcr.io/meirongdev/jobs-sg@sha256:<当前digest> -- \
  /usr/local/bin/jobs-sg-retech --data-dir /data > /tmp/j.yaml
# 补上 PVC 挂载后 apply（PVC: jobs-sg-data，挂 /data，可写）
# 2) 看完增减再决定是否加 --apply 重跑一次
```

1. 默认 dry-run，`--apply` 才写。dry-run 真的只读（replay 的是代码里的 `store.TechSeeds()`）；
   `--apply` 才跑 `Seed()` 把表也收敛掉（每晚 enrich 读的是表，表里留着退役别名，新岗位照样命中）。
2. 报告里的变化不都是规则造成的：重放用最后一次归档的文本，描述改过的岗位也会进 diff。判据：
   规则改动一次动几百条，描述编辑是长尾的单条。
3. `enrich_done` 只补不盖：已有标记绝不重新盖时间戳；缺的必须补上（早于 `enrich_done` 表富化的
   岗位，`job_tech` 行就是「这层跑过」的唯一证据，清空它就掉回积压）。
4. ⚠️ 判 rule 层积压别看 `jobs_sg_enrich_backlog`（只数 LLM 层），自己查
   `NOT EXISTS job_tech(source='rule') AND NOT EXISTS enrich_done(source='rule')`。

### 重算历史周（`report --week`）

`weekly_metric` 是物化的，retech/reclassify 都不碰，历史周要逐周 `report --week`。

- ⚠️ 用**不带 Telegram env 的 Job**：推送是 env-driven、unset 即跳过，而
  `--from=cronjob/report` 会把 env 一起抄过来，等于把历史周报重推一遍进 Telegram。
- ☠️ `report --week` 无条件把 `latest.html` / `index.html` 覆写成那一周。重算完旧周必须把最新周的
  HTML 复制回去，否则「最新周报」倒退。
- ☠️ `active_jobs`（"On the board at publication"）重算出来是「重算当日」快照：SQL 是
  `closed_at IS NULL AND expiry_date >= 周末`，而 `closed_at` 只反映今天。重算会覆盖历史真值且
  无快照可复原，别随手重算历史周。
- 判旧周是否已按新口径：查对应 `week_start` 的 `weekly_metric.computed_at` 是否晚于修复的部署时间。

2026-08-24/26 已对全表跑过 `reclassify --apply`、`retech --apply`，W31–W34 已逐周重算，过程见
[records/2026-08-24-jobs-sg-tech-alias-false-positives.md](../records/2026-08-24-jobs-sg-tech-alias-false-positives.md)。

## 别名表（`tech_taxonomy`）的规则

规则层是纯文本词边界匹配，分不清词义。

- 别名同时是普通英文词（`express`、`go`）时加**词义门**：只在技术枚举上下文里算命中（一侧紧邻
  `( , / ; [` 或 `) . ]` 等分隔符）。门有代价（漏掉 "Node.js Express REST APIs" 这种散文里的真
  命中），只给实测精度差的加；`spark`、`node`、`swift` 刻意不加。
- ☠️ `Seed()` 会删掉表里不在 seed 列表的别名：手工 `INSERT` 进 `tech_taxonomy` 的别名会被下一次
  ingest/enrich 清掉，加别名只能改代码。
- 改别名表修不了历史，要跑 `retech`。

### 判一个别名准不准：拿 LLM 层当对照，不用人工判

规则层和 LLM 层是两套独立方法看同一批 JD，两层命中集合的 Jaccard 重合度就是免标注的精度代理。
健康区间约 79–92%（2026-08-24 全量实测：`python` 91.9%、`kubernetes` 85.7%、`spark` 78.7%；
加门后的 `go` 78.7%、`expressjs` 77.2%）。新增或怀疑一个别名时先看这个数，明显低于 79% 就去看
命中上下文。

## work_mode 的口径：Unknown 是一等状态

MCF 的 `flexibleWorkArrangements` 回答的是什么时候上班，不是在哪上班：500 条全行业样本里只有
7.4% 带这个字段，唯一的地点信号 `Telecommuting` 占 0.6%，其余是 `Flexi-Hours` 之类的排班值。

- 只有地点类 arrangement 产生结论（`Telecommuting`→Remote、`Flexi-Place`→Hybrid），排班类一律不
  产生，没有地点信号就是 `Unknown`。看到「Unknown 占九成」不是故障，是数据源只知道这么多。
- ⚠️ 换镜像不会立刻改变页面：`work_mode` 由 ingest 的 upsert 重写，web 只读，要等下一轮抓取；
  周日 reconcile 走全 board，一次刷新所有在架岗位；已下架的要 `reclassify`。
- 生产库全表 0 条 `Onsite`（2026-08-24 `reclassify --apply` 后），W31–W34 已按新口径重算。
