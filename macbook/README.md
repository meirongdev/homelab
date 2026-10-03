# MacBook — 本地 macOS 自动化

管理两台**远程无头 Apple Silicon Mac**，都经 Tailscale 访问，都是 homelab 的 AI 本地推理（OMLX）节点：

| inventory 主机 | 机器 | Tailscale | 登录用户 | Prometheus |
|---|---|---|---|---|
| `mbp-m2-pro` | MacBook Pro M2（合盖运行） | `100.89.15.120` | `matthew` | `cluster=macbook` |
| `mac-studio` | Mac Studio M5 Max / 128G（2026-10-03 入列） | `100.98.220.75` | **`matstudio`** | `cluster=mac-studio` |

目录名仍叫 `macbook/`（十几个文件里的路径、根 justfile 的 `mod macbook` 都指着它，改名收益抵不上代价），
实际管的是两台；哪台跑哪些 playbook 由 [ansible/inventory.yaml](ansible/inventory.yaml) 的分组决定。

当前内容只有 Ansible 配置归档，入口见:

## 快速上手

```bash
cd macbook/ansible && just ping     # 连通性（两台）
just site mac-studio                # 全量，一次一台（逐台问 sudo 密码）
just os-updates                     # 系统更新：先看计划（只读，两台），再 just os-update <host>
just os-update-no-restart <host>    # 系统更新：只装免重启的
```

## 详见

- 配置归档: [ansible/README.md](ansible/README.md)
- 模型接线（Open Notebook → Mac OMLX）: [docs/reference/open-notebook.md](../docs/reference/open-notebook.md)
- OMLX 指标采集与面板（**OMLX 无原生 `/metrics`**，集群内 json-exporter 翻两个 JSON 端点）:
  [docs/reference/omlx-inference-metrics.md](../docs/reference/omlx-inference-metrics.md)
- ☠️ **OMLX 0.7 起没配 API key 就起不来**：重启后 launchd 崩溃循环，直到有人发现，
  2026-09-29 M2 就这样挂了 34h。2026-10-03 起 `just omlx` 管住了这一点（只合并
  host/port/key 四个键，key 从 Vault 取）；重装、升级或在 admin 面板里重置设置之后重跑它。
  其余 OMLX 设置与模型仍归 admin 面板，不归 Ansible。
