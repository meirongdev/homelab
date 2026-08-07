# Guides

> 面向任务的跨领域流程，非日期绑定、也不是故障处置 SOP（那些在 [runbooks/](../runbooks/README.md)）。

| 指南 | 内容 |
|------|------|
| [dev-machine-bootstrap.md](dev-machine-bootstrap.md) | 换新机器后把环境配到能 clone/改/验这个 repo（密钥、工具链、kubeconfig、本地 CI 检查、需从旧机拷贝的 gitignored 文件） |
| [ebook-sync.md](ebook-sync.md) | Calibre-Web 电子书同步（本地 → cwa ingest） |
| [calibre-metadata-enrichment.md](calibre-metadata-enrichment.md) | 给书库补元数据的四层手段（内嵌提取 → 外部查询 → 按 ISBN 修正 → LLM 从内容生成）、各自实测产出率、以及**什么时候该停** |
| [hermes-agent.md](hermes-agent.md) | Hermes Agent（MacBook 本地工具）Profile 管理与 MCP 集成 |

新增指南：`<topic>.md`（文件名不带日期），并更新上表。
