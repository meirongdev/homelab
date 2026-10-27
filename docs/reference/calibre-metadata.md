# Calibre 元数据 — 覆盖率、污染与回补机制（架构事实）

> Last updated: 2026-10-28
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

2026-08-08 全部作业跑完时的快照（2053 本，之后未随书库增长重测）：ISBN 77% · 简介 88% ·
标签 83% · 出版社 85% · 作者非 Unknown 98% · 封面 98%；六项全有约 70%，完全无元数据
26 本（起始 236 本）。各层逐轮产出与停止判据见 guide。

- **ISBN（起始 35%）是全局的锚**：它把模糊匹配变成按标识符精确查，修正作业才成立。
- **客观下限**：剩下的是自出版 / Kindle 独占（`B09RHP5H81 EBOK`、`FINAL eBOOKS`、
  `Passive Income Business…`），本就没有 ISBN、不在任何书目库里；26 本里 21 本连正文都
  取不到（PDF 无文本层、EPUB 无 spine 正文），只能人工录入或接受缺失。
- 绝大多数是英文书（中文约 20 本），**豆瓣类中文源基本无用**，Google Books / OpenLibrary
  才对路。`identifier` 里只有 `isbn`、`google` 有查询价值，其余是 epub 私有 id
  （`pub-id` / `doi` / `uid…` 等几十种）。
- **封面**：`calibre-metadata-updater` 每夜从文件**内嵌**封面提取（零网络，覆盖绝大多数）；
  `calibre-metadata-covers`（挂起）从 Google Books `imageLinks` 补，仍缺的多半没有标识符。
  `fetch-ebook-metadata --cover` 在本环境拿不到封面；默认 `thumbnail` 只有约 128px，要请求
  `w=800`（详见 `metadata-covers.yaml` 与 guide 1.5 节）。

## ☠️ 已知污染：mtime 冒充出版日期

`metadata-enrich.yaml`（2026-07 那套，**已被取代**；清单保留只因它的 Job 已 Complete 且
`spec.template` 不可变）盲取 `openlibrary/search.json?…&limit=1` 第一条，查不到就拿
**文件 mtime** 当出版日期，结果不可逆地混进了真数据：

- 487 本 pubdate 是 `MM-DD=01-01`，其中 193 本年份 ≥2024（那是下载时间）。readlist 只认得出
  **37 本**（pubdate 与文件 last_modified 同一天），上游 `internal/calibre/calibre.go` 已把
  `SourceCalibre` 定为不可信。
- 修正作业把其中 253 本换成按 ISBN 查回的完整日期并标 `#pubdate_src=google-isbn`；余下约
  234 本多数没有可查的 ISBN，维持原值。**判据**：带 `#pubdate_src` 的可信，不带标记的
  `01-01` 存疑，不必再猜 `MM-DD`。

查不到就编一个值比留空更糟：编出来的值会被下游当成证据。这是 backfill 不做任何兜底、
LLM 写入必须打 `#meta_src` 的原因。原方案见
[plans/archive/2026-07-05-calibre-metadata-enrichment.md](../plans/archive/2026-07-05-calibre-metadata-enrichment.md)。

## 回补作业 `calibre-metadata-backfill`

清单 `cloud/oracle/manifests/calibre-metadata/{metadata-backfill,backfill-job}.yaml`，
由 ArgoCD `calibre-metadata` App 交付。

**契约**：只写**当前为空**的 `identifiers` / `comments` / `tags` / `publisher`；
`pubdate` / `title` / `authors` 一律不碰（在线源的 title 带长副标题，改了是上千处可见变更；
authors 覆盖要先清空再写，风险不对称；pubdate 见上节）。

三级策略，先试可靠的；不过门的**不写**，记进「待人工确认」清单：

1. **库内已有 ISBN** → `fetch-ebook-metadata --isbn` 精确查，不过标题门。
2. **从书自身内容挖 ISBN** → 同样精确查，只过低门 `GATE_ISBN_CONTENT=0.35`（库里不少书名
   是垃圾，书自己印的 ISBN 更可信，这道门只拦量级错误）。
3. **按标题+作者查**，最不可靠。判据是 `title_gate()`：书名（去冠词与版次）与对方互为前缀
   且至少 2 个 token；我方更长或 ≥4 token 才收，更短的要作者姓氏佐证。覆盖率不参与判定
   （`coverage()`、`GATE_WITH_AUTHOR` / `GATE_NO_AUTHOR` 只出现在日志里）：它会放行
   `Machine Learning` → `Grokking Machine Learning` 这种另一本书，作者相同也救不了。

失败模式是安全的：脏输入时 `fetch-ebook-metadata` 返回空而不是错的书。

### 书内挖 ISBN（策略 2）

专治书名把主副标题连成一串、标题搜索无效的那批；ISBN 是 ground truth，不需要 LLM。
EPUB 取 OPF 元数据 → spine 前部正文（命中约一半），PDF 取前 16 页 `pdftotext`（九成以上）。

- ⚠️ **EPUB 必须按 OPF `<spine>` 阅读顺序取前部**：文件可以叫 `bm01` / `ch10` / `pt02`，
  按字母序取到的往往不是版权页。
- ⚠️ **calibre 导入时不认 OPF 里的 `urn:isbn:…`**（只认 `scheme="ISBN"`），`ebook-meta`
  也不报，这是「库里没有、书里有」的主因。
- ☠️ **`pdftotext` 缺 `LD_LIBRARY_PATH=/app/calibre/lib` 会静默输出空**，与「PDF 没有文本层」
  无法区分，会把文本 PDF 全判成扫描件。calibre 的**所有**二进制都吃这个变量。
- ⚠️ **全文扫 `978` 号段会捞到参考文献里的书**（id=168 捞出 `9780201633610`，
  《The Pragmatic Programmer》），所以只取 OPF + 版权页所在的前部，再过 0.35 那道门。

### ☠️ 书名尾括号：四种互斥含义，不能盲删

| 例 | 含义 | 检索时 | 存储的书名 |
|---|---|---|---|
| `…Best Practices (Md Johirul Islam)` | 作者名 | 去掉才命中 | correct D 类删 |
| `…Organizations (Casey Sisterson's Library)` | 收藏标记 | 保留才命中 | correct D 类删 |
| `What to Do (and NOT Do) in 75+…` | 书名的一部分 | 保留 | **删了就毁了书名** |
| `An Illustrated Guide to AI Agents (for . .)` | 下载源水印 | 去掉 | 匿名的 `(for . .)` 剥掉，具名的 `(for Raymond Rhine)` 历来保留 |

backfill 两个变体都试、取过门的那个。correct D 类唯一可靠的判据：拿 ISBN 查回权威书名，
**括号内容在权威书名里出现过半就保留**。☠️ 水印是本地文件名里就带着的，**不是 CWA 导入
产生的垃圾**：当导入故障按 `DELETE ... WHERE title LIKE '%(for . .)%'` 批量清，会连带删掉
正常书籍。

### 怎么跑

CronJob 每周日 06:00 UTC 自动跑新书（`ORDER_MODE=newest` / `RECENT_DAYS=30` / `LIMIT=150`，
三个是一套，别单独改）；手动全量的参数与停止判据见 guide 第 2 层。用 CronJob 不用裸 Job：
要改参数反复跑，而 Job 的 `spec.template` 不可变、删了重建会从头再跑，CronJob 的
`jobTemplate` 改完 git push 即可。

```bash
# 任意有 kubeconfig 的机器；派生的 Job 不归 ArgoCD 管，跑完自己 delete
kubectl --context oracle-k3s -n personal-services create job backfill-1 \
  --from=cronjob/calibre-metadata-backfill
```

改数据源 / 换库 / 调匹配门之后，**先把 `DRY_RUN` 翻回 `"1"` 重跑一轮**再置 `0`。

## 修正作业 `calibre-metadata-correct`

清单 `cloud/oracle/manifests/calibre-metadata/{metadata-correct,correct-job}.yaml`，挂起、
手动派生，会覆盖已有值，跑写入前先备份（命令见 guide 第 3 层）。与 backfill 分工：backfill
只填空；correct 覆盖已知错误值，且**只处理有 ISBN 的书**，修改锚在标识符上。

| 类 | 判据 | 只在什么条件下写 |
|---|---|---|
| A 作者 | `authors ∈ {Unknown, 空}` | 不覆盖任何真实作者名（Unknown 是缺失不是数据） |
| B 日期 | `pubdate` 的 `MM-DD = 01-01` | **对方必须给出带月日的完整日期**；对方也只有年份就不换，那是拿一个猜测换另一个猜测 |
| C 书名 | 像文件名 | 只认三点分隔 / ASIN `B0XXXXXXXX` / 纯大写 ID，宁漏不错 |
| D 书名 | 尾部括号杂讯 | 见上节表格 |

**已知限制**：约三成 ISBN 在 Google Books 查无结果，集中在 Apress 的 `1484` 号段（电子版
ISBN），OpenLibrary 也没有。这些书安全跳过，不做任何修改。

### 自定义列 `#pubdate_src` / `#meta_src`

calibre 原生没有 provenance 字段，这正是 mtime 污染能被洗成真数据的根本原因。
`custom_columns` 里只有这两列，都是出处标记；没有标记的是导入自带或来源不明的历史数据。

- `#pubdate_src`：`calibredb --with-library=/calibre-library add_custom_column pubdate_src "出版日期来源" text`
  建的，分配到 **id=1**（normalized 型 → `custom_column_1` + `books_custom_column_1_link`，
  对应 correct 的 `PUBDATE_SRC_COL`），值 `google-isbn`。
- `#meta_src`：id=2（`metadata-llm.yaml` 的 `META_SRC_COL`），值 `llm-from-content`。

## ❌ 为什么不用 CWA 自带的 auto_metadata_fetch

`cwa.db` 的 `auto_metadata_fetch_enabled` 维持 **0**（关闭）：`cps/auto_metadata.py` 是
`metadata = results[0]`，同样盲取第一条无匹配校验；唯一调用点 `scripts/ingest_processor.py`
只对新导入的书生效；默认 `auto_metadata_smart_application=0` 是无条件覆盖，authors 分支连
smart 保护都没有（永远 `clear()` 后替换）。

## 评分与书评：calibre 的能力边界

- 书评正文没有对应字段，`comments` 存的是出版社简介（blurb）。原生 `rating` 是「你自己的
  星级」（0–5 存 0–10），不是公众评分。
- ❌ **公众评分刻意不建列**：Google Books（带 API key）与 OpenLibrary `/ratings.json` 对本库
  抽样覆盖率都是 0，readlist 的独立测量 `readlist_dim_measured{dim="A"}` 约 2%。根因是书目
  结构（英文技术书为主，评分来自大众读物），建出来几乎全空还要养一个夜间作业。
- 唯一可能可行的是 **Hardcover.app**（免费 GraphQL API，需账号 token）：**拿到 token 实测
  覆盖率之前不要建列**。CWA 的 `cps/metadata_provider/hardcover.py` 帮不上忙，它的 `rating`
  字段代码从不赋值、GraphQL 也不 select。
- 其它路都不通：calibre 内置源只有 Amazon 给 rating（本集群 120s 超时，反爬）；CWA 网页端
  provider（`google.py:83` `match.rating = volume_info["averageRating"]`）只能在编辑页逐本点；
  没有任何源支持按内容查，全部是标识符 → 书名+作者匹配。

## 写库的副作用边界

直接用 sqlite3 写 `metadata.db` **不会**触发 CWA 的元数据强制回写：
`auto_metadata_enforcement=1` 虽开着，但 `metadata-change-detector` 监视的是
`metadata_change_logs/` 目录（calibre-web 自己编辑时才写）；`cover_enforcer.py` 的
`supported_formats` 也只有 epub/azw3。所以批量写库不会引发书文件重写与 restic 备份 churn。

⚠️ 判重/清理前：`books.path` 会过期，按 path 找不到文件不等于文件没了，见
[records/2026-08-18-calibre-dedup-stale-paths.md](../records/2026-08-18-calibre-dedup-stale-paths.md)。

### ☠️ `calibredb embed_metadata` 报成功但什么都没写

DB 补得再全，书文件里的元数据还是旧的，文件一旦被重新 ingest（或导出、发到设备）旧值就回来。
`calibredb --with-library=/calibre-library embed_metadata <id>` 在本库打印 `Processed …`、
exit 0，但文件 mtime 与 OPF 的 `dc:title` 都不变（权限、EPUB 结构、prefs 已排除，未深挖）。
**能用的是底层 `ebook-meta`**，先在 `/tmp` 的副本上验证再动库内文件：

```bash
# calibre-web pod 内。值全部取自 metadata.db，保证文件与 DB 一致
ebook-meta "<library>/<path>/<name>.epub" \
  --title "<title>" --authors "<a1> & <a2>" --publisher "<pub>" \
  --isbn "<isbn>" --comments "<html>" --date "2026-04-09T11:20:05+00:00"
```

- ⚠️ **`--date` 要传完整时间戳**：只给日期会按 pod 本地时区（UTC+8）解释再存成 UTC，落地偏
  一天。EPUB 原本的 `dc:date` 就是现成的真值。
- ⚠️ **绕过了 calibre 的记账**：文件体积变了而 `data.uncompressed_size` 不会更新，写完顺手
  `UPDATE data SET uncompressed_size=? WHERE book=? AND format=?`。
- 这会重写书文件，批量做要算 restic 增量代价。

值得做的原因：`book title` / `PDF Reducer Demo version` 这类工具残渣标题只改 DB 是治标，
重新入库就复发；而这类标题在 `scripts/cleanup-duplicates.py` 里被**排除在判重之外**
（标题不携带识别信息，据此判重会把不同的书合并）。

### ☠️ CWA 导入会把多人 `dc:creator` 落成一个作者（名字里带 `|`）

EPUB 只有一个 `<dc:creator>`、内容是 `Neal Ford, Mark Richards, Raju Gandhi` 时，CWA 不拆人，
整串存进 `authors.name` 并把逗号改写成 `|`（calibre 用它表达「姓, 名」排序，撞车了），UI 上
成了一个叫 `Neal Ford| Mark Richards` 的人。同一查询还会捞出 `Hossain| Mir`（calibre 反解了
`Hossain Mir`）、`Edited by` 被当成人、尾随 `;` 进了名字这类。查新增里的：

```sql
SELECT l.book, a.name FROM books_authors_link l JOIN authors a ON a.id = l.author
WHERE l.book > <导入前的 MAX(id)> AND a.name LIKE '%|%';
```

拆开用 `calibredb`（它维护 link 表；直接 UPDATE `authors` 会留下孤儿行），
**多值分隔符是 `&&`**，重音字符（`Catricalà`）过 `kubectl exec` 无损：

```bash
kubectl --context oracle-k3s -n personal-services exec deploy/calibre-web -c calibre-web -- \
  calibredb --with-library=/calibre-library set_metadata <id> \
    --field 'authors:Neal Ford&&Mark Richards&&Raju Gandhi'
```

同理可修 `title`。

☠️ **`set_metadata` 只是三步里的第一步**，单做它会在重建库时静默回滚：

1. 它不重算 `sort` / `author_sort`（calibre-web 按 sort 浏览），要显式带上
   `--field 'sort:…' --field 'author_sort:Last, First'`；
2. `calibredb embed_metadata <id>` 把新值写进书文件自己的 OPF；
3. sidecar `<书目录>/metadata.opf` 前两步都不刷，而 calibre 重建库时信它，旧标题会回来。只能用 calibre API：
   先 `mark_as_dirty(set(ids))` 再 `dump_metadata(ids)`（不标 dirty 时它一个字节都不写还报成功），按 mtime 核验。

⚠️ 集群里的 correct / backfill / llm 作业都用 sqlite 直接写库，**完全不刷 sidecar**；backfill 每周自动跑，
sidecar 因此持续漂移，跑完要重新同步一遍。

⚠️ 值取自**书本身**（`pdftotext -f 1 -l 4` 取版权页 / EPUB 的
`toc.ncx`·`nav.xhtml`），不要凭记忆也不要照抄文件名（文件名里的 `Sana Aburass` 在扉页上是
Sanad Aburass）。
