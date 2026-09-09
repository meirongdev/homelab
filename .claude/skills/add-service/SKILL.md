---
name: add-service
description: Add a new service to the homelab. Creates the K8s manifest, gateway HTTPRoute, homepage entry, and Uptime Kuma monitor. DNS is automatic (external-dns). Use when the user wants to deploy a new application or self-hosted service.
argument-hint: [service-name]
allowed-tools: Read, Edit, Write, Glob, Grep, Bash(kubectl *), Bash(dig *), Bash(curl *), Bash(cd /Users/matthew/projects/homelab && git *)
---

## Add New Homelab Service: $ARGUMENTS

**本文是入口壳，不是流程的真相源。**完整 SOP 在
[docs/runbooks/add-service.md](../../../docs/runbooks/add-service.md) —— 先完整读它，再按它的
步骤 1–8 执行（落点判据 → 清单 → HTTPRoute → GitOps 注册 → homepage → Uptime Kuma → 提交 → 验收）。

☠️ **改流程改 runbook，不要改本文件。**这里只留 frontmatter 与这一段指针，是为了让流程受
`docs/RULES.md` 的 R1/R3/R5/R8 与 `scripts/check-docs.py` 约束（runbook 必须有触发条件、
成功判定、回滚，且进 `docs/runbooks/README.md` 索引）。2026-08-01 就是因为流程只存在于本文件、
没有任何检查覆盖它，两条错误指令（HTTPRoute 追加进 `gateway.yaml`、parentRef 用 port 8000）
静默存在了一段时间，见 `docs/plans/2026-08-01-open-notebook-homelab.md`。

执行时最容易漏的四条（runbook 里有完整版，别跳过它）：

- **新子域名不需要动 DNS**：写 HTTPRoute 就是改 DNS，不要动 `cloudflare/terraform`。
- **oracle-k3s 必须登记**进 `cloud/oracle/manifests/kustomization.yaml`，没登记 = 静默不生效。
- **新 PVC 要同时进备份白名单**（H4）· **新 ns 要显式写 PSA 等级**（H5）。
- 提交前 `cd /Users/matthew/projects/homelab && just check`；验收判据看 HTTPRoute 的
  `ResolvedRefs=True`，不是「旧域名还能开」。
