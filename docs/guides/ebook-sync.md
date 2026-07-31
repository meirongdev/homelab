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

`k8s/helm/manifests/personal-services/calibre-ebook-sync.yaml` — 每 6h 在 pod 内运行健康检查：

- 统计 ingest 堆积
- 查询数据库新增
- 上报磁盘用量
- ingest > 50 文件堆积时标记为失败

该文件由 ArgoCD `personal-services` App 管理（目录 `k8s/helm/manifests/personal-services/`），改动走 GitOps：

```bash
git add k8s/helm/manifests/personal-services/calibre-ebook-sync.yaml
git commit -m "chore(calibre): 更新 ebook-sync 监控"
git push   # ArgoCD 3 分钟内自动同步
```

⚠️ **不要手动 `kubectl apply`**——该目录归 `personal-services` App（prune+selfHeal+SSA），手动应用会被 ArgoCD 改回去。

## 传输流程

```
本机 ~/Downloads/books/ ──(kubectl cp + sha256 校验)──→ pod /cwa-book-ingest/ ──→ calibre-web 自动入库
```

## 元数据补全

参考 `docs/plans/apps/2026-07-05-calibre-metadata-enrichment.md`。
