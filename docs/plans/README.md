# Plans

> **这里只放还没做完的方案。** 要知道**今天**是什么样：读 [reference/](../reference/README.md)。
> 要知道**还剩什么没做**：读 [../ROADMAP.md](../ROADMAP.md)。

2026-11-09 起 plans **做完即删**：稳定结论回写 `reference/`（事实）或 `decisions/`（取舍）后删除
plan 文件，不再归档。旧方案在 git 历史里：
`git log --diff-filter=D --name-only --oneline -- docs/plans/` 找到提交，再 `git show <commit>^:<path>`。

## 当前方案

| 日期 | 方案 | 状态 |
|------|------|------|
| 2026-11-11 | [Tailscale ACL 收紧：服务器节点从 `*:*` 收到按需端口](2026-11-11-tailscale-acl-tightening.md) | 📐 设计（7 条 grant + policy tests；k8s-node 不能打 tag，按 IP 点名） |
| 2026-11-10 | [Cilium 网络策略：双集群定向收口](2026-11-10-cilium-network-policy.md) | 🚧 两集群 audit soak 中（最早 11-18 / 11-19 翻 enforce） |
| 2026-10-02 | [Ubuntu 26.04 LTS 升级与 IaC 适配](2026-10-02-ubuntu-26-04-upgrade-plan.md) | 📐 设计（待生态成熟与 IaC 适配；ROADMAP #20） |
| 2026-09-03 | [DGX 换模型提速：事故式切换 → 改一个值 + 跑两条命令](2026-09-03-dgx-model-swap-optimizations.md) | 📐 设计（未实施；[换栈 SOP §8](../runbooks/dgx-model-swap-homelab-followup.md) 的展开） |
| 2026-08-03 | [离站备份（restic copy → 云）](2026-08-03-offsite-backup.md) | 📐 设计（等开云桶；ROADMAP #1） |

## 写新 plan

1. 路径：`docs/plans/YYYY-MM-DD-<topic>.md`（**不分子目录**）
2. 文首必须有 `日期` + `状态` + `结论`；状态取 [R4 枚举](../RULES.md#r4-状态标记)
3. **做完后把稳定结论回写 `reference/` / `decisions/`，把还有用的踩坑挪进 `records/` 或 runbook，
   再删掉这份 plan**，并从本页索引移除；指向它的链接一并改指常青文档
4. 方案被放弃时同样删除；「为什么不做」值得留的，写进 ROADMAP「不做 / 已取消」表或一份否决 ADR
5. 更新本页索引

完整规则见 [文档组织规则](../RULES.md)。
