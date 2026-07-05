# sync-ebooks.sh — calibre-web 电子书同步

将本地电子书批量同步到 homelab 的 calibre-web ingest 目录，并验证入库结果。

## 功能

| 特性 | 说明 |
|------|------|
| ✅ NFS 直传 | 主传输路径，处理文件名中的特殊字符 |
| 🔄 kubectl 回退 | NFS 不可用时自动降级 |
| 🔁 自动重试 | 每文件最多 3 次，指数退避 |
| ✅ 校验和验证 | 传输后 sha256 比对，确保数据完整 |
| 📊 入库确认 | 查询 calibre-web 数据库确认新书入库 |
| 🔒 并发锁 | 防重复执行 |
| 🔍 文件完整性 | EPUB 检查 zip 结构，PDF 检查 magic bytes |
| 🗂️ 智能去重 | 模糊标题匹配，忽略大小写和元信息后缀 |
| 💾 本地备份 | 可选备份已上传文件 |
| 🧹 清理模式 | 上传成功后删除本地文件 |

## 使用

```bash
# 检查状态
./scripts/sync-ebooks.sh --check

# 检查 + 上传
./scripts/sync-ebooks.sh --upload

# 上传 + 备份 + 清理本地
./scripts/sync-ebooks.sh --upload --backup --cleanup

# 预览（不实际传输）
./scripts/sync-ebooks.sh --upload --dry-run --verbose
```

## 选项

| 选项 | 默认值 | 说明 |
|------|--------|------|
| `--check` | 默认 | 仅扫描检查 |
| `--upload` | — | 检查后上传 |
| `--source DIR` | `~/Downloads/books` | 源目录 |
| `--context NAME` | `k3s-homelab` | K8s context |
| `--dry-run` | off | 模拟运行 |
| `--backup` | on | 备份到 `~/.local/share/calibre-web-sync-backup/` |
| `--no-backup` | — | 禁用备份 |
| `--cleanup` | off | 上传成功后删除本地文件 |
| `--verbose` | off | 详细输出 |

## 传输架构

```
本机                       NFS 存储节点 (192.168.50.106)     K8s Pod
━━━━━━━━━━━━━━━━━          ━━━━━━━━━━━━━━━━━━━━━━━━━━━      ━━━━━━━━━━━━━
~/Downloads/books/  ───→   /storage/calibre/ingest/  ──→   /cwa-book-ingest/
    sync-ebooks.sh          (rsync, 主路径)                  (calibre-web 自动导入)
                              ↑
                            └── 不可用时降级到
                            kubectl cp → pod (回退路径)
```

## 输出示例

```
╔════════════════════════════════════════════════════╗
║       calibre-web 电子书同步 — 检查模式             ║
╚════════════════════════════════════════════════════╝

[10:30:01] ℹ 扫描本地目录: ~/Downloads/books
[10:30:01] ✅ 本地找到 66 本电子书
[10:30:01] ℹ 传输通道: NFS 直连 (192.168.50.106)
[10:30:02] ℹ 获取 calibre 数据库书籍列表...
[10:30:02] ✅ 数据库现有 2032 本书

════════════════════════════════════════════════════
  检查结果
════════════════════════════════════════════════════
  总计扫描:        66
  ✅ 已入库:        40
  ⏳ 处理中 (ingest): 16
  📤 待上传:        10
  ❌ 文件损坏:       0
```

## K8s CronJob

CronJob `ebook-sync-monitor` 每 6h 运行，生成健康报告：

```
============================================
  calibre-web 同步报告
============================================
  📚 书库总计:     2100 本
  📤 待导入 (ingest): 3 个
  ✨ 本轮新增:    10 本
  💾 书库大小:    5.2G
  📥 Ingest 大小: 24M
============================================
  最近入库:
    · Some Book — Author Name
============================================
```
