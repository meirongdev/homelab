# Images — 自建容器镜像（Dockerfile 源）

本目录下的镜像由 CI 构建并推送到 `ghcr.io/meirongdev/*`（各自一个 workflow，
按路径触发）。其余服务用的都是上游官方镜像，不在此维护。

```
images/
├── excalidraw-room/
│   └── Dockerfile
└── squoosh/
    ├── Dockerfile
    └── squoosh.conf
```

| 镜像 | 为什么自建 | Workflow |
|------|-----------|----------|
| `excalidraw-room` | 官方镜像只发 amd64，oracle-k3s 是 arm64 | `.github/workflows/excalidraw-room-image.yml` |
| `squoosh` | 上游 `dko0/squoosh` 2022-07 停更，入口是 EOL 的 Node 16 静态服务器且公网可达（15 条 Critical CVE）；只取其静态产物换进新 nginx 壳 | `.github/workflows/squoosh-image.yml` |

> **首次构建后必须手工把 ghcr 包可见性改成 Public**
> （Packages → 包名 → Package settings → Change visibility），
> 否则 oracle 集群拉取需要 imagePullSecret（现有 `meirongdev/*` 镜像均为 public）。
