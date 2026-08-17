# calibre 去重：过期的 books.path 被当成"空壳记录"，差点删掉活文件；旧脚本只认完全同名

> 日期: 2026-08-18
> 影响: 书库 2083 → **2025** 本，磁盘孤儿文件 → 0。过程中**真的误删了 20 本**（判定它们
>       "文件已丢失"，实际文件都在磁盘上、只是目录名对不上），同一天从磁盘 + 删除前的 DB
>       快照全部恢复，最终无数据丢失。另有 3 处近失在执行前被磁盘核对拦下
>       （`Principles of Web API Design` 的 20MB EPUB、`React Application Architecture`
>       的 11MB PDF、`NGINX Cookbook` 第 3 版）。
> 根因: 四个独立问题。① 旧 `cleanup-duplicates.sh` 用 `GROUP BY title HAVING COUNT(*)>1`
>       做**完全同名**匹配，60 组重复只认出 6 组。② calibre 的 `books.path` 会过期（改作者名
>       重写目录但 `path` 不跟；标题含换行时 DB 存字面 `\n` 而磁盘上被清洗成空格），于是
>       "按 path 找不到文件"被误读成"这条记录没有文件"。③ 补救用的 basename 索引只校验目录名
>       末尾的 `(id)`，而这个库有 **id 被复用**的历史目录，只按 id 采信会把别人的文件挂错书。
>       ④ metadata.db 是 **WAL 模式**，`cat metadata.db` 拿到的是落后快照，而字节数与
>       `integrity_check` 都照样通过——备份"已校验"是假的。
> 结果: 旧 `.sh` 删除，重写为 `scripts/cleanup-duplicates.py`（归一化匹配 + 磁盘核对 +
>       格式合并 + `calibredb`），带离线回归断言（含 id 复用必须被拒的用例）；备份改用
>       `sqlite3 .backup` 且以 **books 行数与现网一致**为校验条件。4 处文档错误同步修正。

## 旧脚本的四个缺陷（都由这次实测确认）

| # | 缺陷 | 实测后果 |
|---|------|---------|
| 1 | 只认**完全同名** | 同一库上它报 6 本，归一化扫描是 **60 组 / 61 本**。`:` vs `_`、连字符 vs 破折号、少空格、含换行、有无副标题——全部漏掉 |
| 2 | `DELETE FROM books WHERE id=N` | 只删 DB 行。`books_authors_link` / `books_tags_link` / `data` / `comments` 留孤儿行，**书文件留在磁盘上**，库目录只增不减 |
| 3 | 错误被 `2>/dev/null \|\| true` 吞掉 | 删除失败照样报成功；**备份 `kubectl cp` 失败也不阻止删除** |
| 4 | 无脑保留最小 id | 多组判错。例：会删掉 `Practical Systems Programming in Go` id=2080（EPUB+PDF，5.5MB）去保留 id=1978（仅 EPUB，1.8MB） |

补一条已核实的**非**缺陷：默认 context 虽然还写着已迁走的 `k3s-homelab`（第 4 行），但
`set -euo pipefail` 会在取不到 pod 时硬失败（exit 1），**不会**假报"没有重复书籍"。

## ☠️ 核心教训：path 指不到文件 ≠ 文件没了

这是唯一一条静态检查查不出、只能靠流程拦的：

```
DB:   Alickovic, Alan;/React Application Architecture for Production (1084)/...pdf   ← 找不到
磁盘: Alan Alickovic/React Application Architecture for Production (1084)/...pdf     ← 文件在这
```

换行的情况更隐蔽——DB 里是字面换行，磁盘目录里是空格：

```
DB:   Daniel Afonso/State Management with\nReact Query (1317)/...epub   ← 找不到
磁盘: Daniel Afonso/State Management with React Query (1317)/...epub    ← 文件在这
```

**任何"文件不存在 → 这条是空壳 → 保留另一份"的逻辑都必须先做路径救援**：依次试
①DB 原路径 ②换行换成空格/下划线的变体 ③全库 basename 索引。

⚠️ 第 ③ 步的护栏要**两条同时成立**：命中路径的父目录名以 `(<book_id>)` 结尾，**且**目录名的
标题部分与该书标题归一化后前缀相符。只校验 `(id)` 是不够的——本库存在 **id 被复用**的历史目录
（`JavaScript Design Patterns (1513)`，而现役 1513 是 `Building Your Own JavaScript Framework`，
两本毫无关系），只按 id 采信就会把别人的文件挂到这本书上。两种情形都有回归断言守着。

## ☠️ 第二个坑：`cat metadata.db` 的备份是假的（WAL）

书库的 metadata.db 跑在 **WAL 模式**。最近的事务都在 `metadata.db-wal` 里（实测 2.8MB），
主库文件的 mtime 可以停在几小时前。于是：

```
cat /calibre-library/metadata.db > backup.db     # 拿到的是落后快照
字节数比对        ✅ 通过   ← SQLite 删行不缩容，大小可能一模一样（实测两次都是 7135232）
integrity_check   ✅ 通过   ← 落后的快照本身是完整的
books 行数        ❌ 2083 而现网 2022
```

**只有比行数才发现得了。** 正确做法是 `sqlite3 <db> ".backup <dest>"`（online-backup API，
含 WAL），并以「备份里的 books 行数 == 现网」为校验条件。字节数 + integrity_check 会让你
以为备份"已校验"。

## 只能靠人判断的三条

静态规则写不出来，每次去重都得看一眼：

- **Manning MEAP 是预售草稿，要输给无版本标记的正式版**——哪怕 MEAP 文件大得多
  （`The Art of Code`：MEAP 24MB vs 正式版 1.47MB，后者 248 页完整，只是纯文本压得好）。
  按"保留大文件"会留下草稿。
- **配套分册不是重复本**。`Automate the Boring Stuff with Python` 和它的 `... Workbook`
  标题前缀完全一致，模糊匹配必然判成重复。脚本按 `workbook/companion/solutions/exercises`
  排除，但新出现的配套词还得人看。
- **跨版本不要合并格式**。1st 版的 EPUB 挂到 2nd 版条目下 = 一个条目里两份不同内容的书。

## 误删 20 本与恢复过程（最该记住的一段）

判完重复之后我把 22 个"文件已丢失"的条目删了（20 个格式行指不到文件 + 2 个完全无格式记录）。
删之前做过全库 basename 搜索，结论是"真的不存在"。**这个结论是错的。**

错在 basename 索引拿 `data.name` 当键，而这些书的**文件早先被改名过、DB 的 `name` 没跟上**：

```
DB  data.name : Web Data Mining with Python_ Discover and extract in - Dr. Ranjana Rajnish
磁盘上的文件  : Web Data Mining with Python - Dr. Ranjana Rajnish.epub
```

basename 对不上 → 判为不存在。真正该用的信号是**目录名里的 `(id)`**，不是文件名。

发现方式：删完之后扫"磁盘上有书文件但无 DB 引用的目录"，跳出 31 个、381.7MB。恢复：
把删除前的 DB 快照送进 pod，按目录名的 `(id)` 回查标题/作者/标签/简介，
`calibredb add` + `set_metadata` 逐本重建。31 本全部恢复，其中

- **20 本是我误删的**——全部完好回归；
- **1 本是版本回归**：`NGINX Cookbook-3rd (1465)` 的 DB 标题里没有版本标记，被我的版本规则
  当成"更旧的一版"删掉，实际它是**第 3 版**。恢复并改名为 `NGINX Cookbook, 3rd Edition` 后，
  去重工具按版本规则正确地留下第 3 版、删掉第 2 版；
- **10 本**是更早的清理留下的孤儿文件（含 id 复用目录）。恢复后其中 5 本与库中现有条目重复，
  再跑一次去重被正常合并掉。

**教训**：删记录之前，"磁盘上有没有无主的书文件"这个反向检查和"记录指不到文件"一样重要。
单向核对只能发现一半问题。

## 遗留（有意不处理）

- `.caltrash` 约 687MB：今天删掉的书都在 calibre 回收站，**默认 14 天后自动过期**，期间可恢复。
  磁盘 37%（还剩 124G）没有压力，而今天已经用到过一次恢复——这条退路故意留着，不清。
- **25 本作者是 `Unknown`**（其中 2 本是把 `welcome.html` / `chapter-1.html` 这种 HTML 抓取
  残渣改回 `Unknown` 的——查不出真作者就不猜）。这属于元数据补全的活，走
  [guides/calibre-metadata-enrichment.md](../guides/calibre-metadata-enrichment.md)。
- `docs/RULES.md` 把 R3 标为脚本强制，但 `check-docs.py` 的 `check_frontmatter()`
  **没有 `records` 分支**——records/ 的「日期+影响+根因」实际没人查（实测删掉本文的 `根因`
  仍然通过）。补检查会让 4 篇旧 record 不合规（`2026-03-09-oracle-k3s-outage-report`、
  `2026-06-07-zitadel-console-grpc-404` 缺全部三项；`2026-03-15-cilium-hubble-tls-issue`、
  `2026-07-12-pve-screen-backlight-always-on` 缺「影响」），故留待决定。

## 相关

- 工具：`scripts/cleanup-duplicates.py`（`cd k8s/helm && just cleanup-calibre-dry-run`）
- 同步侧：[guides/ebook-sync.md](../guides/ebook-sync.md) · 元数据：[reference/calibre-metadata.md](../reference/calibre-metadata.md)
- 同类"报成功但什么都没做"：`sync_ebooks.py` 也只信 `kubectl cp` 的退出码，不核对落地字节数
