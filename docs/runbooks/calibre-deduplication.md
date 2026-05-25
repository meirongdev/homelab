# Calibre-Web 重复文件彻底解决方案

## 问题描述

Calibre-Web 中存在重复文件无法删除的问题，主要原因：

1. **SQLite 数据库锁定** - calibre-web 运行中，数据库被独占锁定
2. **孤立记录** - 数据库中有记录，但对应的文件已删除
3. **级联删除失败** - 关联表中的记录未被正确删除

## 解决方案概览

### 方案对比

| 方案 | 难度 | 停机 | 自动化 | 推荐度 |
|------|------|------|--------|--------|
| A: UI 删除 | ⭐ | 否 | 否 | ⭐⭐ |
| B: 数据库清理 | ⭐⭐ | 是 | 是 | ⭐⭐⭐⭐⭐ |
| C: 命令行工具 | ⭐⭐ | 否 | 是 | ⭐⭐ |
| D: 数据库重建 | ⭐⭐⭐ | 是 | 否 | ⭐ |

## 快速开始（推荐方案 B）

### 第1步：分析问题

首先检查有多少重复/孤立记录：

```bash
cd /Users/matthew/projects/homelab
./scripts/clean-calibre-duplicates.sh --analyze
```

输出示例：
```
=== 1. 孤立的书籍记录（没有对应的文件） ===
23

=== 2. 孤立的作者链接 ===
45

=== 3. 孤立的标签链接 ===
67
```

### 第2步：执行清理

```bash
./scripts/clean-calibre-duplicates.sh --clean
```

脚本会：
1. ✅ 备份数据库
2. ✅ 停止 calibre-web pod
3. ✅ 清理所有孤立记录
4. ✅ 优化数据库（VACUUM）
5. ✅ 重启 pod

### 第3步：验证结果

清理完成后，calibre-web 会自动重启。可以再次运行分析确认问题已解决：

```bash
./scripts/clean-calibre-duplicates.sh --analyze
```

## 详细步骤

### 步骤 1: 分析数据库

运行分析检查数据一致性：

```bash
./scripts/clean-calibre-duplicates.sh --analyze
```

这会显示：
- 孤立的书籍记录数
- 孤立的作者链接数
- 孤立的标签链接数
- 孤立的系列/出版商/语言链接数
- 可能的重复书籍

### 步骤 2: 备份数据库

清理前自动备份（脚本会自动做）：

```bash
# 手动备份（可选）
kubectl cp personal-services/<pod-name>:/calibre-library/metadata.db \
    ~/.local/share/calibre-db-backup/metadata.db.manual-backup
```

### 步骤 3: 停止 Pod

```bash
kubectl scale deployment calibre-web -n personal-services --replicas=0
# 等待 pod 停止
sleep 5
```

或让脚本自动处理：

```bash
./scripts/clean-calibre-duplicates.sh --clean
```

### 步骤 4: 清理数据库

执行完整清理（会删除所有孤立记录）：

```sql
BEGIN TRANSACTION;

-- 删除孤立的作者链接
DELETE FROM authors_link 
WHERE book NOT IN (SELECT id FROM books);

-- 删除孤立的标签链接
DELETE FROM tags_link 
WHERE book NOT IN (SELECT id FROM books);

-- 删除孤立的系列链接
DELETE FROM series_link 
WHERE book NOT IN (SELECT id FROM books);

-- 删除孤立的出版商链接
DELETE FROM publishers_link 
WHERE book NOT IN (SELECT id FROM books);

-- 删除孤立的语言链接
DELETE FROM languages_link 
WHERE book NOT IN (SELECT id FROM books);

-- 删除孤立的注释链接
DELETE FROM comments_link 
WHERE book NOT IN (SELECT id FROM books);

-- 优化数据库
VACUUM;

COMMIT;
```

### 步骤 5: 重建索引（可选但推荐）

```bash
./scripts/clean-calibre-duplicates.sh --rebuild
```

或手动执行：

```bash
kubectl exec -n personal-services <pod> -- sqlite3 /calibre-library/metadata.db << 'SQL'
REINDEX;
ANALYZE;
VACUUM;
SQL
```

### 步骤 6: 重启 Pod

```bash
kubectl scale deployment calibre-web -n personal-services --replicas=1
# 等待 pod 启动
kubectl rollout status deployment/calibre-web -n personal-services
```

## 预防措施

### 1. 定期检查一致性

创建 cron 任务运行监控脚本：

```bash
# 编辑 crontab
crontab -e

# 添加以下行（每天凌晨2点运行检查）
0 2 * * * cd /Users/matthew/projects/homelab && ./scripts/monitor-calibre-consistency.sh --check >> ~/.local/share/calibre-consistency.log 2>&1
```

### 2. 监控脚本

```bash
./scripts/monitor-calibre-consistency.sh --check
./scripts/monitor-calibre-consistency.sh --report
```

输出示例：
```
[2026-05-02 22:50:00] 开始一致性检查...
[2026-05-02 22:50:02] ✓ 数据一致性检查完成 - 无问题
```

### 3. 改进导入流程

在 `sync-ebooks.sh` 中已添加：
- ✅ 文件完整性验证
- ✅ DRM 保护检测
- ✅ 错误报告

## 高级选项

### 完整重建数据库（核选项）

如果问题严重，可以完全重建数据库：

```bash
# 1. 停止 calibre-web
kubectl scale deployment calibre-web -n personal-services --replicas=0

# 2. 删除旧数据库
kubectl exec -n personal-services <pod> -- rm /calibre-library/metadata.db

# 3. 重启 pod（会自动创建新数据库）
kubectl scale deployment calibre-web -n personal-services --replicas=1

# 4. 重新导入电子书
cd /Users/matthew/projects/homelab
./scripts/sync-ebooks.sh --backup --cleanup
```

## 故障排除

### 问题：脚本找不到 pod

**解决方案**：
```bash
# 确认 pod 在运行
kubectl get pods -n personal-services -l app=calibre-web

# 检查 KUBE_CONTEXT
echo $KUBE_CONTEXT  # 应该是 k3s-homelab
kubectl config current-context
```

### 问题：数据库清理失败

**解决方案**：
1. 确认 pod 已停止：`kubectl get pods -n personal-services`
2. 检查权限：`kubectl exec -n personal-services <pod> -- ls -l /calibre-library/`
3. 手动重启 pod：`kubectl scale deployment calibre-web -n personal-services --replicas=1`

### 问题：清理后 calibre-web 无法启动

**解决方案**：
1. 检查日志：`kubectl logs -n personal-services <pod>`
2. 恢复备份：
   ```bash
   kubectl cp ~/.local/share/calibre-db-backup/metadata.db.<timestamp>.backup \
       personal-services/<pod>:/calibre-library/metadata.db
   ```
3. 重启 pod

## 日志和备份

### 备份位置
```
~/.local/share/calibre-db-backup/
```

### 清理日志
```
~/.local/share/calibre-consistency.log
```

### 查看备份
```bash
ls -lh ~/.local/share/calibre-db-backup/
```

## 脚本参考

### clean-calibre-duplicates.sh

```bash
用法: clean-calibre-duplicates.sh [选项]

选项:
  -a, --analyze      仅分析，不执行修改
  -c, --clean        执行清理（需要停止 Pod）
  -r, --rebuild      重建数据库索引
  -h, --help         显示此帮助信息

示例:
  clean-calibre-duplicates.sh --analyze    # 分析重复
  clean-calibre-duplicates.sh --clean      # 执行清理
  clean-calibre-duplicates.sh --rebuild    # 重建索引
```

### monitor-calibre-consistency.sh

```bash
用法: monitor-calibre-consistency.sh [选项]

选项:
  --check            检查数据一致性
  --report           生成详细报告

示例:
  monitor-calibre-consistency.sh --check    # 快速检查
  monitor-calibre-consistency.sh --report   # 生成报告
```

## 总结

| 步骤 | 命令 | 说明 |
|------|------|------|
| 1 | `--analyze` | 分析问题规模 |
| 2 | `--clean` | 执行自动清理 |
| 3 | `--rebuild` | 重建索引（可选） |
| 4 | `--report` | 验证结果 |

## 相关文件

- `scripts/clean-calibre-duplicates.sh` - 主清理脚本
- `scripts/monitor-calibre-consistency.sh` - 监控脚本
- `scripts/sync-ebooks.sh` - 改进的导入脚本
- `docs/runbooks/calibre-deduplication.md` - 本文档
