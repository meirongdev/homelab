# 📚 calibre-web 电子书同步工具

一个 bash 脚本，用于将本地目录中的电子书文件同步到 calibre-web 服务。支持自动检测、去重和批量导入。

## 🎯 功能特点

- ✅ **自动扫描**：扫描本地目录，自动识别电子书文件
- 🔍 **智能去重**：检查 calibre-web 中已导入的书籍，避免重复上传
- 📤 **批量导入**：支持将多个电子书文件批量导入 calibre-web
- 🚫 **过滤非电子书**：自动识别和过滤简历、工作文档等非电子书文件
- 📊 **详细统计**：显示扫描结果、导入状态等详细信息
- 🔐 **安全操作**：提供预览模式和确认机制，防止误操作

## 📋 支持的电子书格式

- PDF (.pdf)
- EPUB (.epub)
- MOBI (.mobi)
- Amazon (.azw, .azw3)
- Text (.txt)
- DjVu (.djvu)
- Comic (.cbz, .cbr)

## 🚀 快速开始

### 前置要求

- `bash` 4.0+
- `kubectl` 已正确配置，能访问 K3s 集群
- calibre-web 运行在 `personal-services` 命名空间

### 安装

1. 将脚本放到 homelab 项目的 `scripts` 目录：

```bash
cd /Users/matthew/projects/homelab
chmod +x scripts/ebook-sync.sh
```

2. （可选）配置默认参数：

```bash
cp scripts/ebook-sync.conf.example scripts/ebook-sync.conf
# 编辑 scripts/ebook-sync.conf 修改默认参数
```

### 基本用法

#### 1️⃣ **检查本地电子书（推荐首先运行）**

```bash
./scripts/ebook-sync.sh --source ~/Downloads --check-only
```

输出示例：
```
✅ 本地文件扫描完成
  📚 电子书: 140 个
  ❌ 非电子书: 17 个
  ❓ 其他文件: 8 个

✅ 导入状态检查完成
  ✅ 已导入: 60 本
  ⏳ ingest 中: 14 个
  📤 待上传: 66 个

════════════════════════════════════════════════════════════
📊 扫描结果总结
════════════════════════════════════════════════════════════

本地电子书统计:
  总计: 140 个
  ✅ 已导入: 60 本
  ⏳ 处理中 (ingest): 14 个
  📤 新增: 66 个

待上传的新书 (前 10 个):
  - AI Agents with Java (Alex Soto Bueno).pdf
  - Build AI into Your Web Apps (Theo Despoudis).epub
  - ...
```

#### 2️⃣ **预览导入（不实际上传）**

在实际上传前，可以用 dry-run 模式预览：

```bash
./scripts/ebook-sync.sh --source ~/Downloads --upload --dry-run --verbose
```

#### 3️⃣ **执行导入**

```bash
./scripts/ebook-sync.sh --source ~/Downloads --upload
```

脚本会：
1. 扫描本地文件
2. 显示导入状态统计
3. 请求确认
4. 执行上传

### 高级选项

```bash
# 使用其他 kubectl 上下文
./scripts/ebook-sync.sh --source ~/Downloads --context my-cluster --upload

# 详细输出（显示临时文件位置）
./scripts/ebook-sync.sh --source ~/Downloads --verbose

# 组合选项
./scripts/ebook-sync.sh \
  --source ~/Documents/Books \
  --context k3s-homelab \
  --upload \
  --verbose
```

## 📝 配置文件

在 `scripts/ebook-sync.conf` 中可以配置默认参数，避免每次都指定命令行选项：

```bash
# ebook-sync.conf 示例

# 本地源目录
SOURCE_DIR="${HOME}/Downloads"

# Kubernetes 上下文
KUBECONFIG_CONTEXT="k3s-homelab"

# calibre-web 所在命名空间
NAMESPACE="personal-services"

# calibre-web Deployment 名称
DEPLOYMENT="calibre-web"

# ingest 目录路径
INGEST_DIR="/cwa-book-ingest"

# 详细输出
VERBOSE=false

# 使用 dry-run 模式（可选）
DRY_RUN=false
```

配置文件创建后，可以简化命令：

```bash
# 无需指定所有参数
./scripts/ebook-sync.sh --upload
```

## 🔄 工作流程

```
┌─────────────────────────────┐
│   扫描本地目录              │
│  - 识别电子书文件           │
│  - 过滤非电子书文件         │
└──────────────┬──────────────┘
               │
┌──────────────▼──────────────┐
│   连接 calibre-web          │
│  - 获取已导入的书籍列表     │
│  - 获取 ingest 中的文件     │
└──────────────┬──────────────┘
               │
┌──────────────▼──────────────┐
│   对比去重                  │
│  - 已导入: 跳过             │
│  - 处理中: 等待             │
│  - 新增: 准备上传           │
└──────────────┬──────────────┘
               │
┌──────────────▼──────────────┐
│   显示统计结果              │
│  - 本地文件数               │
│  - 已导入/处理中/待上传     │
└──────────────┬──────────────┘
               │
        ┌──是否上传?──┐
        │             │
       否             是
        │             │
        └─────┬───────┘
              │
    ┌─────────▼─────────┐
    │   确认上传        │
    │   进度显示        │
    └─────────┬─────────┘
              │
    ┌─────────▼─────────┐
    │   导入完成        │
    │   等待 calibre-web │
    │   自动处理        │
    └───────────────────┘
```

## 📊 理解脚本输出

### 文件分类

脚本会将本地文件分为三类：

| 分类 | 说明 | 示例 |
|------|------|------|
| **电子书** | 支持的电子书格式 | AI Agents.pdf, Python.epub |
| **非电子书** | 简历、工作文档等 | BE_resume.pdf, LinkedIn_CV.pdf |
| **其他** | 无法分类的文件 | image.jpg, config.xml |

### 导入状态

| 状态 | 说明 |
|------|------|
| ✅ **已导入** | 已在 calibre-web 书库中，不需要上传 |
| ⏳ **ingest 中** | 文件已复制到 ingest，等待 calibre-web 处理 |
| 📤 **待上传** | 新文件，需要上传到 ingest 目录 |

## ⚠️ 注意事项

### 重复检测逻辑

脚本使用**书名匹配**来检测重复，会忽略：
- 文件扩展名 (.pdf vs .epub)
- 作者信息 (文件名中括号内的内容)
- 大小写差异

例如，这些被认为是同一本书：
```
AI Agents with Java (Alex Soto Bueno).pdf
AI Agents with Java (for Raymond Rhine).pdf
ai agents with java.epub
```

### 非电子书过滤规则

脚本自动过滤以下类型的文件（不会上传）：

1. **简历类**
   - 以 `BE_`, `SRE_`, `PM_` 等开头
   - 包含 `LinkedIn_`, `resume`, `cv` 等关键词

2. **Confluence 导出**
   - 文件名格式: `Name-YYMMDD-HHMMSS.pdf`
   - 包含 `confluence` 关键词

3. **工作相关**
   - 包含 `fee`, `endpoint`, `finance` 等关键词
   - `.txt` 文件通常被认为是工作文档

如需修改过滤规则，编辑 `ebook-sync.sh` 中的 `is_non_ebook()` 函数。

## 🔧 故障排查

### 问题 1: "无法连接到 Kubernetes 集群"

**原因**: kubectl 配置不正确或上下文不存在

**解决**:
```bash
# 检查可用的上下文
kubectl config get-contexts

# 指定正确的上下文
./scripts/ebook-sync.sh --source ~/Downloads --context k3s-homelab --check-only
```

### 问题 2: "找不到运行中的 calibre-web Pod"

**原因**: calibre-web Pod 未运行或命名空间错误

**解决**:
```bash
# 检查 Pod 状态
kubectl get pod -n personal-services -l app=calibre-web

# 如果 Pod 处于 CrashLoopBackOff，重启它
kubectl rollout restart deployment/calibre-web -n personal-services
```

### 问题 3: 上传失败或超时

**原因**: 文件过大或网络不稳定

**解决**:
```bash
# 用 dry-run 模式测试
./scripts/ebook-sync.sh --source ~/Downloads --upload --dry-run --verbose

# 检查单个文件大小
du -sh ~/Downloads/*

# 减少源目录中的大文件，或使用更小的批次上传
```

### 问题 4: 上传成功但书籍未出现在 calibre-web

**原因**: calibre-web 正在处理 ingest 文件，需要等待

**解决**:
```bash
# 等待 5-10 分钟，让 calibre-web 自动导入

# 检查 ingest 目录状态
./scripts/ebook-sync.sh --source ~/Downloads --check-only

# 查看 calibre-web 日志
kubectl logs -n personal-services deployment/calibre-web --tail=50
```

## 📈 性能参考

基于实际测试数据（Homelab 环境）：

| 场景 | 耗时 | 说明 |
|------|------|------|
| 扫描 500 个文件 | 1-2 秒 | 本地文件系统操作 |
| 获取 1800+ 书籍列表 | 2-3 秒 | 数据库查询 |
| 上传 1 个 10MB 文件 | 5-10 秒 | kubectl exec + tar |
| 上传 100 个文件 | 10-15 分钟 | 受网络限制 |
| calibre-web 自动导入 | 变量 | 取决于文件大小和系统负载 |

## 🛠️ 定制和扩展

### 修改过滤规则

编辑 `is_non_ebook()` 函数：

```bash
is_non_ebook() {
    local filename="$1"
    
    # 添加自己的过滤规则
    if [[ "${filename}" =~ your_pattern ]]; then
        return 0  # 返回 0 表示应该过滤
    fi
    
    return 1  # 返回 1 表示不过滤
}
```

### 添加更多电子书格式

编辑 `EBOOK_FORMATS` 数组：

```bash
EBOOK_FORMATS=("pdf" "epub" "mobi" "azw" "azw3" "txt" "djvu" "cbz" "cbr" "ibooks")
```

### 更改默认参数

编辑 `scripts/ebook-sync.conf` 或脚本中的默认值部分。

## 📝 日志和调试

### 启用详细输出

```bash
./scripts/ebook-sync.sh --source ~/Downloads --verbose
```

这会：
- 显示临时文件位置
- 保留日志和中间结果
- 输出更多调试信息

### 查看完整日志

```bash
cat /tmp/ebook-sync-<PID>/sync.log
```

其中 `<PID>` 是脚本执行时的进程 ID。

## 📞 支持和反馈

如遇到问题或有功能建议，请：

1. 检查 [故障排查](#-故障排查) 部分
2. 查看详细日志和错误信息
3. 在 homelab 项目中提交 Issue

## 📄 许可证

MIT License - 自由使用和修改

## 🔗 相关资源

- [calibre-web 文档](https://github.com/janeczku/calibre-web)
- [Kubernetes kubectl 参考](https://kubernetes.io/docs/reference/kubectl/)
- [Homelab 项目](https://github.com/meirongdev/homelab)

---

**最后更新**: 2026-05-01  
**版本**: 1.0
