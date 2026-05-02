# calibre-web 电子书同步系统

自动从本地目录同步电子书到 calibre-web 的工具和 Kubernetes 部署。

## 📚 功能

- ✅ 监视 `~/Downloads/books` 目录
- ✅ 自动导入新的电子书到 calibre-web
- ✅ 支持多种格式 (PDF, EPUB, MOBI, AZW, AZW3)
- ✅ 可选备份已导入的文件
- ✅ 可选导入后删除本地副本
- ✅ 详细的日志记录
- ✅ K8s CronJob 自动执行

## 🚀 使用方法

### 本地脚本使用

在本地运行电子书同步脚本（需要 kubectl 访问权限）：

#### 查看帮助
```bash
./scripts/sync-ebooks.sh --help
```

#### 测试模式 (查看会做什么，但不实际执行)
```bash
./scripts/sync-ebooks.sh --dry-run
```

#### 导入并备份
```bash
./scripts/sync-ebooks.sh --backup
```

#### 导入、备份并删除本地文件
```bash
./scripts/sync-ebooks.sh --backup --cleanup
```

#### 导入但不备份
```bash
./scripts/sync-ebooks.sh --no-backup
```

#### 详细输出
```bash
./scripts/sync-ebooks.sh --verbose
```

### K8s 自动同步

部署 CronJob 以定期自动同步：

```bash
# 部署同步监控 CronJob
kubectl apply -f k8s/helm/manifests/calibre-ebook-sync.yaml

# 查看 CronJob
kubectl get cronjob -n personal-services ebook-sync-monitor

# 查看执行记录
kubectl get jobs -n personal-services | grep ebook-sync

# 查看特定 Job 的日志
kubectl logs -n personal-services <pod-name>
```

## 📁 目录结构

```
homelab/
├── scripts/
│   └── sync-ebooks.sh                    # 本地同步脚本
├── k8s/
│   └── helm/
│       └── manifests/
│           ├── calibre-web.yaml          # calibre-web 部署
│           ├── calibre-ebook-sync.yaml   # 同步 CronJob
│           └── calibre-metadata/
│               └── metadata-updater.yaml # 元数据提取（每日 02:00）
└── docs/
    └── EBOOK_SYNC.md                     # 本文档
```

## 🔄 工作流程

### 手动同步流程

1. **本地下载电子书**
   ```bash
   # 将电子书放到 ~/Downloads/books 目录
   cp /path/to/book.pdf ~/Downloads/books/
   ```

2. **运行同步脚本**
   ```bash
   ./scripts/sync-ebooks.sh --dry-run      # 先查看
   ./scripts/sync-ebooks.sh --backup       # 导入+备份
   ```

3. **验证结果**
   ```bash
   # 访问 calibre-web 查看
   open https://book.meirong.dev
   ```

### 自动同步流程 (K8s CronJob)

1. **定期执行** (每 6 小时)
   - 监视 `/cwa-book-ingest` 目录
   - 统计待导入的电子书

2. **calibre-web 自动处理**
   - 监视 ingest 目录变化
   - 自动导入新文件到库

3. **元数据提取** (每日 02:00 UTC)
   - 从电子书提取发布日期
   - 提取并保存封面图片

## 📋 脚本选项详解

### `--dry-run` / `-n`
**测试模式** - 显示会处理哪些文件，但不实际执行任何操作。

用途: 在实际运行前预览操作
```bash
./scripts/sync-ebooks.sh --dry-run
```

### `--backup` / `-b`
**备份模式** (默认启用) - 导入前备份文件到 `~/.local/share/calibre-web-sync-backup/`

用途: 确保导入前有本地副本
```bash
./scripts/sync-ebooks.sh --backup
```

### `--no-backup`
**禁用备份** - 不备份直接导入

用途: 节省存储空间（需要谨慎）
```bash
./scripts/sync-ebooks.sh --no-backup
```

### `--cleanup` / `-c`
**清理模式** - 导入成功后删除本地文件

用途: 导入后自动清理本地存储
```bash
./scripts/sync-ebooks.sh --backup --cleanup
```

### `--verbose` / `-v`
**详细输出** - 显示更多调试信息

用途: 排查问题
```bash
./scripts/sync-ebooks.sh --verbose
```

## 📊 配置说明

### 脚本配置项

```bash
# 本地电子书目录
LOCAL_BOOKS_DIR="${HOME}/Downloads/books"

# 备份目录
BACKUP_DIR="${HOME}/.local/share/calibre-web-sync-backup"

# Kubernetes 配置
INGEST_POD_NAMESPACE="personal-services"
INGEST_POD_SELECTOR="app=calibre-web"
INGEST_PATH="/cwa-book-ingest"

# 支持的格式
SUPPORTED_FORMATS=("pdf" "epub" "mobi" "azw" "azw3")
```

### CronJob 时间表

修改 `calibre-ebook-sync.yaml` 中的 schedule 字段：

```yaml
spec:
  schedule: "0 */6 * * *"  # 每 6 小时执行一次
```

常见时间表:
- `0 */6 * * *` - 每 6 小时 (00:00, 06:00, 12:00, 18:00)
- `0 */4 * * *` - 每 4 小时
- `0 */2 * * *` - 每 2 小时
- `0 * * * *` - 每小时
- `0 2 * * *` - 每天 02:00 UTC
- `0 2,14 * * *` - 每天 02:00 和 14:00 UTC

## 🔍 日志和监控

### 本地脚本日志
```bash
# 查看日志
tail -f ~/.local/share/calibre-web-sync.log

# 查看最近 100 行
tail -100 ~/.local/share/calibre-web-sync.log
```

### K8s 日志
```bash
# 查看最近的 CronJob Job
kubectl get jobs -n personal-services -l job-name=ebook-sync-monitor --sort-by=.metadata.creationTimestamp

# 查看特定 Job 的日志
kubectl logs -n personal-services <job-pod-name>

# 实时监视
kubectl logs -n personal-services -f deployment/calibre-web
```

## ✅ 最佳实践

### 1. 预先测试
```bash
# 先用 --dry-run 查看会做什么
./scripts/sync-ebooks.sh --dry-run

# 确认后再实际执行
./scripts/sync-ebooks.sh --backup
```

### 2. 定期备份
```bash
# 启用备份确保数据安全
./scripts/sync-ebooks.sh --backup

# 备份会保存到
# ~/.local/share/calibre-web-sync-backup/
```

### 3. 监视 ingest 目录
```bash
# 查看待导入的文件
kubectl exec -n personal-services calibre-web-7d98b984bc-45q62 -- \
  ls -lah /cwa-book-ingest/
```

### 4. 验证导入成功
```bash
# 查看 calibre-web 的书籍总数
kubectl exec -n personal-services calibre-web-7d98b984bc-45q62 -- \
  sqlite3 /calibre-library/metadata.db "SELECT COUNT(*) FROM books"
```

## 🚨 故障排查

### 问题: "找不到 calibre-web pod"
**原因**: pod 不在 running 状态
```bash
# 检查 pod 状态
kubectl get pods -n personal-services

# 查看 pod 日志
kubectl logs -n personal-services <pod-name>
```

### 问题: "导入失败"
**原因**: 可能是权限问题或磁盘空间不足
```bash
# 检查 calibre-web pod 资源
kubectl describe pod -n personal-services <pod-name>

# 查看磁盘使用
kubectl exec -n personal-services <pod-name> -- df -h

# 检查文件权限
kubectl exec -n personal-services <pod-name> -- \
  ls -la /cwa-book-ingest/
```

### 问题: "本地目录不存在"
**原因**: `~/Downloads/books` 目录未创建
```bash
# 创建目录
mkdir -p ~/Downloads/books

# 验证
ls -la ~/Downloads/books
```

## 🔗 相关资源

- **calibre-web Web UI**: https://book.meirong.dev
- **Kubernetes ConfigMap**: `ebook-sync-script`
- **Kubernetes CronJob**: `ebook-sync-monitor`
- **元数据提取**: `calibre-metadata-updater` (每日 02:00 UTC)

## 📝 更新历史

### v1.0 (2026-05-02)
- 初始版本
- 支持从 `~/Downloads/books` 导入
- 本地脚本和 K8s CronJob
- 备份和清理选项

## 💡 未来改进

- [ ] 支持多目录监视
- [ ] Web UI 管理界面
- [ ] 导入进度显示
- [ ] 自动元数据同步
- [ ] 导入前格式检验
- [ ] 本地数据库缓存
