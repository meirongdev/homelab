# Runbooks

> 可直接执行的运维操作手册 (SOP)。
> Last updated: 2026-07-06

## Available Runbooks

1. [backup-recovery.md](backup-recovery.md) — 备份与恢复 SOP (数据分级、恢复流程、检查清单)
2. [cilium-gateway-cutover.md](cilium-gateway-cutover.md) — Cilium Gateway / Cloudflare Tunnel 切换执行手册
3. [dns-network-failure-recovery.md](dns-network-failure-recovery.md) — DNS/网络故障恢复
4. [homelab-rebuild-ubuntu-24-04.md](homelab-rebuild-ubuntu-24-04.md) — 节点重建与 Ubuntu 24.04 LTS 回退
5. [hermes-agent.md](hermes-agent.md) — Hermes Agent (Profile 切换与 MCP 集成)
6. [security-hardening.md](security-hardening.md) — 安全加固部署/验证/回滚

> 故障复盘见 [records/](../records/README.md)。

## Runbook Standard

1. 目标明确：触发条件与成功判定
2. 命令可执行：完整命令与执行目录
3. 可回滚：关键步骤有回滚路径
4. 事后复盘：在对应 `../plans/` 增补时间线与根因
