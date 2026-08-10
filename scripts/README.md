# scripts/

| 脚本 | 用途 |
|------|------|
| [`check-docs.py`](check-docs.py) | 文档组织规则检查器（强制 [R1-R7](../docs/README.md)）。`python3 scripts/check-docs.py`，CI 每次 PR/push 跑 |
| [`check-public-ips.py`](check-public-ips.py) | 禁止提交公网 IP。扫 git 跟踪的文本文件里的 IPv4 字面量，全球可路由的一律报错；Tailscale `100.64/10`、RFC1918、RFC5737 文档段、第三方 anycast DNS（1.1.1.1/8.8.8.8/…）放行，行内 `public-ip-ok: <理由>` 可豁免。**不设 paths 过滤**，每次 PR/push 全跑（`.github/workflows/no-public-ip.yml`）。只拦新提交，历史里的地址要单独重写 |
| [`verify-oracle-node.sh`](verify-oracle-node.sh) | oracle-k3s 重启/变更后的巡检（主机层 sysctl/GRO/firewalld/DNS + 节点预留账目 + pod/App + ClusterMesh `retrieved=true` + 数据面）。只读，任一条不成立即非零退出；条数是循环动态累加的，结尾自报「N 项通过 / M 项失败」——别在文档里写死条数。`cd cloud/oracle && just verify-node`。**配套** `just check-node-drift`（`ansible-playbook --check`）查「配置有没有漂移」，本脚本查「结果对不对」 |
| `sync-ebooks.sh` | calibre-web 电子书同步（下详） |
| `cleanup-duplicates.sh` | 清理重复书目 |

---

# sync-ebooks.sh — calibre-web 电子书同步

将本地电子书批量同步到 homelab 的 calibre-web ingest 目录，并验证入库结果。

## 功能

| 特性 | 说明 |
|------|------|
| ✅ kubectl cp 传输 | **唯一**传输通道。⚠️ 原有的「NFS 直传为主、kubectl 回退」已于 2026-07-12 整条删除——书库迁 `local-path` 后，那条路径写的是 106 上迁移前的孤儿快照目录，校验和在副本上比对、全程报绿但书从未真正入库 |
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
本机 ~/Downloads/books/          K8s Pod (personal-services)
━━━━━━━━━━━━━━━━━━━━━━          ━━━━━━━━━━━━━━━━━━━━━━━━
  sync-ebooks.sh  ──(kubectl cp)──→  /cwa-book-ingest/  ──→  calibre-web 自动导入
                  (sha256 校验 + 入库确认)
```

## 输出示例

```
╔════════════════════════════════════════════════════╗
║       calibre-web 电子书同步 — 检查模式             ║
╚════════════════════════════════════════════════════╝

[10:30:01] ℹ 扫描本地目录: ~/Downloads/books
[10:30:01] ✅ 本地找到 66 本电子书
[10:30:01] ℹ 传输通道: kubectl cp
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
