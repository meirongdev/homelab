# Calibre 元数据 — 覆盖率、污染与回补机制（架构事实）

> Last updated: 2026-08-06
> Status: 生效事实
> Scope: calibre 书库（oracle-k3s `personal-services`）的元数据现状、已知污染、
> 回补作业的设计与判据 —— source of truth。书库本身的存储/备份口径见
> [storage.md](storage.md)；下游消费者见 readlist（本文只讲 calibre 侧）。
> 同步电子书的操作走 skill `.claude/skills/sync-ebooks/`。

## 覆盖率现状

2026-08-06 实测（`sqlite3 file:/calibre-library/metadata.db?mode=ro`，共 **2053** 本）：

| 字段 | 有 | 缺 |
|---|---|---|
| pubdate | 2048 | 5 |
| 封面 | 1999 | 54 |
| publisher | 1356 | 697 |
| 任意 identifier | 990 | **1063** |
| comments（简介） | 980 | 1073 |
| tags | 457 | **1596** |
| rating | 14 | 2039 |
| series | 1 | 2052 |

语言分布 **eng 1725 / zho 20**（余数为无语言标注）。**豆瓣类中文源对本库基本无用**，
Google Books / OpenLibrary 才对路。

`identifier` 类型分布里 `isbn` 715、`google` 310，其余是 epub 内嵌的各种私有 id
（`pub-id` / `doi` / `uid…` 等几十种），**对在线查询没有价值**。

## ⚠️ 已知污染：mtime 冒充出版日期

`metadata-enrich.yaml`（2026-07 那套，**已被取代**）的策略是
`openlibrary/search.json?…&limit=1` 盲取第一条 + 查不到就拿**文件 mtime** 当出版日期。
后果已经落库且**不可逆地混进了真数据**：

- 实测 **487 本** pubdate 是 `MM-DD=01-01`，其中 **193 本年份 ≥2024** —— 那是文件下载
  时间，不是出版日期。
- readlist 上游已把这件事写成代码里的结论（`internal/calibre/calibre.go`）：
  `SourceCalibre —— 来自 calibre 且看不出是不是 mtime 兜底。**不可信**`。
- readlist 只能认出 **37 本**（判据：pubdate 与文件 last_modified 落在同一天），
  其余全部被洗成「看起来像真数据」。

**判据教训**：查不到就编一个值，比留空更糟 —— 留空是诚实的缺失，编出来的值会被下游
当成证据。本条是 `metadata-backfill` 不做任何兜底的直接原因。

修这批污染**尚未做**，属独立决定（会改动现有数据）。

## 回补作业 `calibre-metadata-backfill`

清单 `cloud/oracle/manifests/calibre-metadata/{metadata-backfill,backfill-job}.yaml`，
由 ArgoCD `calibre-metadata` App 交付。

### 契约

只写**当前为空**的 `identifiers` / `comments` / `tags` / `publisher`。
**`pubdate` / `title` / `authors` 一律不碰**：

- `title` —— 在线源返回的是带副标题的长书名（`Learning eBPF` →
  `Learning eBPF: Programming the Linux Kernel for Enhanced Observability…`），
  改了是上千处可见变更；
- `authors` —— 覆盖逻辑天然要先清空再写，风险不对称；
- `pubdate` —— 见上面的污染段，属独立决定。

### 匹配门（这是与旧脚本的根本差别）

1. 有 ISBN → `fetch-ebook-metadata --isbn`，标识符精确匹配，不过标题门。
2. 无 ISBN → 按标题+作者查，计算**我方标题 token 被对方覆盖的比例**
   （不是 Jaccard —— 对方副标题长会稀释 Jaccard，把正确匹配判成不匹配）。
   门槛：有作者 `0.60`，作者 Unknown `0.75`；作者 token 对上可放宽 0.15。
3. 不过门的**不写**，记进「待人工确认」清单。

### 标题变体

书名尾部括号在本库有**三种互斥含义**，实测都存在，所以两个变体都试、取过门的那个：

| 例 | 括号含义 | 哪个变体命中 |
|---|---|---|
| `…Best Practices (Md Johirul Islam)` | 作者名 | 去掉括号 |
| `…Organizations (Casey Sisterson's Library)` | 收藏标记 | **保留原样** |
| `What to Do (and NOT Do) in 75+…` | 书名的一部分 | **保留原样** |

### 实测产出率（2026-08-06）

| 桶 | 数量 | 命中 |
|---|---|---|
| 作者可用 + 标题干净 | 786 | **10/10** |
| 标题带括号 / 作者 Unknown | 277 | **3/6** |

约 **3.3s/本**；候选池（存在任一空字段）**1746 本**，全量约 1.7 小时。
一次命中同时拿到 ISBN + Google id + 简介 + 标签 + 出版社。

**失败模式是安全的**：脏输入时 `fetch-ebook-metadata` 返回**空**而不是返回错的书。
查不到的典型是书名把主副标题连成一串且无标点（如
`Becoming KCNA Certified Build a strong foundation in…`），需抽版权页辨认，尚未做。

### 怎么跑

**挂起的 CronJob**，永不自动触发。之所以不是裸 `kind: Job`：本作业要改参数反复跑，
而 Job 的 `spec.template` 不可变，改一次就得 delete 重建 —— 而删了重建会**从头再跑一遍**
（`enrich-job.yaml` 里有整段注释在讲这个代价）。CronJob 的 `jobTemplate` 可变，
改完 git push 即可。

```bash
# 在任意有 kubeconfig 的机器上
kubectl --context oracle-k3s -n personal-services create job backfill-1 \
  --from=cronjob/calibre-metadata-backfill
kubectl --context oracle-k3s -n personal-services logs -f job/backfill-1
kubectl --context oracle-k3s -n personal-services delete job backfill-1   # 手动派生的 Job 不归 ArgoCD 管，自己删
```

改数据源 / 换库 / 调匹配门之后，**先把 `DRY_RUN` 翻回 `"1"` 重跑一轮**再置 `0`。

## ❌ 为什么不用 CWA 自带的 auto_metadata_fetch

`cwa.db` 的 `auto_metadata_fetch_enabled` 维持 **0**（关闭），2026-08-06 查证后否决：

- `cps/auto_metadata.py` 是 `metadata = results[0]` —— **同样盲取第一条，无任何匹配校验**；
- 唯一调用点是 `scripts/ingest_processor.py`，**只对新导入的书生效，回补不了历史书**；
- 默认配置 `auto_metadata_smart_application=0` 是**无条件覆盖**，且 authors 分支
  连 smart 保护都没有（永远 `clear()` 后替换）。

同理 `cps/metadata_provider/hardcover.py` 虽有 `rating` 字段但**代码从不赋值**、
GraphQL 也不 select，指望它拿评分是空的。

## 评分与书评：calibre 的能力边界

- **「评价」（书评正文）calibre 没有对应字段。** `comments` 存的是出版社简介（blurb）。
- **原生 `rating` 是「你自己的星级」**（0–5 存 0–10），不是公众评分。要存公众评分
  应建自定义列 —— `custom_columns` 当前为**空**。
- calibre 内置源里只有 Amazon 提供 rating，实测在本集群 **120s 超时无结果**（反爬）。
  CWA 网页端那套 provider（`google.py:83` `match.rating = volume_info["averageRating"]`）
  能拿到，但只在编辑页一本本点，无批量入口。
- **没有任何源支持「按内容查」**：全部是标识符 → 书名+作者匹配，没有全文指纹。

## 写库的副作用边界

直接用 sqlite3 写 `metadata.db` **不会**触发 CWA 的元数据强制回写：
`auto_metadata_enforcement=1` 虽开着，但 `metadata-change-detector` 监视的是
`metadata_change_logs/` 目录（calibre-web 自己编辑时才写日志）。
所以批量写库**不会**引发 24G 书库的电子书文件重写与 restic 备份 churn。
（`cover_enforcer.py` 的 `supported_formats` 也只有 epub/azw3，PDF 本就不受影响。）
