# Calibre 元数据 — 覆盖率、污染与回补机制（架构事实）

> Last updated: 2026-09-01
> Status: 生效事实
> Scope: calibre 书库（oracle-k3s `personal-services`）的元数据现状、已知污染、
> 回补作业的设计与判据，本文是 source of truth。书库本身的存储/备份口径见
> [storage.md](storage.md)；下游消费者见 readlist（本文只讲 calibre 侧）。
> 同步电子书的操作走 skill `.claude/skills/sync-ebooks/`。
>
> 🔧 **要动手补元数据看
> [guides/calibre-metadata-enrichment.md](../guides/calibre-metadata-enrichment.md)**
> 那里是「用哪一层、怎么跑、什么时候停」；本文是「现状是什么、判据为什么这么定」。

## 覆盖率现状

共 2053 本（2026-08-08 那次统计时；现网 2063 本，下表整体是 08-08 的快照，
未随书库增长重测）。「起始」是 2026-08-06 动手之前的基线，留着是因为它解释了
为什么后来的修正才成为可能（见下方「ISBN 从 35% 涨到 77%」）。

**四轮回补 + 三轮修正 + 封面 + 三轮 LLM 生成全部跑完后的终态**（2026-08-08 01:01）：

| 字段 | 起始 | **终态** | 仍缺 |
|---|---|---|---|
| 任意 identifier | 990 | 1750 | 303 |
| ISBN | 715 | 1582 | 471 |
| comments（简介） | 980 | 1812 | 241 |
| tags | 457 | 1698 | 355 |
| publisher | 1356 | 1743 | 310 |
| 作者非 Unknown | 1799 | 2003 | 50 |
| 封面 | 1999 | 2012 | 41 |
| pubdate 年份粒度污染 | 487 | 234 | — |

综合口径：**六项全有 1437 本（70%）**；完全无元数据 26 本（1.3%），从起始的 236 本降下来。

出处标记：`#pubdate_src` 253 条 · `#meta_src` 209 条。
⚠️ 2026-08-08 核过完整性：LLM 跑之后新增的简介/标签**漏标 0 条**
（另有 69 本无标记，全部是导入时自带、跑之前就存在的，属正常）。

**ISBN 从 35% 涨到 77% 是全局关键**：它把「只能模糊匹配」变成「可按标识符精确查」，
修正作业（见下）才有了锚。

### 命中率随轮次衰减，第四轮不值得跑

| 轮次 | 处理 | 命中 | 命中率 |
|---|---|---|---|
| 回补 1 | 1746 | 1053 | 70% |
| 回补 2 | 867 | 338 | 39% |
| 回补 3 | 624 | 105 | 19% |

第三轮 105 次命中只写入 19 个 identifier / 6 条简介（其余命中的书那些字段本来就有），
边际收益已接近零。

### 客观下限：236 → 26 本

起始时有 236 本「三样全无」：自出版 / Kindle 独占（`B09RHP5H81 EBOK`、
`FINAL eBOOKS`、`Passive Income Business…`），**本就没有 ISBN、也从未进过任何
书目数据库**，Google Books 与 OpenLibrary 都查不到、书里也挖不出号段。

第 4 层（LLM 从正文生成）把这批降到 26 本。剩下的里 21 本取不到正文
（PDF 无文本层、EPUB 无 spine 正文），四层手段全部无效，只能人工录入或接受缺失。

### 封面：三个作业的分工

| 作业 | 来源 | 覆盖 |
|---|---|---|
| `calibre-metadata-updater`（每夜） | 电子书文件**内嵌**封面，零网络 | 绝大多数 |
| `calibre-metadata-covers`（挂起，手动触发） | Google Books `imageLinks` | 补上 13 本 |
| — | 无 | 仍缺 41 本 |

2026-08-06 跑完后缺封面 54 → 41。剩下的 41 本：34 本没有任何标识符（查不了），
7 本 Google 侧也没有图。

⚠️ 两个实测要点（写在 `metadata-covers.yaml` 里，别重新发现一遍）：

1. **`fetch-ebook-metadata --cover` 在本环境拿不到封面**：Google 与 Google Images
   两种源、150s 超时都试过，产出为空。只能走 Google Books API 直取 `imageLinks`。
2. **默认 `thumbnail` 只有约 16KB（~128px 宽）**，在 calibre-web 网格里明显发虚。
   同一张图把 URL 参数改成 `zoom=4` 或 `w=800` 能拿到 45–64KB，约 5 倍，
   不需要换源，只是参数问题。

语言分布 eng 1725 / zho 20（余数为无语言标注）。**豆瓣类中文源对本库基本无用**，
Google Books / OpenLibrary 才对路。

`identifier` 类型分布里 `isbn` 715、`google` 310，其余是 epub 内嵌的各种私有 id
（`pub-id` / `doi` / `uid…` 等几十种），**对在线查询没有价值**。

## ⚠️ 已知污染：mtime 冒充出版日期（已修一半）

`metadata-enrich.yaml`（2026-07 那套，**已被取代**）的策略是
`openlibrary/search.json?…&limit=1` 盲取第一条 + 查不到就拿**文件 mtime** 当出版日期。
后果已经落库且**不可逆地混进了真数据**：

- 实测 487 本 pubdate 是 `MM-DD=01-01`，其中 193 本年份 ≥2024，那是文件下载
  时间，不是出版日期。
- readlist 上游已把这件事写成代码里的结论（`internal/calibre/calibre.go`）：
  `SourceCalibre：来自 calibre 且看不出是不是 mtime 兜底。**不可信**`。
- readlist 只能认出 **37 本**（判据：pubdate 与文件 last_modified 落在同一天），
  其余全部被洗成「看起来像真数据」。

**判据教训**：查不到就编一个值，比留空更糟。留空是诚实的缺失，编出来的值会被下游
当成证据。本条是 `metadata-backfill` 不做任何兜底的直接原因。

**修复进展**（2026-08-06 三轮修正作业）：`MM-DD=01-01` 从 487 降到 234，
其中 **253 条**已带 `#pubdate_src=google-isbn` 出处标记。剩下的 234 本多数没有
可查的 ISBN（或 ISBN 未被 Google Books 收录），只能维持原值，但它们不带
`#pubdate_src` 标记，所以「可信 vs 存疑」现在可以直接区分，不必再猜 `MM-DD`。

## 回补作业 `calibre-metadata-backfill`

清单 `cloud/oracle/manifests/calibre-metadata/{metadata-backfill,backfill-job}.yaml`，
由 ArgoCD `calibre-metadata` App 交付。

### 契约

只写**当前为空**的 `identifiers` / `comments` / `tags` / `publisher`。
**`pubdate` / `title` / `authors` 一律不碰**：

- `title`：在线源返回的是带副标题的长书名（`Learning eBPF` →
  `Learning eBPF: Programming the Linux Kernel for Enhanced Observability…`），
  改了是上千处可见变更；
- `authors`：覆盖逻辑天然要先清空再写，风险不对称；
- `pubdate`：见上面的污染段，属独立决定。

### 三级策略（按可靠性排序，先试可靠的）

1. **库内已有 ISBN** → `fetch-ebook-metadata --isbn`，标识符精确匹配，不过标题门。
2. **从书自身内容挖 ISBN** → 同样按 ISBN 精确查。见下节。
3. **按标题+作者查** → 计算我方标题 token 被对方覆盖的比例
   （不是 Jaccard：对方副标题长会稀释 Jaccard，把正确匹配判成不匹配）。
   门槛：有作者 `0.60`，作者 Unknown `0.75`；作者 token 对上可放宽 0.15。
   最不可靠，放最后。

不过门的**不写**，记进「待人工确认」清单。

### 内容提取 ISBN（策略 2）

专治标题搜索**完全无效**的那批：书名把主副标题连成一串没有标点
（`Becoming KCNA Certified Build a strong foundation in…`），Google 匹不上，
但书里印着的 ISBN 一查就中。不需要 LLM，ISBN 是 ground truth，
比让模型从扉页文本猜书名可靠。

提取顺序：

| 格式 | 来源 | 实测命中（40 本样本，均为库中当时无 isbn 的书） |
|---|---|---|
| EPUB | OPF 元数据 → spine 前部正文 | **21/40 ≈ 52%**（其中 16 本 ISBN 一直在 OPF 里） |
| PDF | 前 16 页文本（`pdftotext`） | **16/17 ≈ 94%** |

挖不到的多是自出版 / Kindle 独占（`B09RHP5H81 EBOK`、`Passive Income Business…`），
**本就没有 ISBN**，这是真实下限，不是技术失败。

⚠️ **EPUB 必须按 OPF `<spine>` 阅读顺序取前部，不能按文件名字母序**：
EPUB 内的文件可以叫 `bm01` / `ch10` / `pt02` 任意名字，字母序取到的往往不是版权页。
改对之后 EPUB 命中率从 22% → 52%。

⚠️ **calibre 导入时不认 OPF 里的 ISBN**：那 16 本的写法是 `urn:isbn:…` 之类，
不是 `scheme="ISBN"`，所以 `ebook-meta` 不把它当 ISBN 报出来。这是「库里没有但书里有」的主因。

#### 两个已踩过的坑

1. **`pdftotext` 缺 `LD_LIBRARY_PATH=/app/calibre/lib` 会静默输出空**：
   表现与「PDF 真的没有文本层」**完全一致**。2026-08-06 的第一版探测因此把
   10 个 PDF 全判成扫描件，报出 36% 的假命中率；修正后无文本层实际是 **0 本**。
   calibre 的**所有**二进制都吃这个变量。
2. **全文扫 `978` 号段会捞到参考文献里引用的书。** 实测 id=168
   `Java OOP Done Right` 捞出 `9780201633610`（《The Pragmatic Programmer》）
   与 `9780321125217`（《DDD》）。所以只取 OPF + 版权页所在的前部，
   并且仍过一道低标题门（`GATE_ISBN_CONTENT=0.35`）兜底：
   门槛低是因为库里不少书名本身就是垃圾（`FINAL eBOOKS`、`B09RHP5H81 EBOK`），
   书自己印的 ISBN 比我们的书名可信；0.35 只用来拦量级错误。

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
| 作者可用 + 标题干净 | 786 | 10/10 |
| 标题带括号 / 作者 Unknown | 277 | 3/6 |

约 3.3s/本；候选池（存在任一空字段）1746 本，全量约 1.7–2.5 小时。
一次命中同时拿到 ISBN + Google id + 简介 + 标签 + 出版社。

加上策略 2 之后，在**标题搜索啃不动的那一段**上实测（12 本样本）：命中 8 本，
其中 6 本来自书内挖出的 ISBN，标题匹配只贡献 2 本，这段路上策略 2 是主力。

**失败模式是安全的**：脏输入时 `fetch-ebook-metadata` 返回空而不是返回错的书。

### 怎么跑

**挂起的 CronJob**，永不自动触发。之所以不是裸 `kind: Job`：本作业要改参数反复跑，
而 Job 的 `spec.template` 不可变，改一次就得 delete 重建，而删了重建会**从头再跑一遍**
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

## 修正作业 `calibre-metadata-correct`

清单 `cloud/oracle/manifests/calibre-metadata/{metadata-correct,correct-job}.yaml`。

**与 backfill 的分工**：backfill 只填空字段、绝不覆盖；correct 覆盖已知错误值，
且**只处理有 ISBN 的书**：修改锚在标识符上，不靠模糊匹配。当初把
pubdate/title/authors 划在回补范围外正是因为没有这个锚；ISBN 覆盖率
从 715 涨到 1571 之后，这条路才成立。

四类，各有独立准入判据：

| 类 | 判据 | 只在什么条件下写 |
|---|---|---|
| A 作者 | `authors ∈ {Unknown, 空}` | 不覆盖任何真实作者名（Unknown 是缺失不是数据） |
| B 日期 | `pubdate` 的 `MM-DD = 01-01` | **对方必须给出带月日的完整日期**；对方也只有年份的不换，那是拿一个猜测换另一个猜测 |
| C 书名 | 像文件名 | 只认三点分隔 / ASIN `B0XXXXXXXX` / 纯大写 ID，宁漏不错 |
| D 书名 | 尾部括号杂讯 | 见下 |

### ☠️ D 类不能盲删括号

本库尾括号有**三种互斥含义**，实测都存在：

| 例 | 含义 | 该不该删 |
|---|---|---|
| `…Best Practices (Md Johirul Islam)` | 作者名 | 删 |
| `…Organizations (Casey Sisterson's Library)` | 收藏标记 | 删 |
| `What to Do (and NOT Do) in 75+…` | 书名的一部分 | **删了就毁了书名** |

唯一可靠判据是数据驱动的：拿 ISBN 查回权威书名，**括号内容在权威书名里出现过半就保留**。

### `#pubdate_src` 自定义列

`calibredb --with-library=/calibre-library add_custom_column pubdate_src "出版日期来源" text`
（分配到 **id=1**，normalized 型 → `custom_column_1` + `books_custom_column_1_link`）。

建它的原因：**calibre 原生没有 provenance 字段**，这正是当初 mtime 污染能被
「洗成真数据」的根本原因：readlist 只能靠猜 `MM-DD` 是不是 `01-01` 来判断可信度，
且只认得出 37/487。修过的日期标 `google-isbn`，以后可直接区分。

### 已知限制

约 **32%** 的 ISBN 在 Google Books 查无结果，实测集中在 Apress 的 `1484` 号段
（电子版 ISBN），**OpenLibrary 也查不到**（2026-08-06 实测三例均无）。
这些书安全跳过，不做任何修改。

## ❌ 为什么不用 CWA 自带的 auto_metadata_fetch

`cwa.db` 的 `auto_metadata_fetch_enabled` 维持 **0**（关闭），2026-08-06 查证后否决：

- `cps/auto_metadata.py` 是 `metadata = results[0]`，**同样盲取第一条，无任何匹配校验**；
- 唯一调用点是 `scripts/ingest_processor.py`，**只对新导入的书生效，回补不了历史书**；
- 默认配置 `auto_metadata_smart_application=0` 是**无条件覆盖**，且 authors 分支
  连 smart 保护都没有（永远 `clear()` 后替换）。

同理 `cps/metadata_provider/hardcover.py` 虽有 `rating` 字段但**代码从不赋值**、
GraphQL 也不 select，指望它拿评分是空的。

## 评分与书评：calibre 的能力边界

- **「评价」（书评正文）calibre 没有对应字段。** `comments` 存的是出版社简介（blurb）。
- **原生 `rating` 是「你自己的星级」**（0–5 存 0–10），不是公众评分。

### ❌ 公众评分：不是抓不到，是数据不存在（2026-08-06 实测后放弃）

两个免费源对本库的覆盖率**都是零**：

| 源 | 样本 | 有评分 |
|---|---|---|
| Google Books（带 API key，无 429） | 25 本 | 0 |
| OpenLibrary `/ratings.json` | 8 本（其中 3 本有 work 记录） | 0 |

与 readlist 的独立测量互相印证：`readlist_dim_measured{dim="A"}` = **39 / 2045（1.9%）**。

根因是**书目结构**而非技术：本库 1725/2053 是英文技术书，而 Google Books 与
OpenLibrary 的评分主要来自大众读物。建这一列会得到一个 **98% 为空**的字段，
还要为它维护一个夜间作业，因此**刻意不建**，`custom_columns` 里只有 `pubdate_src`。

唯一可能可行的路是 **Hardcover.app**（Goodreads 的开放替代，免费 GraphQL API，
技术书覆盖较好），但需要账号 token；**在拿到 token 实测覆盖率之前不要动手建列**，
否则重复一次同样的空字段。⚠️ 注意 CWA 自带的 `cps/metadata_provider/hardcover.py`
帮不上忙：它有 `rating` 字段但**代码从不赋值**、GraphQL 也不 select（见下节）。
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

### ☠️ 反过来：`calibredb embed_metadata` 报成功但什么都没写

上面那条的代价是：**DB 补得再全，书文件里的元数据还是旧的**。文件一旦被重新 ingest
（或导出、发到设备），旧值就回来了。想把 DB 元数据写回文件，官方手段是
`calibredb embed_metadata <id>`。**它在本库不生效，且完全不报错**（2026-08-18 实测）：

```
$ calibredb --with-library=/calibre-library embed_metadata 3063
Processed Django 6 Cookbook, Second Edition: ... (1 of 1)
$ echo $?
0
```

然后文件 **mtime 纹丝不动**，zip 里 `OEBPS/opf.opf` 的 `dc:title` 还是原来那个
`book title`。排除过的因素：权限没问题（`-rw-rw-rw- root abc`，以 root 跑）；
EPUB 结构合规（有 `mimetype`、`META-INF/container.xml` 的 rootfile 指向确实存在的
`OEBPS/opf.opf`）；prefs 里没有任何 embed 相关开关。**没有继续深挖 calibre 内部为什么
no-op**，有能用的替代手段，不值得。

**能用的是底层的 `ebook-meta`**（先在 `/tmp` 的副本上验证过再动库内文件）：

```bash
# 在 pod 内。值全部取自 metadata.db，保证文件与 DB 一致
ebook-meta "<library>/<path>/<name>.epub" \
  --title "<title>" --authors "<a1> & <a2>" --publisher "<pub>" \
  --isbn "<isbn>" --comments "<html>" --date "2026-04-09T11:20:05+00:00"
```

两个坑：

- ⚠️ **`--date` 只给日期会偏一天。** 传 `--date 2026-04-09`，ebook-meta 按 **pod 本地
  时区**（UTC+8）解释再存成 UTC，落地是 `2026-04-08T16:00:00+00:00`。**传完整时间戳**
  （EPUB 原本的 `dc:date` 就是现成的真值）。
- ⚠️ **绕过了 calibre 的记账，`data.uncompressed_size` 会过期。** 文件被重写后体积会变
  （实测 +638 / +688 字节），DB 里那一列不会自动更新，calibre-web 显示的大小就是旧的。
  写完顺手 `UPDATE data SET uncompressed_size=? WHERE book=? AND format=?`。

⚠️ 注意这确实会重写书文件，也就绕开了本节开头那条「不引发 churn」的前提，
批量做要算 restic 增量代价（EPUB 每本几百字节，PDF 的元数据写入能力本就有限）。

**为什么值得做**：这正是占位符标题问题反复的原因。`book title` / `PDF Reducer Demo
version` 这类工具残渣只改 DB 是治标，文件重新入库就复发；而带这种标题的书在
`scripts/cleanup-duplicates.py` 里是**被排除在判重之外**的（标题不携带识别信息，
据此判重会把不同的书合并，实测两本 `book title` 的 sha256 与体积都不同）。
→ [records/2026-08-18-calibre-dedup-stale-paths.md](../records/2026-08-18-calibre-dedup-stale-paths.md)
