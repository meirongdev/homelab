---
name: sync-ebooks
description: Sync local ebook files into the homelab calibre-web (cwa) ingest folder running on Kubernetes — validates integrity, de-dupes against the library, transfers into the pod with sha256 verification, and keeps a backup. Use when the user wants to sync/upload/import ebooks or books into calibre-web, or mentions calibre ingest, "同步电子书", "上传电子书到 calibre", or the book.meirong.dev library.
---

# Sync ebooks → calibre-web

**改流程请改 [docs/guides/ebook-sync.md](../../../docs/guides/ebook-sync.md)，不要改本文件。**
本文只是让 agent 发现这个流程的壳 + 几条最容易踩的硬约束。

唯一实现是 **`scripts/sync-ebooks.sh`**（2026-09-08 起；此前并存的
`.claude/skills/sync-ebooks/scripts/sync_ebooks.py` 已删除，能力已并入 bash —— 见
[ROADMAP 开放项 #15](../../../docs/ROADMAP.md) 的收口）。

## 快速开始

先看再传，两步：

```bash
./scripts/sync-ebooks.sh --check                 # 只分类，不传
./scripts/sync-ebooks.sh --upload                # 传（会交互确认）
```

默认目标是 oracle-k3s 的 calibre-web，常见场景只需要 `--source`。
全部参数跑 `--help`（`--context/--namespace/--selector/--ingest-path/--db-path/
--backup-dir/--exts/--timeout/--cp-timeout/--no-filter-non-ebooks/--cleanup/--verbose`）。

## 硬约束（错了通常静默失效）

- ☠️ **传输走 `tar | kubectl exec -i`，不是 `kubectl cp`，且传完逐个比对 sha256。**
  `kubectl cp` 会在非 ASCII 文件名上**退出码 0 却什么都没拷**（实测 1/41 个文件、32% 字节、
  产出无效 zip）。所以别"顺手改成 kubectl cp 更简单"。校验和这一步 2026-09-08 已实测：
  内容不同 → rc=1、远端缺文件 → rc=1、一致 → rc=0。

- ⚠️ **去重是启发式的**（文件名推标题 vs DB 标题，忽略 `(author)`/`[tag]` 后缀和尾部
  ` - author`）。它会误判：曾把 11 本里的 5 本误判成重复。`--check` 的输出要人眼过一遍，
  别只看数字。

- ☠️ **数据库读不到就必须中止，不能当成空书库**。没有标题列表 = 去重被绕过 = 整批重复入库。
  脚本现在会 abort（含"查询成功但 0 个标题"这种情形）。

- ⚠️ **ingest 目录空不代表传失败**：calibre-web-automated 入库后会把文件从 ingest 移走。
  判据看书库 DB 的书数变化（脚本上传后会自动打印前后对比），不是 ingest 列表。

- ⚠️ 大写扩展名（`.PDF`）本脚本能识别（`find -iname` + 扩展名转小写），
  但 **CWA 自己的 ingest 匹配是区分大小写的**：真进了 ingest 目录却不被识别时，
  在 pod 内把文件名改成小写以触发一次新的 inotify 事件。

- ☠️ calibre 的 `books.path` 指不到文件**不等于**文件没了（作者改名会让路径失效；标题含
  换行时 DB 存字面量而磁盘目录是净化过的）。把这种记录当空的会删掉活文件。
  → [records/2026-08-18-calibre-dedup-stale-paths.md](../../../docs/records/2026-08-18-calibre-dedup-stale-paths.md)

## 别搞混的三个东西

| 东西 | 是什么 |
|---|---|
| `scripts/sync-ebooks.sh` | **本文这个**：本机跑，把书传进 ingest。`just sync-ebooks*` 四条配方调它 |
| `cloud/oracle/manifests/personal-services/calibre-ebook-sync.yaml` 里内嵌的 `sync-ebooks.sh` | **同名但完全是另一个脚本**（80 行、0 次 kubectl）：CronJob `ebook-sync-monitor` 每 6h 在 pod 内跑的健康检查。走 GitOps 改 |
| `scripts/cleanup-duplicates.py` | 删库里的重复条目（`just cleanup-calibre-dry-run`），不负责同步 |
