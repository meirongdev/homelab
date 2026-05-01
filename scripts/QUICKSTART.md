# 🚀 ebook-sync 快速开始指南

这是一个一分钟的快速开始。完整文档请查看 [README.md](./README.md)

## 📦 文件说明

| 文件 | 说明 |
|------|------|
| `ebook-sync.sh` | 主脚本（已可执行） |
| `README.md` | 完整使用文档 |
| `ebook-sync.conf.example` | 配置文件模板 |
| `QUICKSTART.md` | 本文件 |

## ⚡ 五分钟上手

### 第一步：扫描本地电子书

```bash
cd /Users/matthew/projects/homelab
./scripts/ebook-sync.sh --source ~/Downloads --check-only
```

你会看到类似这样的输出：
```
✅ 本地文件扫描完成
  📚 电子书: 140 个
  ❌ 非电子书: 17 个
  ❓ 其他文件: 8 个

✅ 导入状态检查完成
  ✅ 已导入: 60 本
  ⏳ ingest 中: 14 个
  📤 待上传: 66 个
```

### 第二步：上传新书

```bash
./scripts/ebook-sync.sh --source ~/Downloads --upload
```

脚本会：
1. 显示待上传的书籍列表
2. 要求确认
3. 执行上传
4. 显示成功/失败统计

## 🎯 常见任务

### 检查 Downloads 中有哪些新书
```bash
./scripts/ebook-sync.sh --check-only
```

### 预先查看会上传哪些文件（不实际上传）
```bash
./scripts/ebook-sync.sh --upload --dry-run --verbose
```

### 从其他目录上传电子书
```bash
./scripts/ebook-sync.sh --source ~/Documents/Books --upload
```

### 使用配置文件简化命令

1. 复制配置文件模板：
```bash
cp scripts/ebook-sync.conf.example scripts/ebook-sync.conf
```

2. 编辑 `scripts/ebook-sync.conf` 设置默认参数

3. 之后可以简化命令：
```bash
./scripts/ebook-sync.sh --upload  # 使用配置文件中的默认值
```

## 📊 理解输出

### 文件分类

- **电子书** 📚：支持的格式（pdf, epub, mobi 等）
- **非电子书** ❌：简历、工作文档等（自动过滤）
- **其他** ❓：无法分类的文件

### 导入状态

- **✅ 已导入**：已在 calibre-web 中，无需上传
- **⏳ ingest 中**：文件已在处理队列，等待 calibre-web 导入
- **📤 待上传**：新文件，需要上传

## ⚠️ 重要提示

1. **首次运行**：先用 `--check-only` 模式检查，确保一切正常
2. **预览上传**：用 `--dry-run` 模式预览将上传哪些文件
3. **确认操作**：上传时脚本会要求你确认，按 `y` 继续
4. **等待导入**：文件上传后，calibre-web 需要 5-10 分钟自动处理

## 🔧 故障排查

### "无法连接到 Kubernetes"
确保 kubectl 已配置并且有访问权限：
```bash
kubectl config get-contexts
kubectl --context k3s-homelab cluster-info
```

### "找不到 calibre-web Pod"
检查 Pod 是否正在运行：
```bash
kubectl get pod -n personal-services -l app=calibre-web
```

### 上传失败
检查文件大小和网络：
```bash
du -sh ~/Downloads/*  # 查看文件大小
./scripts/ebook-sync.sh --dry-run --verbose  # 预览
```

## 📖 更多信息

完整文档和高级用法请查看 [README.md](./README.md)

## 💡 提示

- **定期运行**：可以设置定时任务定期同步新书
- **多个目录**：可以为不同的电子书目录创建多个配置文件
- **自定义规则**：可以修改脚本中的过滤规则来改变行为

---

现在就试试吧！🎉
