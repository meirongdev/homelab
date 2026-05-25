# Calibre-Web 只读数据库错误排查

## 问题症状

```
(sqlite3.OperationalError) attempt to write a readonly database
[SQL: DELETE FROM books_authors_link WHERE ...]
(raised as a result of Query-invoked autoflush; consider using a session.no_autoflush block...)
```

## 根本原因

### 1. NFS 挂载权限问题

SQLite 数据库位于 NFS 存储上，当发生以下情况时会出现只读错误：

```
NFS 权限不匹配:
  - 数据库文件权限: -rw-r--r--
  - Pod 用户: uid 501 (calibre-web)
  - NFS 根用户: uid 0 (root)
  
结果: Pod 用户权限不足以修改 NFS 上的文件
```

### 2. SQLite 超时锁定

长时间的数据库访问导致锁定：

```
Timeline:
  1. 用户点击删除
  2. calibre-web 执行 DELETE
  3. 数据库处于锁定状态
  4. NFS 超时
  5. 数据库变为只读
```

### 3. Pod 重启导致的权限重置

```
重启前:
  数据库文件权限正常
  calibre-web 进程可以写入
  
重启后:
  NFS 重新挂载
  权限发生变化（通常是更严格）
  calibre-web 无法写入
```

## 诊断步骤

### 1. 检查错误日志

```bash
kubectl logs -n personal-services <pod> -c calibre-web | tail -50
```

关键词：
- `readonly`
- `OperationalError`
- `permission denied`

### 2. 检查数据库文件权限

```bash
# 在 pod 中检查
kubectl exec -n personal-services <pod> -- ls -la /calibre-library/metadata.db

# 检查目录权限
kubectl exec -n personal-services <pod> -- ls -ld /calibre-library/
```

### 3. 检查 NFS 挂载信息

```bash
# 查看 PV 配置
kubectl get pv calibre-books-pv -o yaml | grep -A 5 nfs

# 预期输出:
# nfs:
#   path: /storage/calibre
#   server: 192.168.50.106
```

### 4. 检查 Pod 用户

```bash
# 查看 pod 定义中的 securityContext
kubectl get pod -n personal-services -o yaml <pod> | grep -A 5 securityContext
```

## 解决方案

### 方案 A: 快速修复（推荐）

使用离线数据库修改脚本：

```bash
# 删除单本书籍
./scripts/delete-calibre-book.sh <book_id>

# 示例
./scripts/delete-calibre-book.sh 2017
```

**优点:**
- 快速（< 1 分钟）
- 绕过权限问题
- 原子操作
- 自动备份

**缺点:**
- 需要停止 Pod
- 临时中断服务

### 方案 B: 修复 NFS 权限

```bash
# 在 NFS 服务器上执行
ssh admin@192.168.50.106

# 检查权限
ls -la /storage/calibre/metadata.db

# 修复权限（允许所有用户读写）
chmod 666 /storage/calibre/metadata.db
chmod 777 /storage/calibre/

# 验证
ls -la /storage/calibre/metadata.db
```

然后重启 calibre-web:
```bash
kubectl rollout restart deployment/calibre-web -n personal-services
```

### 方案 C: 修改 Pod 权限上下文

编辑 calibre-web deployment，添加 securityContext：

```yaml
spec:
  template:
    spec:
      securityContext:
        fsGroup: 0  # root 组
        runAsNonRoot: false
      containers:
      - name: calibre-web
        securityContext:
          runAsUser: 0  # root 用户
          runAsGroup: 0  # root 组
```

## 预防措施

### 1. 定期权限检查

```bash
# 在 crontab 中添加
0 */6 * * * kubectl exec -n personal-services <pod> -- \
  chmod 666 /calibre-library/metadata.db
```

### 2. NFS 导出配置

在 NFS 服务器上检查 `/etc/exports`:

```
/storage/calibre  192.168.0.0/16(rw,all_squash,anonuid=0,anongid=0)
```

参数说明：
- `rw`: 读写权限
- `all_squash`: 所有用户映射到 anonymous
- `anonuid=0`: anonymous 用户 ID 为 0 (root)
- `anongid=0`: anonymous 组 ID 为 0 (root)

### 3. 监控只读错误

```bash
# 添加到 monitoring
kubectl logs -n personal-services <pod> -c calibre-web | grep -i readonly && \
  echo "ALERT: Database readonly error detected!"
```

## 常见场景

### 场景 1: 刚重启 Pod 后无法删除

**原因:** NFS 权限重置
**解决:** 等待 30 秒后重试，或使用自动化脚本

### 场景 2: 特定用户无法删除

**原因:** UI 权限检查
**解决:** 使用自动化脚本绕过权限检查

### 场景 3: 大批量删除时失败

**原因:** 并发锁定
**解决:** 使用 `clean-calibre-duplicates.sh` 进行批量清理

## 工具参考

### 快速删除单本书

```bash
./scripts/delete-calibre-book.sh <book_id>
```

### 批量清理重复/孤立记录

```bash
./scripts/clean-calibre-duplicates.sh --analyze
./scripts/clean-calibre-duplicates.sh --clean
```

### 监控数据库一致性

```bash
./scripts/monitor-calibre-consistency.sh --check
```

## 深入技术细节

### SQLite 锁定模式

```
UNLOCKED → SHARED (读取) → RESERVED → EXCLUSIVE → RELEASED

只读错误通常发生在:
  1. 需要升级到 EXCLUSIVE 锁时
  2. 但 NFS 权限不允许
  3. 导致操作失败
```

### NFS 与 SQLite 的冲突

```
问题:
  - SQLite 使用文件级锁定
  - NFS 锁定机制不完美
  - 高并发时容易失败

症状:
  - "database is locked"
  - "attempt to write a readonly database"
  - 间歇性错误
  
解决:
  - 使用 PostgreSQL/MySQL 替代
  - 或改进 NFS 配置
```

### 权限映射

```
Pod 中的 UID/GID:
  calibre-web 进程: uid 501, gid 501
  
NFS 映射:
  no_all_squash: 保留原始 UID/GID
  all_squash: 映射到 anonymous (通常是 root)
  
如果 NFS 使用 no_all_squash:
  - uid 501 → 需要在 NFS 服务器上有相应的用户
  - 如果 NFS 服务器没有 uid 501，权限会被拒绝
  
解决:
  - 改为 all_squash + anonuid=0 (root)
  - 或在 NFS 服务器上创建相应用户
```

## 参考资源

- [SQLite Locking](https://www.sqlite.org/lockingv3.html)
- [NFS Mount Options](https://linux.die.net/man/5/nfs)
- [Kubernetes Security Context](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
- [calibre-web Issues](https://github.com/janeczku/calibre-web/issues)

## 总结

| 症状 | 原因 | 解决 |
|------|------|------|
| 只读数据库错误 | NFS 权限问题 | 修复 NFS 权限或使用自动化脚本 |
| 删除失败但无错误 | UI 权限检查 | 使用自动化脚本绕过 |
| 批量删除时超时 | 数据库锁定 | 使用 clean-calibre-duplicates.sh |
| 重启后权限问题 | 挂载点重置 | 修改 Pod securityContext |

**建议操作顺序:**
1. 如果是单本书籍: `./scripts/delete-calibre-book.sh <id>`
2. 如果是重复/孤立: `./scripts/clean-calibre-duplicates.sh`
3. 如果权限持续出现: 修复 NFS 权限或 Pod securityContext
