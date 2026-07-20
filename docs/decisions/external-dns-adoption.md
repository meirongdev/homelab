# external-dns 采用：子域名 DNS 从 Terraform 手管转向 HTTPRoute 声明式

> Date: 2026-07-19（2026-07-20 补：homelab 收尾 + observability + oracle-k3s 全量落地 + 双集群隧道通配）
> Decision status: Implemented（**两集群全量完成**）— homelab + oracle-k3s 均已：既有记录零停机迁移给 external-dns、terraform DNS 解耦收缩、隧道改单条 `*.meirong.dev` 通配路由。homelab 另配 ServiceMonitor+告警。加子域名从此**只写一个 HTTPRoute**（两集群均已端到端验证）。
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
> 说明：external-dns 的 secret 复用 oracle 那份 token 只是图省事（一份已知可用的 Zone token）。**不是**因为 homelab 没有可用 token——homelab 真正有效的 Cloudflare API Token 一直在 gitignored 的 `cloudflare/terraform/.env` 里，`just plan/apply` 经 `-var` 注入使用，terraform 从未真的被卡住（详见下方 Remaining Work 第 1 项的更正）。曾经 `terraform.tfvars` 里塞的是一段 Tunnel connector token（`eyJhIjoi...`）的误值，但它被 `.env` 的值覆盖、从不生效；2026-07-20 已把本地 tfvars 的该值改回正确 token，消除误导。

## Verification（2026-07-19 端到端）

建一个一次性测试 HTTPRoute（`edns-verify-test.meirong.dev`）→ external-dns 在下一个 reconcile 周期于 Cloudflare 建出真实 `CNAME`（→tunnel，`proxied=true`）+ ownership `TXT`，格式与 terraform 现有记录一致；`dig`/API 均确认。验证后删除 HTTPRoute 并手动清理两条测试记录（`upsert-only` 不会自动删）。

**共存安全性已实测**：homelab 那 5 条既有记录（`argocd`/`book`/`grafana`/`llm`/`vault`）对应的 HTTPRoute external-dns **全都看得到**，但因它们的 CNAME 目标本就与期望一致（同一 tunnel），external-dns 判定无需变更 → **完全不碰、连 ownership TXT 都没建**（核查 zone 内 TXT 记录数为 0）。即 external-dns 对这 5 条的足迹为零，共存干净。

## Consequences

- ✅ **加子域名（homelab）的 DNS 半步已消除**：写一个 HTTPRoute，external-dns 自动建 CNAME。⚠️ 但**隧道路由半步仍在**——cloudflared 无通配 ingress，新 hostname 仍需在 `cloudflare/terraform` 的 `ingress_rules` 里加一条才不 404（详见 Remaining Work 第 5 项）。所以现状是"两步变一步半"，不是"变一步"。
- ✅ **5 条既有记录已迁移（2026-07-20，零停机验证通过）**：`argocd`/`book`/`grafana`/`llm`/`vault` 的 ownership TXT 已预埋、external-dns 已接管、5 条 CNAME 的 `modified_on` 全程未变；terraform 侧已 `state rm` 并把 DNS 与隧道路由**解耦**（见第 2 项）。归属权登记完成，两套不再并存。
- ⚠️ **别把 `policy` 改成 `sync`** 除非接受 external-dns 全权删除——`sync` 下它会删掉自己认为"不该存在"的记录（仍受 txt 所有权保护，但风险面变大）。5 条已被正确接管，技术上可升，但 `upsert-only` 已够用、无必要冒险。
- ⚠️ external-dns 只 watch **它所在的 homelab 集群**的 HTTPRoute；oracle-k3s 的子域名（`auth`/`status`/`keep`/… 由 `cloud/oracle/cloudflare` terraform 管）不在其管辖内，各管各的（第 3 项仍待办）。

## Remaining Work / 完成记录

> **2026-07-20 更新**：第 1、2、4 项已完成（保留原委 + 标注实际做法与两处更正）；第 3 项（oracle-k3s）仍待办；核查中新发现第 5 项（隧道无通配路由），一并记录。

### 1. ✅ 已澄清：terraform 从没被 token 卡住（原判"🔴 阻塞项"是误判）

原文把它列为第 2 项的"硬前提"，称 tfvars 的 token 是 Tunnel connector 格式、导致 `plan`/`apply`/`state rm` 全报错，需去 Dashboard 建新 token。复核推翻了这个判断：真正有效的 Zone token 一直在 gitignored 的 `cloudflare/terraform/.env`，`justfile` 用 `-var` 注入，`just plan/apply` 从来正常；`terraform.tfvars` 那段 `eyJhIjoi...` 误值被 `-var` 覆盖、从不生效。2026-07-20 已把本地 tfvars 的该值改回正确 token（与 `.env` 同值），`terraform state rm` 与 `just plan`（No changes）均实测通过。**无需再建 token**。（`.env`/`*.tfvars` 均 gitignored，误值从未进过 git。）

### 2. ✅ 已完成（2026-07-20）：5 条记录归属权转交 external-dns + terraform 解耦收缩

零停机路径按原计划执行并验证通过；**原计划第 3 步有一处会致公网 404 的错误，已更正**。

1. 手工预埋 5 条 ownership TXT（`ttl=1`，不 proxied）。格式用一次性 probe HTTPRoute 逐字节实测 external-dns v0.21.0 的真实产物确认——**含外层双引号**：POST content 带引号则读回带引号、raw 则都不带，external-dns 用的是带引号那种，必须一致否则它认不出自己的 owner 记录。5 条精确内容：

   | TXT 记录名 | content（含外层引号） | 对应 HTTPRoute |
   |---|---|---|
   | `cname-argocd.meirong.dev` | `"heritage=external-dns,external-dns/owner=homelab-externaldns,external-dns/resource=httproute/argocd/argocd"` | `argocd/argocd` |
   | `cname-book.meirong.dev` | `"…owner=homelab-externaldns,…/resource=httproute/personal-services/calibre-web"` | `personal-services/calibre-web` |
   | `cname-grafana.meirong.dev` | `"…owner=homelab-externaldns,…/resource=httproute/monitoring/grafana"` | `monitoring/grafana` |
   | `cname-llm.meirong.dev` | `"…owner=homelab-externaldns,…/resource=httproute/bifrost/bifrost"` | `bifrost/bifrost` |
   | `cname-vault.meirong.dev` | `"…owner=homelab-externaldns,…/resource=httproute/vault/vault"` | `vault/vault` |

2. 等 reconcile，零停机验证通过：external-dns 连续多轮日志 `All records are already up to date`，5 条 CNAME 的 `modified_on` 与迁移前逐字节一致（证明是接管、非删重建）。
3. **⚠️ 更正原计划**：原文第 3 步说"`state rm` 这 5 个 `cloudflare_dns_record.subdomains["…"]`，并从 `ingress_rules` 删掉这 5 条 key"。**后半句是错的、会致故障**——`main.tf` 里 `ingress_rules` 同时驱动两个资源：`cloudflare_dns_record.subdomains`（DNS，要交给 external-dns）**和** `cloudflare_zero_trust_tunnel_cloudflared_config`（cloudflared 隧道 ingress 路由）。external-dns 只管 DNS、**不管隧道 config**；隧道又无通配路由（见第 5 项），删掉 key 会连这 5 条隧道路由一起删掉 → 5 个服务公网直接 404。正确做法是**解耦**（本次实际所做）：
   - `terraform state rm` 掉 5 个 `cloudflare_dns_record.subdomains["…"]`；
   - 把 `cloudflare_dns_record.subdomains` 的 `for_each` 从 `var.ingress_rules` 改到新变量 `var.terraform_managed_dns`（`set(string)`，默认 `[]`）→ terraform 从此管 0 条子域名 CNAME；
   - `ingress_rules` 当时保留全部 5 条继续驱动隧道路由（**后被第 5 项的通配路由取代、已删除**）；
   - `just plan` = No changes（隧道 config 不变、DNS 资源空且 state 空）。✅ 实测通过。
4. `policy` 暂不升 `sync`（见 Consequences）——`upsert-only` 已够用、无必要扩大删除风险面。

### 3. ✅ 已完成（2026-07-20）：oracle-k3s 第二实例 + 10 条记录迁移

oracle-k3s 处境与 homelab 当初一致（`oracle-gateway` 也是 addressless LoadBalancer，`PROGRAMMED=False`），且子域名更多。本轮全量落地：

- **第二个 external-dns 实例**（`just deploy-external-dns-oracle`，`values/external-dns-oracle-values.yaml`）。`txtOwnerId=oracle-externaldns`（**必须**与 homelab 的 `homelab-externaldns` 不同——共享同一 zone，owner id 撞了会互相误判所有权）。upsert-only / gateway-httproute / cloudflare-proxied。
- **Secret 管线**：`cloud/oracle/manifests/base/external-dns.yaml`（ns + ExternalSecret）经 oracle 的 `vault-backend` ClusterSecretStore（走 Tailscale 连 homelab Vault）读**同一把** zone token（`secret/homelab/external-dns` `api_token`）——它是 zone 级 token，对 oracle 子域名同样有效。
- **target**：`oracle-gateway` 无可读地址，故在 `base/gateway.yaml` 打 `external-dns.alpha.kubernetes.io/target=<oracle tunnel>` 注解（同 homelab）。⚠️ **实测 `--default-targets` / `--force-default-targets` 对 addressless gateway source 都不生效**，注解是唯一可行机制。⚠️ 该 gateway 归 oracle-k3s ArgoCD App（selfHeal）管，手动注解会被回滚，故注解必须进 git 由 ArgoCD 施加（本次经 push→ArgoCD 激活并验证）。
- **迁移 10 条**（`rss`/`home`/`status`/`tool`/`pdf`/`squoosh`/`keep`/`slot`/`trends`/`auth`）：预埋 owner=oracle-externaldns 的 TXT → external-dns 零停机接管（连续 `All records are already up to date`，10 条 CNAME `modified_on` 全程未变，含 `auth`/SSO），再 `state rm` + terraform 解耦（同 homelab）。
- **顺带清理**：`notify`（Gotify 已下线）在 oracle tfvars/state 里是过期条目（Cloudflare 已无该记录），随本次 `state rm` + 删 `ingress_rules` 一并清除。

### 4. ✅ 已完成（2026-07-20）：external-dns observability

补的正是"pod 活着但 reconcile 静默失败"这个缺口（token 过期/吊销、API 限流——`KubePodCrashLooping`/`KubePodNotReady` 抓不到）。做法：
- `values/external-dns-values.yaml` 开 `serviceMonitor.enabled: true` + `additionalLabels.release: kube-prometheus-stack`（否则 kube-prometheus-stack 的 serviceMonitorSelector 不采纳）；`just deploy-external-dns` 已部署，实测被 Prometheus 抓到（target up，经 scrapeClasses relabel 带 `cluster=homelab`）。
- 新增 `manifests/external-dns-alerts.yaml`（PrometheusRule，`monitoring` ns，`release` 标签；已加入 `argocd/applications/monitoring-dashboards.yaml` 的 `directory.include` 白名单，随 git push 由 ArgoCD 同步）。4 条告警实测已在 Prometheus 加载、health=ok：
  - `ExternalDNSReconcileStalled`：`time() - external_dns_controller_last_sync_timestamp_seconds{cluster="homelab"} > 600`，for 10m —— 核心盲点（reconcile 静默停摆）。
  - `ExternalDNSRegistryErrors` / `ExternalDNSSourceErrors`：Cloudflare API / HTTPRoute 源读取报错计数上升。
  - `ExternalDNSMetricsAbsent`：metrics 整体消失（controller 挂或 scrape 断，否则会掩盖上面几条），仿照 `ExternalSecretsMetricsAbsent`。

### 5. ✅ 已完成（2026-07-20）：隧道改通配路由，"加子域名只写一个 HTTPRoute" 现已完全成立

原状况（迁移中发现）：cloudflared ingress 是**每个 hostname 一条显式规则** + `http_status:404` 兜底，**无通配**。所以全新子域名 external-dns 虽能自动建 CNAME，但进隧道后 cloudflared 匹配不到 → 落 404。即当初对 `edns-verify-test` 的"端到端"只验了 DNS 解析，没验 HTTP 真能通；"只写一个 HTTPRoute"当时只对 DNS 半步成立。

修复（两集群均已做）：把隧道 ingress 改成单条 `*.meirong.dev -> <cilium gateway>` + `http_status:404` 兜底。gateway 对没有对应 HTTPRoute 的 host 本就返回 404，故通配到 gateway 安全。terraform 里 `ingress_rules` 整个删除，由 `var.gateway_service`（通配目标）取代。**零停机**：现有 hostname 迁移前后都指向同一 gateway，只是从显式规则改走通配匹配。

- homelab：`ce9fd9fe…` tunnel，5 条既有 host 实测仍 200/302/307。
- oracle：`bc630e77…` tunnel，10 条既有 host 实测仍 200/401/307/302（含 `auth`/SSO）。

至此加子域名对两集群都是**只写一个 HTTPRoute**：external-dns 建 CNAME、通配路由转发进 gateway、gateway 按 HTTPRoute 分发。

## 重新评估 / 退出条件

- 若要下线某集群的 external-dns：删该集群的 Helm release + Gateway target 注解 + 对应 ownership TXT（homelab 5 条 `cname-*` owner=homelab-externaldns / oracle 10 条 owner=oracle-externaldns）；因 `upsert-only` 从未删过 CNAME，既有 DNS 不受影响。若要把某条 DNS 交还 terraform：把 hostname 填回该集群 `var.terraform_managed_dns` 并 `terraform import` 回来即可。⚠️ 下线时若也想恢复"隧道显式路由"，需把 `main.tf` 的通配 ingress 改回按 hostname 列举。
- 现状：**两集群全部收口**，无阻塞项。仅剩两条低优先增强（非阻塞）：(a) oracle external-dns 尚无 observability——homelab 的 `external-dns-alerts.yaml` 规则用 `cluster="homelab"` 限定，未覆盖 oracle；oracle metrics 需经其 OTel Collector 抓 `:7979` 并 remote-write 后才谈得上告警。(b) 两实例 `policy` 仍是 `upsert-only`，可按需评估升 `sync`（见上警告）。
