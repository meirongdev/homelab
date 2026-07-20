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

## Remaining Work（完成本次优化还需要做的）

按优先级排序；前两项是"把已开始的事做完"，后两项是"这次优化其实只覆盖了一半基础设施"。

### 1. 🔴 阻塞项：修复 homelab `cloudflare/terraform` 的无效 token

`cloudflare/terraform/terraform.tfvars` 的 `cloudflare_api_token` 是 Tunnel connector token（格式错），导致该项目 `terraform plan`/`apply`/**`state rm`** 全部直接报错（Terraform 在解析 provider 配置阶段就校验字符集，不等到发网络请求）。**这是下面第 2 项的硬前提**——不修好这个 token，5 条记录连从 state 里移除都做不到。需要去 Cloudflare Dashboard 建一个 `Zone:DNS:Edit`（scope 限 `meirong.dev`）的真 API Token 换掉它。

### 2. 🟡 把 5 条既有记录的归属权转给 external-dns，收缩 terraform

**不要**直接从 terraform 里删这 5 条再等 external-dns 重建——proxied CNAME 被删掉到 external-dns 下一个 reconcile（最长 1 分钟）之间，`argocd`/`grafana`/`vault`/`book`/`llm` 会短暂 DNS 中断。更安全的路径是**先手工"预埋"ownership TXT 记录**（让 external-dns 认为自己已经拥有该记录、CNAME 内容又本就一致 → 它什么都不用改），再把 terraform 那边清掉，全程零停机：

1. 手工建 5 条 TXT 记录（`ttl=1`，不 proxied）。格式已用一次性测试 HTTPRoute 实测确认（2026-07-20），**不是猜的**：`<prefix>cname-<hostname>` / `"heritage=external-dns,external-dns/owner=<txtOwnerId>,external-dns/resource=httproute/<namespace>/<name>"`。5 条的精确内容：

   | TXT 记录名 | content | 对应 HTTPRoute |
   |---|---|---|
   | `cname-argocd.meirong.dev` | `"heritage=external-dns,external-dns/owner=homelab-externaldns,external-dns/resource=httproute/argocd/argocd"` | `argocd/argocd` |
   | `cname-book.meirong.dev` | `"heritage=external-dns,external-dns/owner=homelab-externaldns,external-dns/resource=httproute/personal-services/calibre-web"` | `personal-services/calibre-web` |
   | `cname-grafana.meirong.dev` | `"heritage=external-dns,external-dns/owner=homelab-externaldns,external-dns/resource=httproute/monitoring/grafana"` | `monitoring/grafana` |
   | `cname-llm.meirong.dev` | `"heritage=external-dns,external-dns/owner=homelab-externaldns,external-dns/resource=httproute/bifrost/bifrost"` | `bifrost/bifrost` |
   | `cname-vault.meirong.dev` | `"heritage=external-dns,external-dns/owner=homelab-externaldns,external-dns/resource=httproute/vault/vault"` | `vault/vault` |

2. 等一个 external-dns reconcile 周期（`interval: 1m`），确认它的日志不再跳过这 5 条、且 Cloudflare 里 CNAME **没有被改动**（`modified_on` 不变 = 证明是零停机接管，不是删了重建）。
3. `cd cloudflare/terraform && terraform state rm` 掉这 5 个 `cloudflare_dns_record.subdomains["..."]`（此时 token 已修好，见第 1 项），并从 `terraform.tfvars` 的 `ingress_rules` 里删掉这 5 条 key。`terraform plan` 应显示 no changes。
4. 之后才考虑把 `policy` 从 `upsert-only` 升级成 `sync`（见 Consequences 里的警告——升级前确认所有该管的记录都已被 external-dns 正确接管，否则 `sync` 可能删掉它还没来得及认领的东西）。

### 3. 🟡 oracle-k3s 完全没做——而且它的子域名数是 homelab 的两倍

这次优化**只覆盖了 homelab**。核查发现 oracle-k3s 处境和 homelab 当初一模一样，甚至更值得做：

- `cilium-gateway-oracle-gateway` 也是 `type: LoadBalancer` 但 `EXTERNAL-IP: <pending>`——同样没有可读地址，需要同款 `external-dns.alpha.kubernetes.io/target` 注解。
- `cloud/oracle/cloudflare/terraform.tfvars` 现有 **10 条**子域名（`auth`/`status`/`keep`/`rss`/`slot`/`tool`/`pdf`/`trends`/`squoosh`/`home`），是 homelab 5 条的两倍——两步走的手工负担实际大头在 oracle 这边，这轮完全没碰。
- 需要：oracle-k3s 里部署第二个 external-dns 实例（`txtOwnerId` 必须换成不同值，比如 `oracle-externaldns`——两个实例共享同一个 Cloudflare zone，owner id 撞了会互相干扰所有权判定）、oracle 那边的 Vault/ESO secret 管线、`oracle-gateway` 打 target 注解。这些还没有对应的 justfile/manifest，需要新写。

### 4. 🟢 external-dns 自身缺可观测性

部署时只启用了核心功能，没接监控——查过了，这**不是**"忘了"，是这类通用告警本来就不覆盖它这类故障:
- **Pod 级故障已覆盖**：确认 `KubePodCrashLooping`/`KubePodNotReady` 是 kube-prometheus-stack 默认规则，全命名空间生效，external-dns pod 崩了会告警，不用重复造轮子。
- **缺口在"pod 活着但 reconcile 静默失败"**：比如 Cloudflare token 过期/被吊销、API 限流——这种情况 pod 一直 Running/Ready，泛化告警抓不到，只有 external-dns 自己的 metrics（`:7979`，chart 里 `serviceMonitor.enabled` 默认关着，现在没在被 Prometheus 抓）才看得出来。真出问题的表现是:新增/改动的 HTTPRoute 迟迟不出现对应 DNS 记录，且没人知道。要补的话是开 `serviceMonitor.enabled: true` + 一条基于 `external_dns_*` 系列 metrics（如 sync 错误计数/最后成功同步时间）的 PrometheusRule，優先级不高但计入待办。

## 重新评估 / 退出条件

- 若要下线 external-dns：删 `external-dns` Helm release + ArgoCD App + Gateway 注解即可；因 `upsert-only` 从未删过记录，既有 DNS 不受影响，回退无损。
- 上面 4 项均为独立后续工作，不阻塞当前"新子域名（homelab）单文件"能力已经生效这一事实。
