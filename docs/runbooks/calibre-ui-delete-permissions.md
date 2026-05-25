# Calibre-Web UI 删除权限问题 - 深度分析

## 问题现象

在 calibre-web 页面上点击删除按钮删除重复书籍时，遇到权限错误或删除无效。

## 根本原因

### 1. SQLite 数据库锁定机制

calibre-web 运行时，SQLite 数据库处于**独占锁定**状态：

```
┌─────────────────────────────────────────┐
│  calibre-web Pod                        │
│  ┌───────────────────────────────────┐  │
│  │ calibre-web 应用进程               │  │
│  │ (持有数据库 EXCLUSIVE 锁)          │  │
│  └───────────────────────────────────┘  │
│           ↓                               │
│  ┌───────────────────────────────────┐  │
│  │ /calibre-library/metadata.db      │  │
│  │ (SQLite 数据库文件)                │  │
│  └───────────────────────────────────┘  │
└─────────────────────────────────────────┘
    ↓
NFS 存储 (192.168.50.106:/storage/calibre)
```

当 calibre-web 进程运行时：
- 只有该进程可以写入数据库
- UI 操作（包括删除）需要通过应用层的权限检查
- 直接的 DELETE 操作会被应用层权限机制阻止

### 2. calibre-web 应用权限检查

```
用户在 UI 点击删除
    ↓
进入 calibre-web HTTP endpoint
    ↓
权限检查 (User Role 检查)
    ├─ 是否是管理员？
    ├─ 是否有删除权限？
    └─ 是否是该书的拥有者？
    ↓
如果权限检查失败 → 返回 403 Forbidden
    ↓
如果权限通过 → SQLite DELETE 操作
```

即使文件权限允许（-rw-r--r--），应用层权限也可能拒绝删除。

### 3. 并发和缓存问题

calibre-web 维护书籍元数据的内存缓存：

```
删除操作:
1. UI 触发 DELETE
2. 数据库中删除记录
3. 内存缓存不同步
4. 页面刷新还能看到书籍（来自缓存）
```

## 为什么数据库直接修改有效

跳过应用层的直接数据库修改：

```
方案对比:

UI 删除:
  UI → 权限检查 → SQLite 锁 → 缓存同步 ✗
  
数据库直接修改:
  1. 停止 pod（释放锁）
  2. 本地修改（绕过权限检查）
  3. 上传回 NFS
  4. 重启 pod（重新加载）✓
```

## 技术细节

### SQLite 锁定状态

```bash
# 检查数据库锁定状态
sqlite3 /tmp/metadata.db "PRAGMA query_only=0; SELECT 1;"

# 在独占锁定下（pod 运行）：
# Error: database is locked
```

### 权限检查示例

calibre-web 中可能的删除权限检查：

```python
# 伪代码
def delete_book(book_id, user):
    # 检查用户权限
    if not user.has_permission('delete_book'):
        raise PermissionError("User cannot delete books")
    
    # 检查用户是否是管理员或所有者
    book = database.get_book(book_id)
    if book.owner_id != user.id and not user.is_admin:
        raise PermissionError("User cannot delete this book")
    
    # 最后才执行删除
    database.delete_book(book_id)
```

## 解决方案对比

| 方案 | 优点 | 缺点 | 适用场景 |
|------|------|------|---------|
| **UI 删除** | 简单、无风险 | 权限问题、缓存同步 | 单一书籍、权限完整 |
| **数据库直接修改** | 彻底、绕过权限检查 | 需要 Pod 管理、有锁定风险 | 批量删除、权限问题 |
| **重启 Pod** | 强制同步、清理缓存 | 服务中断 | 作为其他方案的辅助 |

## 预防策略

### 1. 改进导入流程

在 `sync-ebooks.sh` 中添加验证：

```bash
validate_epub() {
    # 检查 ZIP 完整性
    # 检查 EPUB 结构
    # 检查是否已存在
    # 避免重复导入
}
```

### 2. 监控和告警

定期检查数据库一致性：

```bash
# 每天运行
./scripts/monitor-calibre-consistency.sh --check
```

### 3. 安全的删除操作

总是在数据库和应用层都执行删除，而不是依赖单一方式：

```
最佳实践:
1. 从应用层尝试删除（通过 UI）
2. 如果失败，检查权限和文件锁
3. 最后才使用数据库直接修改
4. 完成后验证
```

## 技术堆栈信息

### 环境

- **Kubernetes**: K3s (single-node)
- **存储**: NFS (192.168.50.106:/storage/calibre)
- **数据库**: SQLite 3.x
- **应用**: calibre-web (多容器 Pod)

### 容器详情

```
Pod: calibre-web-xxxxx
├── 容器 1: calibre-web (主应用)
├── 容器 2: log-exporter (日志导出)
└── 容器 3: permission-fixer (权限修复工具)
```

### 数据库架构

```
SQLite 数据库表（关键表）:
├── books                      # 书籍主表
├── authors / books_authors_link    # 作者关联
├── tags / books_tags_link          # 标签关联
├── series / books_series_link      # 系列关联
├── publishers / books_publishers_link  # 出版商关联
├── languages / books_languages_link    # 语言关联
├── data                       # 书籍文件数据
├── comments                   # 书籍评论
└── ...其他关联表
```

## 故障排除

### 问题：删除后页面还能看到书籍

**原因**: 内存缓存未同步
**解决**:
1. 清除浏览器缓存
2. 重启 calibre-web pod
3. 等待 30 秒后刷新

### 问题：多个用户删除同一本书时冲突

**原因**: 并发控制问题
**解决**:
1. 不同用户分别删除不同的书
2. 避免同时操作
3. 使用数据库直接修改（原子操作）

### 问题：删除后数据库大小没有变化

**原因**: SQLite 不自动释放空间
**解决**:
```bash
kubectl exec -n personal-services <pod> -- \
  sqlite3 /calibre-library/metadata.db "VACUUM;"
```

## 参考资源

- [SQLite 锁定机制](https://www.sqlite.org/lockingv3.html)
- [calibre-web 权限系统](https://github.com/janeczku/calibre-web)
- [K3s 存储最佳实践](https://docs.k3s.io/storage)
- [NFS 性能优化](https://www.kernel.org/doc/html/latest/filesystems/nfs/)

## 总结

**关键点**：
1. ✅ UI 删除失败是因为 SQLite 锁定 + 应用权限检查
2. ✅ 直接数据库修改是可行的解决方案
3. ✅ 预防优于治疗 - 改进导入流程
4. ✅ 定期监控可以早期发现问题

**建议行动**:
- [ ] 启用 `sync-ebooks.sh` 的文件验证
- [ ] 设置定期数据库一致性检查
- [ ] 文档化此问题为运维参考
- [ ] 考虑向 calibre-web 项目提交权限改进建议
