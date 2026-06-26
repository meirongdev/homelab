# Runbooks

> Reproducible operational procedures.
> Last updated: 2026-06-05

## Available Runbooks

1. [dns-network-failure-recovery.md](dns-network-failure-recovery.md): DNS/网络故障恢复
2. [backup-recovery.md](backup-recovery.md): 备份与灾难恢复 SOP（数据分级、恢复流程、检查清单）
3. [cilium-gateway-cutover.md](cilium-gateway-cutover.md): Cilium Gateway / Cloudflare Tunnel 切换执行手册
4. [homelab-rebuild-ubuntu-24-04.md](homelab-rebuild-ubuntu-24-04.md): homelab 节点重建与 Ubuntu 24.04 LTS 回退手册
5. [hermes-agent.md](hermes-agent.md): Hermes Agent — Profile 切换与 MCP 集成（Jira Cloud）

## Runbook Standard

1. 目标明确：说明触发条件与成功判定。
2. 命令可执行：每一步给出完整命令与执行目录。
3. 可回滚：关键步骤必须有回滚路径。
4. 事后复盘：在对应 `../plans/` 增补时间线与根因。
