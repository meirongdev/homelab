# scripts/

| 脚本 | 用途 |
|------|------|
| [`check-docs.py`](check-docs.py) | 文档组织规则检查器（强制 [R1-R7](../docs/RULES.md)）。`python3 scripts/check-docs.py`，CI 每次 PR/push 跑 |
| [`check-terminology.py`](check-terminology.py) | 术语正典检查（强制 [terminology.md](../docs/reference/terminology.md) 的 T1-T3）：不存在的 context 名（`homelab-k3s`/`k3s-oracle` —— 曾让脚本默认打错集群）、拼写正典（ArgoCD/ZITADEL/ClusterMesh/控制面/storage-106）、`reference/`+`runbooks/` 里把 homelab 说成单节点（2026-08-13 起双节点）。**故意不查风格类变体**（K3s vs K8s 的语义选择、App/Application、`106` 简称）——写成规则必然误报，误报多了检查就会被绕过。`plans/`+`records/` **也在范围内**（命名不是事实陈述），但 T3 只管 `reference/`+`runbooks/`。行内 `terminology-ok: <理由>` 可豁免（同 `public-ip-ok` 约定）。`python3 scripts/check-terminology.py`，CI 走 `docs-check.yml` |
| [`render-manifests.py`](render-manifests.py) | **渲染检查**（2026-09-02 加）：以 `argocd/applications/*.yaml` 为输入，把每个 App 真正会 apply 的对象渲染出来（目录源拼接 / `kubectl kustomize` / `helm template` 带 pin 与 `$values`），逐个过 `kubeconform -strict`。拦的是 H1-H5 读不到的那层：values 写错层级被 chart 静默忽略、多源 `$values` 渲染成空操作、kustomize 漏登记。☠️ 必须带 `--kube-version`/`--api-versions`，否则 ServiceMonitor 一类模板压根不渲染，校验的是另一份清单。「跳过」不是「通过」——无 schema 的 kind 会被列出来。`uv run --with pyyaml python scripts/render-manifests.py`，CI 走 `static-checks.yml` 的 `render` job |
| `check-version-pairs.py` | 版本配对断言 **V1-V4**：同一 chart 跨 Application 同版本 · 声明为同一事实的变量组取值一致 · `cilium_version` ↔ `gateway_api_version` 符合兼容表 · ☠️ **V4**（2026-09-02）：`versions.just` 的共享变量不得被 `import` 方重新定义 —— `just import` 允许覆盖且**静默胜出**，比原来各写一份更隐蔽。行尾 `version-pair-ok: <理由>` 可豁免 |
| [`check-public-ips.py`](check-public-ips.py) | 禁止提交公网 IP。扫 git 跟踪的文本文件里的 IPv4 字面量，全球可路由的一律报错；Tailscale `100.64/10`、RFC1918、RFC5737 文档段、第三方 anycast DNS（1.1.1.1/8.8.8.8/…）放行，行内 `public-ip-ok: <理由>` 可豁免。**不设 paths 过滤**，每次 PR/push 全跑（`.github/workflows/no-public-ip.yml`）。只拦新提交，历史里的地址要单独重写 |
| [`verify-oracle-node.sh`](verify-oracle-node.sh) | oracle-k3s 重启/变更后的巡检（主机层 sysctl/GRO/firewalld/DNS + 节点预留账目 + pod/App + ClusterMesh `retrieved=true` + 数据面）。只读，任一条不成立即非零退出；条数是循环动态累加的，结尾自报「N 项通过 / M 项失败」——别在文档里写死条数。`cd cloud/oracle && just verify-node`。**配套** `just check-node-drift`（`ansible-playbook --check`）查「配置有没有漂移」，本脚本查「结果对不对」 |
| `sync-ebooks.sh` | calibre-web 电子书同步（下详） |
| `cleanup-duplicates.py` | 清理重复书目。归一化标题匹配（不是完全同名）+ **拿真实磁盘核对计划** + 同书 EPUB/PDF 合并 + `calibredb` 删除。`cd k8s/helm && just cleanup-calibre-dry-run` 先看判定 |

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
