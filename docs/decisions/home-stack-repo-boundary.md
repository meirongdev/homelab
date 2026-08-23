# home-stack 与 homelab 的分工：按资源类型切，不按仓库能力切

> 日期: 2026-08-23
> 状态: ✅ 已实施
> 关联：[reference/networking-ingress.md](../reference/networking-ingress.md#不走这条链的-meirongdev-主机名集群外托管)（记录归属表）·
> [reference/services.md](../reference/services.md)（服务清单唯一真相源）·
> [ROADMAP #13](../ROADMAP.md)（本决策留下的监控缺口）

## 上下文

2026-08-23 `stack.meirong.dev` 上线。它**不是集群里的服务**：那是另一个仓库
（公开的 `meirongdev/home-stack`，Rust→wasm 的自托管选型目录站）用**自己的** Terraform
部到 Cloudflare Workers 上的。于是 `meirong.dev` 这个 zone、这个 Cloudflare 账号，
第一次出现「两个仓库、两份 state、两枚凭据」同时写入。

写入者盘点（4 个，前 3 个是既有的）：

1. homelab `cloudflare/terraform` —— 隧道配置、zone 设置、WAF/限流、集群外源记录
2. homelab 集群的 `homelab-externaldns`（txt owner，`upsert-only`）
3. oracle 集群的 `oracle-externaldns`（txt owner，`upsert-only`）
4. **home-stack 的 terraform —— 只有 `stack.meirong.dev` 这一条**（Workers 自定义域名）

不把边界切清楚，有三种**具体**的坏结局，都不是假想：

- **双主**：两边都声明同一条记录。Workers 自定义域名**不能**建在已存在 CNAME 的主机名上，
  于是谁先 apply 谁赢，另一边永久报错。
- **清理型误删**：那条记录既不在 homelab 的 state，也没有 external-dns 的 ownership TXT，
  看着就像一条游离记录。删掉 = 站点域名解析消失，而 homelab 仓库里没有任何线索指向原因。
  自动化不会误删它（两个 external-dns 都 `upsert-only`，terraform 不 prune 不在自己
  state 里的记录）—— **风险只有人**，所以这条只能靠文档拦。
- **凭据越界**：首次部署图省事用了 homelab 那枚宽 token（能改全部 DNS/隧道/WAF/R2）。
  它若进了 home-stack（**公开仓库**）的 Actions secret，爆炸半径远超「部署一个站点」。

## 可选项

| | 方案 | 为什么不选 |
|---|------|-----------|
| A | **homelab 全管**：homelab 的 terraform 消费 home-stack 的 `modules/worker` 子模块 | 那个模块**按设计不构建产物**，消费方必须自己 checkout home-stack 并具备 Rust + wasm32 + `worker-build` + Pagefind 工具链 —— 等于把一条 Rust 构建链拖进 homelab 的部署路径；且 home-stack 目前 0 个 tag，只能钉 `main`（内容与代码一起变，部署内容会在没人改动时变化）|
| B | **home-stack 全管**：连隧道、WAF、zone 设置一起接走 | 那些是**全 zone 共享**的：27 个主机名依赖同一份隧道与同一套 WAF。一个站点的仓库不该有权改它们 |
| **C ✅** | **按资源类型切**，一张归属表，两边都留注释 | 代价见「后果」 |

## 决策

选 C。归属表（**本表是这件事的唯一真相源**）：

| 资源 | 归属 | 另一边的义务 |
|------|------|-------------|
| Worker / version / deployment / 静态资源层 | **home-stack** | homelab 不部署它、不 `wrangler deploy`、不引入 Rust 构建 |
| `stack.meirong.dev` 的 DNS 记录（`AAAA 100::` 橙云） | **home-stack**（`cloudflare_workers_custom_domain` 自建） | homelab ☠️ 不声明第二份、☠️ 不当游离记录清理 |
| 其余 `meirong.dev` 记录（隧道 CNAME、集群外源） | **homelab**（terraform + 两个 external-dns） | home-stack 不碰 |
| 隧道 `cloudflared` 配置 | **homelab** | 与 home-stack 无关（Workers 不经隧道）|
| zone 设置 / WAF / 限流 | **homelab 独占** | 站点要 WAF 例外 → 改动落在 homelab（见后果）|
| R2 桶 `terraform-backend` 本体与生命周期 | **homelab** | home-stack 只拥有 `home-stack/` 这个 key 前缀 |
| 部署凭据 | **各自一枚最小权限 token** | ☠️ 不把 homelab 的宽 token 放进 home-stack 的 CI secret |
| 可用性监控（Uptime Kuma、Homepage 磁贴） | **homelab** | home-stack 只管应用层正确性（内容校验、渲染一致性）|
| 文档 | zone/入口的**事实**在 homelab `reference/`；部署 **SOP** 在 home-stack 的 runbook | 互链不复制。⚠️ homelab 是私有仓库 → home-stack 的文档必须自成一体，不能依赖读者点进 homelab |

## 后果

**好的**：两边都能独立 `apply`，谁都不需要对方的工具链；凭据可以各自最小化；
出问题时「这是谁的 state」一眼可判。

**代价，逐条**：

- **zone 的 DNS 不再只有一个真相源** —— 两份 state 各持一部分。缓解是把不对称压到最小：
  home-stack 只拥有**一条**记录，且这条记录的存在在 homelab 侧留了三处痕
  （`cloudflare/terraform/main.tf` 的 `external_origins` 上方、`networking-ingress.md`
  的记录归属表、`services.md` 的集群外托管清单）。
- **改名要动两个仓库**：换主机名 = home-stack 改 `custom_domain` + homelab 改那三处注释。
- ⚠️ **WAF 例外要跨仓库提**：`stack.meirong.dev` 走橙云，于是吃 zone 级 WAF 与限流。
  若站点被 `cf.threat_score gt 14` 那条 managed challenge 误伤（公开文档站会有爬虫），
  改动落在 homelab —— 而 **Free 档规则位已满**（自定义规则 5/5、限流 1/1），
  真要给它开口子得先砍一条现有规则。
- ⚠️ **监控缺口**：按上表 homelab 拥有可用性监控，但目前 `stack.meirong.dev`
  既没有 Uptime Kuma 监控项也没有 Homepage 磁贴 —— 即「站点挂了不会有人知道」。
  记为 [ROADMAP #13](../ROADMAP.md)。
- **home-stack 侧的对称文档**在它自己的 `docs/reference/cross-repo-boundary.md`，
  内容是本表的消费方视角。两份都改才叫改完。
