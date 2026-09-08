# calibre-web 电子书同步

> Last updated: 2026-09-08
>
> ☠️ **calibre 全家在 oracle-k3s**（2026-08-03 迁走），脚本默认 `--context oracle-k3s`；
> 别按「homelab 的书库」去规划。本文是这个流程的真相源，`scripts/README.md` 不再复制它。
> ✅ **2026-09-08 起只有一份实现**：`scripts/sync-ebooks.sh`。原先并存的
> `.claude/skills/sync-ebooks/scripts/sync_ebooks.py` 已删除，它的超时、Running 过滤、
> 全参数化与"失败带原因"都并进了 bash；技能壳只留指针。

自动将本地电子书同步到 calibre-web（ingest 目录 + 入库校验）。

## 快速开始

```bash
# 检查 ~/Downloads/books 中的新书
./scripts/sync-ebooks.sh --check

# 上传新书
./scripts/sync-ebooks.sh --upload
```

## 脚本

`scripts/sync-ebooks.sh` — 本地运行，把文件传到 calibre-web 的 ingest 目录（**唯一**传输
通道；NFS 直传路径已随书库迁 `local-path` 于 2026-07-12 删除）。全部参数跑 `--help`。

☠️ **传输走 `tar | kubectl exec -i`，不是 `kubectl cp`** —— 这不是风格问题：`kubectl cp`
会在非 ASCII 文件名上**退出码 0 却什么都没拷**（实测 1/41 个文件、32% 字节、产出无效 zip），
而书名里中文很常见。传完还逐个比对 sha256（2026-09-08 实测：内容不同 → 非零、
远端缺文件 → 非零、一致 → 0）。别"简化"成 `kubectl cp`。

### ☠️ 2026-09-08 修掉的三个先前缺陷（都是静默的）

合并两份实现时才发现这个脚本**此前根本跑不通**，而四条 `just sync-ebooks*` 配方
一直在空转、没人发现：

| 缺陷 | 症状 | 判据 |
|---|---|---|
| `load_config` 末尾是 `[[ -f conf ]] && source`，配置文件不存在时返回 1 | `set -e` 下**在 main 第二行静默退出**，exit 1、零输出，看着像"没有新书" | `sync-ebooks.conf` 从来不在 git 里 → 任何全新克隆都中招 |
| `validate_epub` 把 `sys.exit(0)` 放在 `try` 里配裸 `except:` | 裸 except 捕获 `SystemExit`，把成功转成失败 → **每本合法 epub 都判"损坏"**，一本都传不上 | 看着像"下载的书全坏了" |
| `is_ebook` 的循环变量 `f` 没 `local`，而调用方 `do_check` 的循环变量也叫 `f` | 一返回 `$f` 就从全路径变成 `"epub"` → 校验报文件不存在；侥幸过关的会把字面量 `epub` 写进 pending.txt | 症状指向"文件坏了"，与真因无关 |

三条共同点：**没有任何一条会报错**，都只是让结果变空或变错。所以改这个脚本后
必须真跑一轮 `--check` 看分类数对不对，`bash -n` 通过不算验证过。

## K8s CronJob

⚠️ **calibre 全家 2026-08-03 迁到 oracle-k3s**，这个 CronJob 跟着走了：清单与集群都变了。

`cloud/oracle/manifests/personal-services/calibre-ebook-sync.yaml`（CronJob 名
`ebook-sync-monitor`，`personal-services` ns，**oracle-k3s**）— 每 6h 在 pod 内运行健康检查：

- 统计 ingest 堆积
- 查询数据库新增
- 上报磁盘用量
- ingest > 50 文件堆积时标记为失败

该文件由 ArgoCD **`oracle-k3s`** App（kustomize 树 `cloud/oracle/manifests/`）管理，改动走 GitOps：

```bash
git add cloud/oracle/manifests/personal-services/calibre-ebook-sync.yaml
# ⚠️ kustomize 树是显式 resources: 列表——新增文件还要登记进同目录的 kustomization.yaml
git commit -m "chore(calibre): 更新 ebook-sync 监控"
git push   # ArgoCD 3 分钟内自动同步

kubectl --context oracle-k3s -n personal-services get cronjob ebook-sync-monitor
```

⚠️ **不要手动 `kubectl apply`**：该树归 `oracle-k3s` App（prune+selfHeal+SSA），手动应用会被 ArgoCD 改回去。

## 传输流程

```
本机 ~/Downloads/books/ ──(tar | kubectl exec -i + sha256 校验)──→ pod /cwa-book-ingest/ ──→ calibre-web 自动入库
```

## 去重

同一本书常以不同标题/格式反复入库（`:` 被文件名清洗成 `_`、副标题有无、EPUB 和 PDF 各一条）。

```bash
cd k8s/helm
just cleanup-calibre-dry-run      # 先看判定：谁保留、谁删除、哪些格式会合并
just cleanup-calibre-duplicates   # 交互确认后执行（会先校验 metadata.db 备份）
just cleanup-logs                 # 历史清理记录
```

`scripts/cleanup-duplicates.py` 做归一化标题匹配（不是完全同名）、把同一本书的 EPUB/PDF
合并成一个条目、用 pod 内的 `calibredb` 删除（会清 link 表，书移入 `.caltrash`，14 天可恢复）。

☠️ **「14 天可恢复」的前提是 `calibredb remove <id>` 不带 `--permanent`**。带上了就直接删书文件、
不进 `.caltrash`，上面那句承诺当场失效（2026-09-07 手删 3 条时踩到：`.caltrash` 里查无此书，
只能走 restic 夜备恢复整个书库目录，而 restic 是**整库回滚**粒度，捞单本书要把快照 restore 到别处再挑）。
手动删书请走 `just cleanup-calibre-duplicates`；真要手敲 `calibredb remove`，先确认不带 `--permanent`，
并且删前把 `id`/`title`/`pubdate` 打出来核对一遍——`remove` 是连目录一起删，写错 id 毁的是书不是行。

☠️ **两条只能靠人看的**：Manning `MEAP` 是预售草稿，要输给无版本标记的正式版（哪怕草稿文件大得多）；
`... Workbook` 这类配套分册标题前缀与主书完全一致，会被模糊匹配判成重复。
判据别只盯 pubdate：**「新下载的那本」完全可能就是草稿**，库里那条反而是成品（2026-09-07：
本地 `Grokking Machine Learning, Second Edition (MEAP v3)` 的 `toc.ncx` 只到第 10 章，
而库里那条尾号 513 页的 2021 年 PDF 是完整第 1 版——按「新版覆盖旧版」删旧的就亏了）。
数一下 TOC 章数 / 页数再决定删谁。
判定依据与踩坑全文 → [records/2026-08-18-calibre-dedup-stale-paths.md](../records/2026-08-18-calibre-dedup-stale-paths.md)。

## 元数据补全

导进来的书元数据往往不全（书名是文件名、无简介无标签、作者 Unknown）。
补全走 [calibre-metadata-enrichment.md](calibre-metadata-enrichment.md)：
四层手段、各自实测产出率、以及什么时候该停。

> ⚠️ 此前这里指向 `plans/archive/2026-07-05-calibre-metadata-enrichment.md`（2026-08-13 归档前在 `plans/apps/`）。
> 那是**写完即冻结的历史快照**，且其「环境」一节已过期（书库早已不在 NFS 上），
> 更重要的是它描述的做法（查不到就拿文件 mtime 当出版日期）**已被证明有害**并弃用。
