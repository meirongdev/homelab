# Plans

> **这是档案，不是现状。** 每份 plan 记录的是写它那天的世界——里面的路径、版本、拓扑
> 可能早就变了（Traefik、Kopia、Gotify、NFS 都还活在某些 plan 里）。
>
> 要知道**今天**是什么样：读 [reference/](../reference/README.md)。
> 要知道**还剩什么没做**：读 [../ROADMAP.md](../ROADMAP.md)。

## 类别

每个类别的 README 列出该类全部方案及其状态。

> 份数由 `scripts/check-docs.py` 校验（R5），漂了 CI 会报错。

| 类别 | 内容 | 份数 |
|------|------|------|
| [apps/](apps/README.md) | 应用部署/迁移方案 | 9 |
| [networking/](networking/README.md) | 网络/集群方案 | 7 |
| [observability/](observability/README.md) | 可观测方案 | 7 |
| [security/](security/README.md) | 安全加固方案 | 3 |
| [architecture/](architecture/README.md) | 舰队级架构诊断与演进建议 | 4 |
| [storage/](storage/README.md) | 存储/备份方案 | 4 |
| [archive/](archive/README.md) | **不存在于当前系统的方案**（从未实施/已取消/已被取代/前提消失） | 18 |

⚠️ **已完成、且东西还在跑的方案不进 archive** —— 它们解释了系统为何是现在这样，留在各自类别里。
archive 只收「读了也帮不上理解当前系统」的那些——**含完成后又整体退役的**（如 Bifrost）。

## 写新 plan

1. 路径：`docs/plans/<类别>/YYYY-MM-DD-<topic>.md`
2. 文首必须有 `日期` + `状态` + `结论`；状态取 [R4 枚举](../README.md)
3. **完成后把稳定结论回写 `reference/`**，然后就不要再改这份 plan 了——它从此是历史快照
4. 被取代时不删文件：文首标状态 + 链到取代它的文档
5. 更新所在类别的 README 索引

完整规则见 [文档组织规则](../RULES.md)。
