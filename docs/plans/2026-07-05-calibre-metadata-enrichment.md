# Calibre 元数据补全方案

> 清理 Calibre 图库时发现约 1,500+ 本书缺少发布年份（pubdate=0101-01-01）。本方案旨在系统性地补全所有电子书的元数据。

## 现状

| 指标 | 值 |
|------|-----|
| 总藏书 | 2,032 本 |
| 有 ISBN 的 | 725 本（35.7%） |
| 元数据完整（有发布年份） | ~500 本 |
| 缺少发布年份 | ~1,500+ 本 |

缺年份主因：CWA 自动导入时未能从电子书文件中提取到发布日期，而 `ebook-meta` 对 PDF 的日期提取能力有限。

## 环境

- Calibre 库位于 NFS：`192.168.50.106:/storage/calibre`（`metadata.db`）
- Calibre Web 运行在 k3s-homelab 集群 `personal-services` 命名空间
- 使用镜像 `crocodilestick/calibre-web-automated`（含 `ebook-meta` 和 Python3）

## 阶段一：从文件自身提取

扫描 Calibre 库中所有书的目录，对每本书：

1. 用 `ebook-meta` 提取文件元数据
   - EPUB/MOBI/AZW3：可提取 title、author、ISBN、publisher
   - PDF：日期字段通常缺失，但 ISBN 可用于后续查询
2. 将 ISBN 写入 `identifiers` 表（如果缺失）
3. 记录有哪些书有 ISBN 可用于后续在线查询

输出：待查 ISBN 列表。

## 阶段二：在线元数据查询

利用 ISBN 或 书名+作者 查询在线 API 获取出版日期。

### 数据源对比

| 数据源 | 优点 | 限制 |
|--------|------|------|
| **OpenLibrary API** | 免费、无需 key、容量大 | 对小众书/技术书覆盖率一般 |
| **Google Books API** | 数据最全、技术书覆盖好 | 免费配额 1,000 次/天 |
| **ISBNdb / WorldCat** | 精准 | 需付费 API key |

### 推荐策略

1. 优先 OpenLibrary（免费、不限速）：约 725 本有 ISBN，加 0.5s 间隔约 6 分钟查完
2. OpenLibrary 查不到的回退到 Google Books API：使用书名+作者搜索
3. 都查不到的标记为 "需要人工确认"

## 阶段三：文件时间戳兜底

对 ISBN 和书名都查不到的书，使用 NFS 上文件的 **mtime** 作为出版日期的粗略参考。

虽然 mtime 不等于出版日期，但：
- mtime > 10 年前的，基本可以确认是旧书
- 对有明确出版年份需求（如清理 10 年以上的书）足够使用

## 实施方式

在 k3s 集群中运行一次性 Job：

```
k8s Job: calibre-metadata-enrich
  镜像: crocodilestick/calibre-web-automated
  挂载: /calibre-library (NFS PVC)
  流程:
    1. 扫描所有 pubdate=0101-01-01 的书籍
    2. 对每本书执行文件元数据提取
    3. 对有 ISBN 的发起在线查询
    4. 更新 metadata.db
    5. 记录处理统计
```

Job YAML 和脚本与现有 `calibre-metadata-updater` CronJob 同目录维护。

## 清理（前置阶段）

作为本次操作的前置阶段，已清理 5 本确认发布超 10 年的图书：

| 书名 | 作者 | 发布时间 |
|------|------|----------|
| Cracking the Coding Interview 6th Ed | Unknown | 2016-06-08 |
| Grokking Algorithms | Aditya Y. Bhargava | 2016-05-12 |
| Absolute Beginner's Guide to Minecraft Mods Programming | Rogers Cadenhead | 2015-10-01 |
| Ansible for DevOps | Jeff Geerling | 2014-02-20 |
| Learning JavaScript Design Patterns | Addy Osmani | 2012-07-08 |
