# jobs-sg 技术栈规则层假阳性：`go`、`expressjs` 靠普通英文词撑进榜单

> 日期: 2026-08-24（修复、历史重放与逐周重算）；2026-08-26 补重算 W31
> 影响: 上线以来 `/tech`、`/pay` 与周报技术榜被规则层假阳性污染：`express` 命中精度 25%、`go` 65%；
>       `go` 靠假阳性进周报 top-30，`expressjs` 被读成高薪信号（高薪档 14.4% / lift 2.67×，实为
>       0.6% / 0.61×）
> 根因: ① 别名同时是普通英文词，词边界匹配分不清词义；② `Seed()` 是纯 upsert 而运行时读表，删别名
>       对已有库是空操作；③ enrich 积压跳过做过的岗位，改别名修不了历史
> 处置: 上游 `8b3040a` + `73aa949` + `fba4fcf`：词义门、`Seed()` 剪枝、新增 `jobs-sg-retech`；
>       线上跑 `retech --apply` 与 `reclassify --apply`，W31–W34 用 `report --week` 逐周重算。
>       现状见 [reference/jobs-sg.md](../reference/jobs-sg.md)

## 经过

### 精度实测

一天归档里 483 条 IT 岗位人工判定：`express` 24 命中只 6 真（25%，剩下是 Meta 简介里的
"express themselves" 和猎头签名档 "Recruit Express Pte Ltd"）；`go` 26 命中 17 真（65%，假阳性
是 "go-to-market" / "go-live" / "go-getter" / "go/no-go"）。加词义门后 `express` 5 命中 5 真、
`go` 17 命中 16 真。同批 `spark` 10/10、`node` 27/29、`swift` 9/10，故意不加门。

### 对指标的影响（在生产数据副本上验）

- `expressjs` 在高薪档从 14.4% / lift 2.67× 掉到 0.6% / 0.61×：它从来不是高薪信号。
- `go` 从 22.8% / 2.62× 变成 18.9% / 3.94×：删掉的假阳性扎堆在低薪那半边，清完溢价反而更明显。
- `go` 掉出周报 top-30（2026-W33 从 96 条降到 47 条，榜尾门槛 59），让位给 `kafka`。

### 拿 LLM 层当对照

规则层与 LLM 层是两套独立方法看同一批 JD，两层命中集合的 Jaccard 重合度可以当免标注的精度代理。
全量 `job_tech` 实测：

| slug | 修前重合 | 修后重合 | 说明 |
|---|---|---|---|
| `expressjs` | 12.6% | 77.2% | 加词义门 |
| `go` | 47.7% | 78.7% | 加词义门 |
| `spark` | 78.7% | 78.7% | 故意不加门 |
| `kubernetes` | 85.7% | 85.7% | 故意不加门 |
| `python` | 91.9% | 91.9% | 故意不加门 |

两个坏别名是唯一显著低于约 79–92% 这个带的，加门后都进了带内。`go` 的两层共同命中只从 411
掉到 385（-26），而 rule 单方面的命中掉了约 400：删掉的几乎全是 LLM 不认可的那部分，recall
基本没伤。

### retech 首次实测

dry-run 报 811 条变化：`expressjs -406`、`go -398`、`typescript -9` 是规则造成的；其余十几个
slug 各 1 条，抽验 `kibana` / `swift` 两条，确认是 JD 原文已不提该工具（重放用的是最后一次归档
的文本）。

修复本身带出两个坑，都已由后续 commit 修掉：

- `8b3040a` 的 dry-run 也调 `Seed()`，而同批改动刚让 Seed 会剪枝，于是「只报告不写库」实际改了
  `tech_taxonomy`（110→109）。`73aa949` 改成 replay 读 `store.TechSeeds()`。
- 4140 条岗位是在 `enrich_done` 表存在之前富化的，对它们 `job_tech` 行就是「这层跑过」的唯一
  证据，重放清空后会掉回积压：不补标记时 `rule_backlog` 0 → 173，补了之后 0 → 0（`llm_backlog`
  始终 0）。`fba4fcf` 改成缺的补、已有的不盖。

## 历史重放与逐周重算

- 08-24：`reclassify --apply`（全表派生分类重写，生产库 `work_mode` 0 条 `Onsite`）与
  `retech --apply`（`expressjs` rule 71 / `go` 471，`ts` / `pg` / `tf` 清零）。
- 08-24：用不带 Telegram env 的 Job 对 2026-W32/33/34 跑 `report --week`，重物化
  `weekly_metric`（`go` / `expressjs` 出 top-30、`kafka` 顶上）。
- 08-26：补重算 W31（首周，唯一漏网的一周）。它原本还挂着编造的 `Onsite: 1301`、已退役的
  avg_views/applications 指标和指向不存在周的 prev week。

重算时撞上的两个坑：

1. `report --week` 无条件把 `latest.html` / `index.html` 覆写成那一周。08-26 重算 W31 后「最新
   周报」倒退，手工复制回 W34。
2. `active_jobs` 重算出来是「重算当日」快照：W32/W33 重算后都显示 4597（撞车不是巧合），W31
   从真实历史值 4902 变成 5266。历史值被覆盖，无快照可复原。
