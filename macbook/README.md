# MacBook — 本地 macOS 自动化

管理那台**远程无头（合盖）Apple Silicon MacBook Pro（M2）**：经 Tailscale 访问，
作为 homelab 的 AI 本地推理（OMLX）节点，并以 `cluster=macbook` 被 Prometheus 监控。

当前内容只有 Ansible 配置归档，入口见:

## 快速上手

```bash
cd macbook/ansible && just ping     # 连通性
just site                           # 全量（packages + ai-clis + node-exporter + power）
just os-updates                     # 系统更新：先看计划（只读），再 just os-update
just os-update-no-restart           # 系统更新：只装免重启的
```

## 详见

- 配置归档: [ansible/README.md](ansible/README.md)
- 模型接线（Open Notebook → Mac OMLX）: [docs/reference/open-notebook.md](../docs/reference/open-notebook.md)
- OMLX 指标采集与面板（**OMLX 无原生 `/metrics`**，集群内 json-exporter 翻两个 JSON 端点）:
  [docs/reference/omlx-inference-metrics.md](../docs/reference/omlx-inference-metrics.md)
- ☠️ **OMLX 本身（brew `jundot/omlx/omlx` + `~/.omlx/settings.json`）不归 Ansible 管**。0.7 起
  没配 API key 就起不来：重启后 launchd 崩溃循环，直到有人发现，2026-09-29 就这样挂了 34h。
  重装、升级或重置设置之后，照 [omlx-inference-metrics.md 的「鉴权」](../docs/reference/omlx-inference-metrics.md#鉴权omlx-07-起)
  把 key 与 `allow_unauthenticated_inference` 写回去。
