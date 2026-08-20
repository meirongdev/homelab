# Calibre 元数据补全

给书库补元数据的**全部有效手段**，按「先可靠后不可靠」排序，以及各自的实测产出率与
适用边界。架构事实（当前覆盖率、已知污染、各作业内部设计）在
[reference/calibre-metadata.md](../reference/calibre-metadata.md)，本文只讲**怎么做、
用哪个、什么时候停**。

书库在 oracle-k3s `personal-services`，PVC `calibre-books-local`。

## 新导入的书会自动补吗？

**部分会。** 分界是「**只填空、绝不覆盖、幂等**的可以自动跑；会覆盖或会生成的必须手动」：

| 作业 | 自动 | 说明 |
|---|---|---|
| `calibre-metadata-updater` | ✅ 每夜 04:00 UTC | 只从**文件内嵌**抠封面，零网络 |
| `calibre-metadata-backfill` | ✅ **每周日 06:00 UTC** | 标识符/简介/标签/出版社，新书优先 |
| `calibre-metadata-correct` | ❌ 挂起 | 会覆盖已有值，跑前要人备份并核对 |
| `calibre-metadata-covers` | ❌ 挂起 | 产出低（13/54）且烧配额 |
| `calibre-metadata-llm` | ❌ 挂起 | 生成内容而非查证，必须人工核样本 |
| CWA `auto_metadata_fetch` | ❌ 关闭 | 盲取第一条无校验，见 reference |

⚠️ **定时跑的 backfill 用的是另一套参数**（`ORDER_MODE=newest` / `RECENT_DAYS=30`
/ `LIMIT=150`），三个是一套，别单独改：默认的 `ORDER BY id` 升序配上 `LIMIT`，
每次都是同一批最低 id 的老书 —— 那批恰恰是反复失败的硬骨头，**新导入的书 id 最大、
永远轮不到**，定时就成了空转。手动全量跑存量时才用 `ORDER_MODE=id` + `RECENT_DAYS=0`。

06:00 UTC 避开了 readlist ingest 01:20（**共用同一份 Google Books 配额**）、
restic 备份 03:00、updater 04:00。

下面各层仍可随时手动派生一次运行。

---

## 先决断：这本书缺什么，就用哪一层

四层手段互不替代，**产出率逐层下降、可信度也逐层下降**。上一层能解决的，
绝不要用下一层——下面每一层都比上一层更容易出错。

| 层 | 手段 | 数据来源 | 可信度 | 2026-08 实测产出 |
|---|---|---|---|---|
| 1 | **内嵌封面提取** | 电子书文件自身 | 权威 | 每夜自动，覆盖绝大多数 |
| 2 | **外部查询**（回补） | Google Books / OpenLibrary | 权威 | 3,600+ 字段 |
| 3 | **按 ISBN 锚定修正** | Google Books | 权威 | 修 253 条日期 + 145 作者/书名 |
| 4 | **LLM 从内容生成** | 书的正文 | **生成物** | 209 本 |

⚠️ 第 4 层与前三层**性质不同**：它生成内容而非查回事实。所以它写的每一条都带
`#meta_src = llm-from-content` 标记。**不要把它当成前三层的延伸**——见文末「为什么必须标出处」。

---

## 第 1 层：内嵌封面（全自动，无需操作）

`calibre-metadata-updater` CronJob 每夜 04:00 UTC 跑，用 `ebook-meta --get-cover`
从电子书文件里抠封面。零网络、零外部依赖。

只有它拿不到的（文件里本来就没有封面）才需要第 1.5 层。

### 1.5 封面在线补全

```bash
kubectl --context oracle-k3s -n personal-services create job covers-1 \
  --from=cronjob/calibre-metadata-covers
kubectl --context oracle-k3s -n personal-services logs -f job/covers-1
kubectl --context oracle-k3s -n personal-services delete job covers-1
```

实测 54 本缺封面 → 补上 13 本（其余 34 本无任何标识符查不了、7 本 Google 侧也没图）。

⚠️ 两个坑，别重新发现：
- **`fetch-ebook-metadata --cover` 在本环境拿不到封面**（Google 与 Google Images
  两种源、150s 超时都试过，产出为空）。只能走 Google Books API 直取 `imageLinks`。
- **默认 `thumbnail` 只有约 16KB（~128px）**，在 calibre-web 网格里发虚。
  URL 参数改成 `w=800` 能拿到 45–64KB，约 5 倍 —— 不必换源。

---

## 第 2 层：外部查询回补（主力，只填空）

`calibre-metadata-backfill`：**只填当前为空的字段**，绝不覆盖。
写 `identifiers` / `comments` / `tags` / `publisher`，**不碰** `pubdate` / `title` / `authors`。

```bash
kubectl --context oracle-k3s -n personal-services create job backfill-1 \
  --from=cronjob/calibre-metadata-backfill
kubectl --context oracle-k3s -n personal-services logs -f job/backfill-1
kubectl --context oracle-k3s -n personal-services delete job backfill-1
```

内部按三级策略依次尝试（可靠性递减）：

1. **库内已有 ISBN** → 按标识符精确查，不过标题门；
2. **从书自身内容挖 ISBN** → 版权页/OPF 里印着的 ISBN 是 ground truth，
   专治「书名把主副标题连成一串、Google 匹不上」那批。**不需要 LLM**；
3. **按标题+作者查** → 最不可靠，要过方向感知的标题门。

### 什么时候停

**命中率逐轮衰减，第四轮就不值得跑了**：

| 轮次 | 处理 | 命中 | 命中率 | 实际写入 identifier |
|---|---|---|---|---|
| 1 | 1,746 | 1,053 | 70% | 1,704 |
| 2 | 867 | 338 | 39% | 487 |
| 3 | 624 | 105 | 19% | 19 |
| 4 | 613 | 96 | 16% | **4** |

第 3 轮起「命中」多是「本来就有 ISBN、只补了零星标签」，边际收益接近零。
**判据看写入数不看命中数。**

---

## 第 3 层：按 ISBN 锚定修正（会覆盖已有值）

`calibre-metadata-correct`：**只处理有 ISBN 的书**，修正已知错误值。
ISBN 覆盖率从 35% 涨到 77% 之后这条路才成立——修改锚在标识符上，不靠模糊匹配。

☠️ **跑写入模式前先备份**：

```bash
kubectl --context oracle-k3s -n personal-services exec deploy/calibre-web -c calibre-web -- \
  sh -c 'sqlite3 /calibre-library/metadata.db ".backup /calibre-library/metadata.db.bak-$(date +%Y%m%d-%H%M%S)"'

kubectl --context oracle-k3s -n personal-services create job correct-1 \
  --from=cronjob/calibre-metadata-correct
```

四类，各有独立准入判据（`DO_AUTHOR` / `DO_PUBDATE` / `DO_FILENAME_TITLE` /
`DO_PAREN_TITLE` 四个开关可分批推进）：

| 类 | 只在什么条件下写 |
|---|---|
| A 作者 | 当前是 `Unknown`/空 —— **不覆盖任何真实作者名** |
| B 日期 | 当前是年份粒度（`MM-DD=01-01`）**且对方给出带月日的完整日期**。对方也只有年份就不换——那是拿一个猜测换另一个猜测 |
| C 书名 | 只认明显文件名特征（三点分隔 / ASIN / 纯大写 ID），宁漏不错 |
| D 括号 | 拿 ISBN 查回权威书名，**括号内容在其中出现过半就保留** |

D 类那条判据不能省：本库尾括号有三种互斥含义（作者名 / 收藏标记 / **书名的一部分**），
盲删会毁掉 `What to Do (and NOT Do) in 75+…` 这类真书名。

---

## 第 4 层：LLM 从内容生成（最后手段）

`calibre-metadata-llm`：只用于**外部数据库里根本没有**的书——自出版、Kindle 独占、
zine（如 wizardzines）。前三层都查不到它们，因为它们客观上不在任何公开书目库里。

**前置：DGX vLLM 必须活着，且跨集群入口已恢复。** oracle 直连不到 DGX，此前走
`dgx-proxy`（**2026-08-08 已随网关退役**，`calibre-metadata-llm` 已 suspend，
其 `LLM_URL` 曾指向已随网关退役的 dgx-proxy）。恢复步骤：LiteLLM 网关落地 →
把 `calibre-metadata-llm` 的 `LLM_URL` 指到新网关 → 解除 suspend → 先跑一轮
`DRY_RUN=1`（见下节）。**入口没恢复前不要直接 create job**，这条链路跑不了。

原委见 [reference/tailscale-network.md](../reference/tailscale-network.md)
的「Tagged devices cannot reach shared nodes」。

恢复后手动跑一轮：

```bash
kubectl --context oracle-k3s -n personal-services create job llm-1 \
  --from=cronjob/calibre-metadata-llm
```

写入纪律比前三层**更严**：`comments`/`tags` 仅当为空；`title` 仅当现有书名像文件名；
`authors` 仅当现有是垃圾值。且每条写入都打 `#meta_src = llm-from-content`。

### ⚠️ 改任何东西之后先翻回 DRY_RUN

`DRY_RUN=1` 不是形式。2026-08-07 跑了**三轮**才敢置 0，每轮抓到的问题都不同：

| 轮 | 发现 |
|---|---|
| 1 | 崩在 `content=None` —— 推理模型的 `max_tokens` 被推理阶段吃光，`content` 是 null 而非空串，`KeyError` 捕不到 |
| 2 | 20/20 有产出，但审计发现把**章节标题**当书名（`Reciprocity.Evolution…` → `Basic Game Theory`）|
| 3 | 加书名护栏后复验：该拦的拦下、该过的仍过 |

**轮 2 那个错单看日志发现不了**——输出格式完全正确、字段齐全，只有拿文件名里的
真实词去比对才看得出它读错了页。所以审计要看内容，不能只看「有没有报错」。

---

## 为什么第 4 层必须标出处

本库已经吃过一次「编出来的值被下游当成证据」的亏：

2026-07 那轮回补在查不到时**拿文件 mtime 当出版日期**。结果 487 本 pubdate 被写成
看起来像真数据的值，而 calibre **没有 provenance 字段**，事后无从分辨。下游 readlist
只能靠猜「`MM-DD` 是不是 `01-01`」，2,045 本里只认得出 37 本，其余全被它标记为
`SourceCalibre —— 不可信`。

所以现在有两个自定义列：

| 列 | 值 | 含义 |
|---|---|---|
| `#pubdate_src` | `google-isbn` | 该日期是按 ISBN 查回的权威值 |
| `#meta_src` | `llm-from-content` | 该书的元数据是模型从正文生成的 |

**没有标记 = 来源不明的历史数据。** 这个区分是不可逆污染与可审计数据之间唯一的界线。

---

## 停止判据

跑到什么程度算够？

- **第 2 层**：看**写入数**不看命中数。单轮写入 identifier < 20 就该停。
- **第 3 层**：候选池（命中判据的书）降到两位数即可停。
- **第 4 层**：末轮只补到个位数就该停。实测三轮 166 → 39 → 4。
- **客观下限**：2026-08-08 全部跑完后仍有 **26 本**毫无元数据，其中 21 本
  **取不到正文**（PDF 无文本层、EPUB 无 spine 正文）—— 四层手段全部无效，
  只能人工录入或接受缺失。起始时这类是 236 本。

## 相关文档

- [reference/calibre-metadata.md](../reference/calibre-metadata.md) —— 覆盖率现状、
  已知污染、各作业内部设计与判据全文
- [guides/ebook-sync.md](ebook-sync.md) —— 把书导进书库（本文的上游）
- [reference/tailscale-network.md](../reference/tailscale-network.md) —— 第 4 层
  跨集群入口的机制与退役经过
