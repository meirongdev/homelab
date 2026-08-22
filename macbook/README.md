# MacBook — 本地 macOS 自动化

管理那台**远程无头（合盖）Apple Silicon MacBook Pro（M2）**：经 Tailscale 访问，
作为 homelab 的 AI 本地推理（OMLX）节点，并以 `cluster=macbook` 被 Prometheus 监控。

当前内容只有 Ansible 配置归档，入口见:

## 快速上手

```bash
cd macbook/ansible && just ping     # 连通性
just site                           # 全量（packages + ai-clis + node-exporter + power）
```

## 详见

- 配置归档: [ansible/README.md](ansible/README.md)
- 模型接线（Open Notebook → Mac OMLX）: [docs/reference/open-notebook.md](../docs/reference/open-notebook.md)
- OMLX 指标采集与面板（**OMLX 无原生 `/metrics`**，集群内 json-exporter 翻两个 JSON 端点）:
  [docs/reference/omlx-inference-metrics.md](../docs/reference/omlx-inference-metrics.md)
