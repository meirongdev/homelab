# external-dns 采用：子域名 DNS 从 Terraform 手管转向 HTTPRoute 声明式

> Date: 2026-07-19
> Decision status: Implemented（5 条既有记录迁移 + terraform 收缩为待办）
> 关联：[演进路线 Phase D](../reference/evolution-roadmap-2026-07-07.md) · [gateway-controller-evaluation](gateway-controller-evaluation.md)

## Context（痛点）

加一个新子域名，此前是 **CONVENTIONS 固定的两步手改**：

1. `cloudflare/terraform/terraform.tfvars` 的 `ingress_rules` 加一条 → `terraform apply` 建 CNAME（指向 tunnel）；
2. `k8s/helm/manifests/gateway.yaml` 加 `HTTPRoute`（+ 需要时 `ReferenceGrant`）声明 hostname→Service。

两处分属不同工具、不同仓库路径，**必须同步改、漏一处就半通**（只改 tfvars → Cloudflare 转发进来但集群不知道路由去哪；只改 gateway → 集群能路由但公网无 DNS）。是纯手工、易漏、无强制校验的 toil。DNS 那一半（第 1 步）本质上可由集群状态推导——HTTPRoute 里已经写了 hostname，再让人去 tfvars 抄一遍是冗余。

## Options

| 方案 | 结论 |
|---|---|
| **维持两步手改** | 痛点不消除；子域名越多越容易漂移 |
| **Crossplane + Cloudflare provider** | ❌ 否决。`cdloh/provider-cloudflare` 2023-01 后无维护、无 v2；且 Crossplane 控制面对单人静态云面是过度工程（详见[演进路线](../reference/evolution-roadmap-2026-07-07.md)「三、Crossplane 评估」） |
| **external-dns（选定）** | ~20MB 控制器，Gateway API HTTPRoute 已是一等 source；直接消掉第 1 步。加子域名从此只写一个 HTTPRoute |

> 为什么不是"把 gateway.yaml 也塞进 terraform"或反过来：terraform 不感知集群运行态（它不会 watch HTTPRoute），无论怎么合并，加子域名仍需人去改 terraform 输入。让**集群成为真相源、DNS 跟随集群**才是消除 toil 的方向，这也和本仓库既有取向一致（Cilium Gateway 作统一入口、ArgoCD 声明式）。

## Decision

部署 external-dns（Helm chart `external-dns/external-dns` 1.21.1，manual-helm，`just deploy-external-dns`），关键配置与**理由**：

| 配置 | 值 | 为什么 |
|---|---|---|
| `sources` | `[gateway-httproute]` | HTTPRoute 成为子域名的唯一真相源 |
| `provider` | `cloudflare` | 现有 DNS 就在 Cloudflare |
| `domainFilters` | `[meirong.dev]` | 限定作用域，绝不碰其它 zone |
| `policy` | **`upsert-only`** | **只增不删**的安全默认——即便误删 HTTPRoute 也不会连带删掉公网 DNS；与仍由 terraform 管的记录共存期尤其重要 |
| `registry` + `txtOwnerId` | `txt` / `homelab-externaldns` | 所有权登记，防止 external-dns 去改它并未创建的记录 |
| Gateway 注解 | `external-dns.alpha.kubernetes.io/target: <tunnel-id>.cfargotunnel.com` | Cilium 是 NodePort Gateway，**没有可读的 LB 地址**；显式指定 CNAME 目标 = terraform 一直用的 tunnel 目标，保证格式一致 |

**Cloudflare token**：复用 `cloud/oracle/cloudflare/terraform.tfvars` 里那份已验证有效的 Zone 级 API Token，经 Vault `secret/homelab/external-dns` → ESO 落地为 secret `external-dns/external-dns-cloudflare`（ExternalSecret 归 ArgoCD `external-dns` App；chart 本体是 manual-helm，同 Vault/ESO/kube-prometheus-stack）。
> ⚠️ 之所以没用 homelab 自己 `cloudflare/terraform/terraform.tfvars` 的 token：那份 `cloudflare_api_token` 当前是**无效值**——格式其实是 Tunnel connector token（`eyJhIjoi...` base64 JSON），不是 API Token，导致该 terraform 项目 `plan` 直接报错。这是排查 external-dns 时顺带发现的既有问题，未在本次修复，待补一个真正的 `Zone:DNS:Edit` token。

## Verification（2026-07-19 端到端）

建一个一次性测试 HTTPRoute（`edns-verify-test.meirong.dev`）→ external-dns 在下一个 reconcile 周期于 Cloudflare 建出真实 `CNAME`（→tunnel，`proxied=true`）+ ownership `TXT`，格式与 terraform 现有记录一致；`dig`/API 均确认。验证后删除 HTTPRoute 并手动清理两条测试记录（`upsert-only` 不会自动删）。

**共存安全性已实测**：homelab 那 5 条既有记录（`argocd`/`book`/`grafana`/`llm`/`vault`）对应的 HTTPRoute external-dns **全都看得到**，但因它们的 CNAME 目标本就与期望一致（同一 tunnel），external-dns 判定无需变更 → **完全不碰、连 ownership TXT 都没建**（核查 zone 内 TXT 记录数为 0）。即 external-dns 对这 5 条的足迹为零，共存干净。

## Consequences

- ✅ **加子域名（homelab）现在只写一个 HTTPRoute 文件**；DNS 自动建。
- ⚠️ **未完成（待办）**：`argocd`/`book`/`grafana`/`llm`/`vault` 这 5 条仍由 terraform 管，归属权尚未转交 external-dns、`terraform.tfvars` 尚未收缩。迁移路径：让 external-dns 接管需它对记录施加一次变更（或强制），届时会补上 ownership TXT；在此之前两套并存，靠 `upsert-only` + txt 登记保证互不破坏。
- ⚠️ **别把 `policy` 改成 `sync`** 除非确已完成上面迁移并接受 external-dns 全权删除——`sync` 下它会删掉自己认为"不该存在"的记录（仍受 txt 所有权保护，但风险面变大）。
- ⚠️ external-dns 只 watch **它所在的 homelab 集群**的 HTTPRoute；oracle-k3s 的子域名（`auth`/`status`/`keep`/… 由 `cloud/oracle/cloudflare` terraform 管）不在其管辖内，各管各的。
- 📌 遗留待办：homelab `cloudflare/terraform` 的无效 token 修复（见上）。

## 重新评估 / 退出条件

- 若要下线 external-dns：删 `external-dns` Helm release + ArgoCD App + Gateway 注解即可；因 `upsert-only` 从未删过记录，既有 DNS 不受影响，回退无损。
- 5 条既有记录的迁移与 terraform 收缩，作为独立后续决策推进（不阻塞当前"新子域名单文件"能力）。
