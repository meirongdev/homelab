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

`scripts/sync-ebooks.sh` — 本地运行，通过 NFS 或 kubectl cp 将文件传到 calibre-web ingest 目录。

详细用法见 `scripts/README.md`。

## K8s CronJob

`k8s/helm/manifests/calibre-ebook-sync.yaml` — 每 6h 在 pod 内运行健康检查：

- 统计 ingest 堆积
- 查询数据库新增
- 上报磁盘用量
- ingest > 50 文件堆积时标记为失败

部署：

```bash
kubectl apply -f k8s/helm/manifests/calibre-ebook-sync.yaml
```

## 传输流程

```
本机 rsync ─→ NFS /storage/calibre/ingest/ ─→ pod /cwa-book-ingest/ ─→ calibre-web 自动入库
  ↑ (失败时降级到 kubectl cp)
```

## 元数据补全

参考 `docs/plans/2026-07-05-calibre-metadata-enrichment.md`。
