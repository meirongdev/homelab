# calibre-web 电子书同步

自动将本地电子书同步到 calibre-web。

## 快速开始

```bash
# 检查 ~/Downloads/books 中的新书
./scripts/sync-ebooks.sh --check

# 上传新书
./scripts/sync-ebooks.sh --upload
```

## 脚本

`scripts/sync-ebooks.sh` — 本地运行，通过 `kubectl cp` 将文件传到 calibre-web ingest 目录（**唯一**传输通道；NFS 直传路径已随书库迁 `local-path` 于 2026-07-12 删除）。

详细用法见 `scripts/README.md`。

## K8s CronJob

⚠️ **calibre 全家 2026-08-03 迁到 oracle-k3s**，这个 CronJob 跟着走了 —— 清单与集群都变了。

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

⚠️ **不要手动 `kubectl apply`**——该树归 `oracle-k3s` App（prune+selfHeal+SSA），手动应用会被 ArgoCD 改回去。

## 传输流程

```
本机 ~/Downloads/books/ ──(kubectl cp + sha256 校验)──→ pod /cwa-book-ingest/ ──→ calibre-web 自动入库
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

☠️ **两条只能靠人看的**：Manning `MEAP` 是预售草稿，要输给无版本标记的正式版（哪怕草稿文件大得多）；
`... Workbook` 这类配套分册标题前缀与主书完全一致，会被模糊匹配判成重复。
判定依据与踩坑全文 → [records/2026-08-18-calibre-dedup-stale-paths.md](../records/2026-08-18-calibre-dedup-stale-paths.md)。

## 元数据补全

导进来的书元数据往往不全（书名是文件名、无简介无标签、作者 Unknown）。
补全走 **[calibre-metadata-enrichment.md](calibre-metadata-enrichment.md)** ——
四层手段、各自实测产出率、以及什么时候该停。

> ⚠️ 此前这里指向 `plans/archive/2026-07-05-calibre-metadata-enrichment.md`（2026-08-13 归档前在 `plans/apps/`）。
> 那是**写完即冻结的历史快照**，且其「环境」一节已过期（书库早已不在 NFS 上），
> 更重要的是它描述的做法（查不到就拿文件 mtime 当出版日期）**已被证明有害**并弃用。
