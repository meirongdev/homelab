# Homelab Changelog

> Last updated: 2026-09-09
> 已经做完的事，一条一行，按阶段/时间倒着找。**这里只回答「做过什么」**——
> 还剩什么没做看 [ROADMAP.md](ROADMAP.md)，现在是什么样看 [reference/](reference/README.md)。
> 2026-09-02 从 ROADMAP 拆出：那份文件长到 23.8KB，9 条开放项被 65 条历史淹没，
> 而 R1 说 ROADMAP 只收开放项、不收实施细节。
>
> 展开细节看链接：复盘在 `records/`，取舍在 `decisions/`，现状在 `reference/`，
> 当时的执行过程在 `plans/`。


### Phase 1：基础设施 ✅

Proxmox Terraform 预配 · Ansible 装 K3s · Helm 应用部署 · LGTM 可观测栈 ·
OTel Collector 替换 Promtail · Loki 面板 4 张（GitOps）· log-exporter sidecar 模式 ·
Oracle Cloud Free Tier K3s · 双集群 OTLP traces → Tempo

### Phase 2：密钥与 GitOps ✅

Vault 部署/初始化/解封 · ESO + `vault-backend` ClusterSecretStore · 全部应用密钥迁入 Vault ·
ArgoCD（auto-sync + selfHeal）· ArgoCD Image Updater（已于 2026-08-03 退役）

### Phase 3：多云与边缘安全 ✅

Tailscale 跨集群 Pod CIDR 路由 · 身份简化（保留 ZITADEL，移除共享入口层 SSO）·
信息管道 Miniflux → Redpanda Connect → KaraKeep（已于 2026-08-14 退役）·
Cloudflare Zone 级 WAF · Uptime Kuma · 双集群从 Flannel 迁 Cilium

### Phase 4：可靠性与备份 ✅

| 时间 | 项目 |
|------|------|
| 2026-03-08 | homelab Ubuntu 24.04 重建（K3s v1.34.5+k3s1 + Cilium 1.19.1）+ Cilium Gateway 恢复 |
| 2026-03-08 | Cilium ClusterMesh 双集群 connected + failover 验证 |
| 2026-03-19 | Loki compactor + retention 168h |
| 2026-06-04 | oracle-k3s 纳入 GitOps（hub-and-spoke，经 Tailscale）([计划](plans/networking/2026-06-04-oracle-k3s-argocd-gitops.md)) |
| 2026-07-05 | Kopia 整体移除（server + CronJob + PVC + Vault secret） |
| 2026-07-06 | **restic 备份上线**：双集群 CronJob 逻辑 dump → 106 ZFS 加密仓库；恢复演练同日通过 ([计划](plans/storage/2026-07-06-storage-local-migration-and-backup-redesign.md)) |
| 2026-07-06 | zpool/SMART 告警上线（`storage-alerts.yaml` 5 条） |
| 2026-07-11 | **存储本地化完成**：106 宕机 3 天后，剩余 PVC + 书库 24G 全迁 `local-path`，nfs-client 卸载 ([storage.md](reference/storage.md)) |
| 2026-07-18 | Alertmanager → 原生 `telegramConfigs`，gotify-bridge 下线 ([决策](decisions/alerting-telegram-migration.md)) |
| 2026-07-19 | **dead-man's switch 打通**：Watchdog → webhook → Uptime Kuma push → Telegram ([dead-mans-switch.md](reference/dead-mans-switch.md)) |
| 2026-07 | **Gotify 彻底退役**：三个消费者处理完后本体 + 路由 + DNS + SLO + backup 条目全删 ([决策](decisions/alerting-telegram-migration.md)) |

### Phase 5：生产加固 ✅

| 时间 | 项目 |
|------|------|
| 2026-06 | **集群内部安全加固**：PSA + Kyverno(Audit) + Trivy + kube-bench + 节点 CIS ([计划](plans/security/2026-06-16-k3s-security-hardening.md) · [security.md](reference/security.md)) |
| 2026-06 | **运行时检测**：Tetragon(homelab) + Falco(oracle) ([计划](plans/security/2026-06-18-runtime-detection.md)) |
| 2026-06-15 | Grafana 面板整改：按 folder 分组、多集群选择器、稳定 datasource uid ([计划](plans/observability/2026-06-15-grafana-dashboard-reorg.md)) |
| 2026-07-06 | **服务重定位脱离 homelab 故障域**：Gotify + ZITADEL → oracle-k3s ([计划](plans/apps/2026-07-04-zitadel-to-oracle-k3s.md)) |
| 2026-07-18 | **ZITADEL DB → CloudNativePG**：PG 15.4 → CNPG 1.30.0 + PG 17.6，停机 ~4.5 分钟 ([identity.md](reference/identity.md)) |
| 2026-07-19/20 | **external-dns 双集群全量** + 隧道改 `*.meirong.dev` 通配 → **新增子域名从此只写一个 HTTPRoute** ([决策](decisions/external-dns-adoption.md)) |
| 2026-07-30 | OpenCost 双集群成本归因 + KRR 周报右尺寸 ([OpenCost](plans/observability/2026-07-30-opencost-multicluster.md) · [KRR](plans/observability/2026-07-30-krr-rightsizing.md) · [决策](decisions/opencost-krr-data-sources.md)) |
| 2026-07-31 | **manual-helm → ArgoCD 采纳**：`kube-prometheus-stack` + `external-dns` ×2；chart 版本唯一真源改为 Application 的 `targetRevision` ([决策](decisions/manual-helm-to-argocd-adoption.md)) |
| 2026-07-31 | **OTel 2026 对齐**：homelab collector 首次落地（此前根本没部署，容器日志从未进 Loki）([决策](decisions/otel-2026-alignment.md)) |
| 2026-07-31 | `manifests/` 目录化（一目录一 App）+ `gateway.yaml` 按路由拆 5 文件 ([决策](decisions/manifests-directory-per-app.md)) |
| 2026-08-02 | **负载迁 oracle-k3s**：Loki+Tempo + ArgoCD 控制面（打破「homelab 死了 ArgoCD 也死了」的鸡生蛋）；途中修掉 tempo 跑在 emptyDir、oracle otel-collector 改 ConfigMap 不重启两个静默 bug ([方案](plans/architecture/2026-08-02-homelab-to-oracle-workload-migration.md) · [runbook](runbooks/argocd-control-plane-on-oracle.md)) |
| 2026-08-02 | **OOM 盲区闭环**（起因：ArgoCD controller 静默 OOMKilled 无告警）：抬 limit + 新增 `ContainerOOMKilled` + `metal-nodes-resources` 组补齐 pve/106/DGX ([告警](reference/observability-alerting-slo.md) · [QoS](reference/k8s-qos-resource-management.md)) |
| 2026-08-03 | **calibre 迁 oracle-k3s**：书库 23G，homelab 磁盘 65%→32%。⚠️ 退役步骤触发级联删除事故，已从 restic 完整恢复并把 4 处内嵌 Namespace 拆成专职文件 ([复盘](records/2026-08-03-namespace-prune-cascade.md)) |
| 2026-08-03 | **PSA `backup` ns 定级闭环**：双集群均 `enforce: privileged`（走特权/豁免路径），从开放项移除（原 #7） |
| 2026-08-03 | **DGX vLLM metrics 探明**（供 #5 入编用）：DGX1 `:8000/metrics` live，DGX2 引擎未起；实测端口与 `vllm.env` 声明不符（详见开放项 #5） |
| 2026-08-06 | **共享 PostgreSQL 平台**：手搓 `rss-postgres` → CNPG `apps-pg`（PG17），逐表对账。刻意不并入 `zitadel-pg`（SSO 库带 `critical`，合库=让 RSS 抢同一个 limit）([决策](decisions/shared-postgres-platform.md)) |
| 2026-08-06 | **PriorityClass 去个人前缀**：`meirong-*` → `critical`/`high`/`bulk`，33 处引用，三步走（PriorityClass 与工作负载分属不同 App，同步无先后保证）([QoS](reference/k8s-qos-resource-management.md)) |
| 2026-08-08 | **jobs-sg 缺陷收口**：修掉 `JobsSgReconcileStale`/`JobsSgIngestStale` 结构性哑火、`work_mode` 拿排班冒充办公地点、写事务撞锁重跑 ([诊断](plans/apps/2026-08-08-jobs-sg-three-defect-diagnosis.md)) |
| 2026-08-08 | **旧 LLM 网关注册退役**：整个 ArgoCD App（网关 + oauth2-proxy + dgx-proxy）删除，由 LiteLLM 接替 ([计划](plans/apps/2026-08-01-litellm-gateway-migration.md)) |
| 2026-08-09 | **探针误杀修复 ×2**：Uptime Kuma（4 天 11 次重启）与 ZITADEL login（27 次）补 `startupProbe` |
| 2026-08-09 | **readlist v0.5.0**：修掉 C/F 两个「静默为 0」结构性缺陷；补 2 条判别力告警（7→9 条） |
| 2026-08-09 | **Cilium identity-mark 撞 Tailscale fwmark**：位段冲突（单 pod 到 `100.64/10` 全超时的 1/256 抽签）([tailscale-network.md](reference/tailscale-network.md)) |
| 2026-08-09 | **oracle journald 持久化**：非正常重启的现场不再每次蒸发 |
| 2026-08-09 | **告警盲区闭环**：DGX 内存告警改 PSI+OOM、补 `NodeRebooted`；dead-man's switch 投递失败不再冒充「告警链路坏了」 |
| 2026-08-10 | **PSA 收口**：`zitadel` ns 从无标签推到 restricted（先补 `securityContext` 再翻 enforce，顺序反了会挡住 Job）+ 清单外 ns 全补齐 + `just psa-check` 漂移哨兵 + CI 规则 H5 ([security.md §5.1](reference/security.md) · [H5](reference/manifest-safety-checks.md)) |
| 2026-08-10 | **KRR 首轮完整分诊**：BestEffort pod oracle 15→5 / homelab 9→1，oracle CPU requests 83%→71%。真正的收获是照出**三处「配置在 git 里却从未生效」**（Helm 静默忽略写错层级的键）([runbook](runbooks/krr-report-triage.md)) |
| 2026-08-10 | **QoS 与 Pod Priority 两条实测推论**：BestEffort 会让 `priorityClassName` 整行失效；带 `system-*-critical` 的 Pod 即使 BestEffort 也排最后 ([QoS](reference/k8s-qos-resource-management.md)) |
| 2026-08-10 | **OOM 告警补齐事前一环**：新增 `ContainerMemoryNearLimit` + `ContainerOOMKilledCadvisor`。⚠️ 同时记录覆盖口径：oracle 侧部分 `container_*` 不进中枢 Prometheus，空结果与「值为 0」外观一致，当天据此误判过一次 ([QoS](reference/k8s-qos-resource-management.md)) |
| 2026-08-10 | **Cilium 双集群 1.19.1→1.20.0**（计划外）：oracle 的 `deploy-cilium` 缺 `--version`，例行部署随 `helm repo update` 静默升版；连带发现 `--reset-values` 会冲掉 clustermesh 的跨集群 CA 信任，唯一真判据是 `cilium status` 的 `retrieved=false` ([tailscale-network.md](reference/tailscale-network.md)) |
| 2026-08-10 | **homelab PriorityClass 分档补齐**（原 #9）：15/36 → 27/36。kyverno 敢归 `bulk` 的判据是实测 webhook `failurePolicy` 为 Ignore = 真 fail-open；sloth 是「设不了」那一类 ([QoS](reference/k8s-qos-resource-management.md)) |
| 2026-08-10 | **CPU limit 的反向陷阱**：node-exporter 配 `200m` 后节流 31%（1m 峰值仅 3m，采集型是亚秒突发，CFS 掐得住而 1m rate 看不见），已撤回；kube-state-metrics 同 limit 实测 0% 故保留。**必须逐个实测** ([runbook](runbooks/krr-report-triage.md)) |
| 2026-08-12 | **oracle DNS 上游冗余真正生效**（原 #8）：此前的 `FallbackDNS=` 是无效修复（不进 `resolv.conf`，而 kubelet 喂 CoreDNS 的正是该文件），与「已修」的自我认知并存了十来天。改 `DNS=` + 重建 CoreDNS pod，并做了掐断演练实证 ([复盘](records/2026-08-01-oracle-k3s-dns-outage.md)) |
| 2026-08-16 | **LiteLLM LLM 网关落地**：`llm.meirong.dev` 上线（DGX 主 + Mac 兜底 fallback），旧网关全线退役 ([决策](decisions/litellm-llm-gateway.md) · [网关事实](reference/litellm-gateway.md)) |
| 2026-08-23 | **集群外三站点补上可用性监控**（原 #13）。☠️ 顺带揪出 uptime-kuma provisioner 一个静默滞后 bug：`add_monitor()` 后 `get_monitors()` 看不见刚建的监控，状态页**落后一次运行**而三条日志全绿 ([决策](decisions/home-stack-repo-boundary.md) · [services.md](reference/services.md)) |
| 2026-08-24 | **capacity 两条告警改为覆盖两集群**（原 #14）：`Homelab*` → `Cluster*RequestsSaturated`，`sum()` 改 `sum by (cluster)`。**教训：写死集群的选择器会在采集面变化后静默失效** ([告警](reference/observability-alerting-slo.md)) |
| 2026-08-24 | **external-dns 元故障告警改为覆盖两集群**（原 #7）：改法刻意不是加一条 `absent(...)`（覆盖 N 集群要硬编码 N 个名字），而是 `count by (cluster) … unless …` 拿 deployment 副本数作参照，自维护且语义更准 ([决策](decisions/external-dns-adoption.md)) |
| 2026-08-25 | **Nakama 游戏后端上线**：3.40.0，**无 PVC**，状态全在 `apps-pg` 第三个租户。密钥走 ESO 渲染整份 `config.yml` 挂成文件，不进命令行（Nakama 的密钥都是 flag）。☠️ 管理台裸挂公网只有自带口令，已记入 [security.md 已知缺口](reference/security.md) · [services.md](reference/services.md) |
| 2026-08-25 | **homelab 两个 Postgres 收敛成一个**：`litellm-pg` + `multica-postgres` → `databases/apps-pg`，逐表对账。**刻意不装 CNPG**（operator 自身开销比省下的 postmaster 还贵），所以两集群的 `apps-pg` 同名同角色但形态不同 ([决策四](decisions/shared-postgres-platform.md)) |
| 2026-08-26 | **接上 godot-games**：Nakama 挂服务端 Lua 模块（initContainer 从 OCI 镜像拷入，换 tag 即发版）+ 按契约设 `runtime.lua_{min,max}_count`（**必须成对**，只调 max 直接启动失败）+ 新服务 `game.meirong.dev` ([services.md](reference/services.md)) |
| 2026-08-27 | **游戏大厅打通**：`game.meirong.dev` 的 HTTPRoute 变三条规则（`/v2/*` + `/ws` → nakama，其余静态站）。☠️ **上游 e2e 直连 nakama 域名、结构上绕过这两条**，路由漏写 e2e 照样全绿，唯一判据是用浏览器真开一次 ([services.md](reference/services.md)) |
| 2026-09-03 | **jobs-sg 升到 `0632049` + `LLM_RETRIES=0`**：上游把模型相关参数全部下沉成 `LLM_*`（换模型不再改代码/发版），并填掉那条"关思考的 kwargs 键名换栈后静默空操作"的坑（键名改成 `LLM_THINKING_KWARG`，默认 `enable_thinking`；仍在推理时自己打 WARN）。耗时按新模型回校：均值 18.7s、15 条/分钟（抽样）与本仓库整轮 6.9 条/分钟并列记录，约 1.3% 调用超 300s → 对策是关掉当场重试（`LLM_RETRIES=0`）而不是加大超时或封顶 token。☠️ 刻意**不设** `LLM_THINKING`：积压已排空（backlog=3），拿抽取质量换速度不划算 ([jobs-sg.md](reference/jobs-sg.md)) |
| 2026-09-03 | **DGX 主力模型全线换引用**：上游 nv-dgx-spark 2026-09-02 把 :8000 从 `deepseek-v4-flash` 换成 `qwen38-flash-next`（NVFP4，ctx 1M→262k，冷启动 8–11min），旧名已从 `/v1/models` 消失。跟着改的是网关别名 + jobs-sg 直连 + Open Notebook 接线 + oracle calibre 作业，另把 `DgxSparkVllmDown` 的 `for` 10m→15m（新栈加载 8–11min，10m 会被正常重启烧掉）。☠️ 爆炸半径实测：**8 把虚拟 key 的白名单**要同步改 ([网关事实](reference/litellm-gateway.md) · [决策修订](decisions/litellm-llm-gateway.md)) |
| 2026-09-04 | **jobs-sg enrich 稳态给推理封顶**（`LLM_EXTRA_BODY={"reasoning_effort":"medium"}`）：qwen38-flash-next 在长岗位上把推理写飞，超时从 1.2%（3/242）一夜变 7.8%（21/269），而引擎读数与前夜一致——不是 DGX 慢，是生成长度没有上界（跑飞那条 16754 completion token，16448 是推理）。跑飞率随正文长度上升（<1500 字符 0/54，>3500 字符 15.9%）。☠️ `chat_template_kwargs` 的三个推理预算键全部静默无效，生效的是顶层 `reasoning_effort`，本文早前先写反了（判据错选成"能不能关掉推理"），且它的失效形态是 HTTP 400 整轮全挂。实测封顶后：前夜超时的 5 条全部 8–22s 完成、抽词更全，8 条正常岗位 244s→82s ([jobs-sg.md](reference/jobs-sg.md)) |
| 2026-09-07 | **博客按文章的访问量**：cf-analytics-exporter 加 `clientRequestPath` 维度（html+200 过滤后 962 行/天，不过滤直接撞 1000 行截断）+ `/pages.csv`；`blog-stats-rollup` CronJob 每天 UPSERT 进 `apps-pg` 第四个租户 `blogstats`，把 Cloudflare 的 8 天窗口变成长期表。☠️「浏览器请求」是真人近似不是真人数（免费版无 `botScore`）([决策](decisions/blog-pageview-rollup-store.md) · [口径](reference/public-traffic-analysis.md)) |
| 2026-09-08 | **博客访问量管道激活 + 修一个只在运行时才现形的缺陷**：三步激活跑完（Vault 口令 → `apps-pg` 建 `blogstats`/`blogstats_ro` 租户 → 首轮验证），表里 3345 行 / 2026-08-31..09-06，CronJob 转 `suspend: false`。☠️ 首轮直接失败：内联进 `args` 的 `DO $$` 被 **kubelet 的 `$(VAR)` 展开**吃掉一个 `$`（`$$` 是「字面 `$`」的转义），psql 报 `syntax error at or near "$"` —— **git 与 CronJob 对象里存的都是对的，只有运行时那一刻是坏的**，所以 `kubectl get -o yaml` 比对与 `check-render` 都查不出，唯一判据是真跑一轮；修法是把 SQL 逐字挪进 ConfigMap。☠️ 另一个静默坑：Grafana 的数据源口令是 `optional: true` 的 env，**Secret 后到不会刷新 env**（`optional` 下变量是整个缺失而非空串），于是「三个 ExternalSecret 全绿 + 表里有行 + pod Running」同时为真而面板连不上库，收口判据必须是面板真出数。resources 按 cgroup `memory.peak` 实测收到 requests 16Mi / limits 64Mi（峰值 4.1Mi，`memory.events` 全 0 证明未被截断）([决策](decisions/blog-pageview-rollup-store.md)) |
| 2026-09-08 | **opsx / OpenSpec 整套移除**（ROADMAP 开放项 #14 收在「停用」这条）：50 个文件、横跨 **6 个** agent 目录（当时记的是 5 个，`.github/` 也各存了一份）——`.agent/` `.codex/` `.gemini/` `openspec/` 整目录 + `.claude/{commands,skills/openspec-*}` `.github/{prompts,skills}` `.qwen/{commands,skills/openspec-*}`。判据不是占地方：`openspec/` 整体 gitignore 导致**产物不落库**（`specs/` 空、`changes/` 只剩空 `archive/`），而本仓库设计产物只认 `docs/plans/` + `docs/decisions/`；同一批 4 个 `SKILL.md` 复制成 24 份还让技能发现看到重复条目。☠️ **git 里一个都没有**（全部 gitignore），所以提交里只体现为 `.gitignore` 与文档改动，删除本身不可由 git 还原。⚠️ `.agent/`（已删）与 `.agents/`（vendored 第三方技能，进 git）差一个 s，别搞混 ([边界](reference/agent-tooling.md)) |
| 2026-09-08 | **`sync-ebooks` 两份实现合一**（ROADMAP 开放项 #15）：python 版删除，其超时 / `status.phase=Running` 过滤 / 全参数化 / 「校验失败带原因」并入 `scripts/sync-ebooks.sh`，技能壳只留指针。☠️ **合并时才发现 bash 那份此前根本跑不通**，三个静默缺陷叠在一起，四条 `just sync-ebooks*` 配方一直空转：① `load_config` 末尾 `[[ -f conf ]] && source` 在缺 conf 时返回 1，`set -e` 下 main 第二行静默 exit 1（而 conf 从不在 git 里 → 全新克隆必中）；② `validate_epub` 把 `sys.exit(0)` 放进 `try` 配裸 `except:`，**裸 except 捕获 SystemExit** → 每本合法 epub 都判「损坏」；③ `is_ebook` 循环变量 `f` 没 `local`，与调用方 `do_check` 同名，一返回 `$f` 就从全路径变成字面量 `epub`。另修：DB 读失败/返回 0 标题时**中止**而非当空书库继续（否则去重被绕过、整批重复入库）、被启发式过滤的文件不再静默丢弃、日志函数加 `|| true`（一句告警曾能杀掉整个脚本）。超时用 `kubectl --request-timeout`（原生，本机无 GNU `timeout`）——实测它只封顶单请求、不封顶总时长。验证：对真实 2128 本书库跑分类，5 个用例全对；传输+sha256 三向验证（一致 0 / 内容不同非零 / 远端缺失非零），全程未向书库入任何书 ([指南](guides/ebook-sync.md)) |
| 2026-09-08 | **oracle 单体 kustomize 树拆成一目录一个 App**（ROADMAP 开放项 #13）：`oracle-k3s` 从 141 个对象降到 45（只剩 `base/` + **12 个 Namespace** + databases/homepage/falco 凭据/backup overlay），五组工作负载拆成 `oracle-rss` / `oracle-uptime-kuma` / `oracle-personal-services` / `oracle-monitoring` / `oracle-zitadel`。☠️ **runbook 原来的步骤 2 是错的、照做会死锁**：ArgoCD 不会把已被别的 App 拥有的对象让出去，新 App 只报 `SharedResourceWarning` 并永久 OutOfSync（判据是 `generation` 全程不变 —— 两边并没有互相改写，是新 App 在拒绝接管，手动 Sync 多少次都不会翻）。实测出的唯一零停机路径是**先把 `oracle-k3s` 的 prune 临时改成 false**：旧 App 不再管这些对象、但不删除，新 App 原地接管注解。⚠️ 全部 `namespace.yaml` 留在 `oracle-k3s`（ns 被 prune 会级联删光，`Prune=false` 拦不住）；`monitoring/` 必须保留 kustomize（configMapGenerator 的哈希驱动 DaemonSet 滚动，且其配置文件无 apiVersion/kind、目录源会当清单 apply 并失败）。验证：38 个 App 全绿 · 20 个 ns 与基线完全一致 · **74 个 pod 零重启** · 11 个 PVC 全 Bound · 七个对外域名正常 · otel-collector 的 ConfigMap 仍是 `-5989tb9bmm` 且 age 2d（未重建） ([runbook](runbooks/oracle-manifests-split-to-apps.md) · [所有权地图](../cloud/oracle/manifests/README.md)) |
| 2026-09-08 | **prometheus-operator 的 10 个 CRD 交 ArgoCD 接管**（ROADMAP 开放项 #4）：去掉 `skipCrds: true`，CRD 之后随 chart 版本自动跟进，不再攒漂移（`helm upgrade` 从不升 chart 的 `crds/`，所以它们一直停在 operator v0.89.0 而实际跑 v0.92.1）。动手前的决定性安全检查：**chart 里每个 CRD 的 versions 必须仍包含 live 的 storedVersions**，10 个逐个核对通过（v1↔v1、v1alpha1↔v1alpha1，无一移除）→ 升级不可能孤立既有 CR。实测：`controller-gen` v0.19.0→v0.21.0（确认换新）· **72 个 CR 一个没少** · Prometheus 规则数前后均 404 · 三个监控 pod 零重启。☠️ 代价：CRD 进了清单集而该 App `prune: true`，chart 哪天移除某个 CRD 会级联删光该类型全部 CR，大版本升级前要 diff `crds/` 文件数 ([决策二](decisions/manual-helm-to-argocd-adoption.md)) |
| 2026-09-08 | **网关加 codex 多 agent 兼容层**：codex 的 `multi_agent_version: "v2"` 把 agent 间消息（父→子 NEW_TASK、子→父 FINAL_ANSWER）作为私有的 `agent_message` item 发进 `/v1/responses` 的 `input`，而自托管上游拿 openai-python 的 `ResponseInputItemParam` union 校验请求体、不认这个类型 → HTTP 400，表现为「一派 subagent 就 Agent errored」，任何强制 dispatch subagent 的 skill（`understand` 之类）在 DGX 上一律跑不了。修法是 LiteLLM 的 `async_pre_call_hook`（`codex_compat.py`）在转发前把它降级成 `role=user` 的 message —— 无损，因为正文本身就带 `Message Type: … / Sender: …` 信封，而 codex 给模型的系统提示就是按这个格式教它读的。拿 DGX vLLM 的 `/openapi.json` 数过：`input` 只接受 30 种 `type`，codex 会发而它不认的就 4 种（另三种 `context_compaction` / `encrypted_function_args` / `internal_chat_message_metadata_passthrough` 一并处理）。☠️ **那句 `Input should be 'shell_call'` 是误导**：跟 shell 工具无关，只是 pydantic 把整个 union 挨个试了一遍。☠️ **修掉 400 不等于 v2 能用**：v2 派任务时那条 NEW_TASK 的 payload 是空的（父 agent 的 spawn_agent 参数里 message 明明在），判据是它出现在**子 agent 自己的本地 rollout 里**——rollout 在发 HTTP 之前就写好了，与网关无关；三种 catalog 组合、传不传 fork_turns 全复现，合理推断是 v2 的任务投递依赖 OpenAI 后端的线程状态。所以客户端侧的结论是反的：**别给自托管模型写 catalog 条目**，没有条目时协作走客户端侧投递（任务作为普通 message 进子 agent），实测 ALPHA/BETA/GAMMA 全回来；代价是启动警告 + 无自动压缩阈值。本 hook 的价值因此是兜底（以后 codex 改默认或谁手开 v2 都不再撞 400，另三种 item 类型也不限于多 agent 场景）。验证：同一份真实 payload 经网关改写前 400、改写后 200 ([坑 D](reference/litellm-gateway.md)) |
| 2026-09-09 | **Proxmox 层体检与收口**：两台 VM 的盘都是 `discard=ignore`，客户机 fstrim 每周自报 "trimmed 32 GiB" 却被 QEMU 全部丢弃，thin LV 实占 98%（118G）而客户机只用 40G，周备因此全读 120G、归档 48GB 且零块仅 4% —— terraform 改 `discard=on` + `ssd` + `iothread`（virtio-scsi-single）+ `vga=serial0`，**pending 到 VM 下次重启**（provider 的 `reboot_after_update` 默认会当场重启控制面，已显式关掉；runbook 补了重启前 `qm pending`、重启后 `fstrim -av` + `lvs` 验证）。两台 VM 加 `protection=1`（API 拒删）与真实 tags/description（106 那台现网一直自述「实验田」，main.tf 改了没 apply）；pve root 与 106 root 同构：真值进 `variables.tf`（此前 tfvars/默认值/example 三处三个数，git 里没一处对）、`_tunnel` 隧道、删掉 `destroy -auto-approve` 与会 rm 掉本地 state 的 `clean`。vzdump 周备补上监控面：两台宿主 `vzdump-textfile` 采集器 + `vzdump-backups` 四条告警（此前 `notifications.cfg` 不存在、失败无人知道）。☠️ 顺带查明 106 的 vzdump 目标在根数据集被 sanoid 快照钉着 9 份归档（keep-last=3），留作策略决定（开放项 #16）([storage.md](reference/storage.md) · [runbook](runbooks/proxmox-host-upgrade.md)) |

### 审计与清理（历史）

| 时间 | 内容 |
|------|------|
| 2026-07-07 | repo↔集群一致性清零：helm pin 对齐、homelab postgres 残留移除、ReferenceGrant v1beta1、gotify-bridge 双 App 争抢去重 |
| 2026-07-12 | 双集群清理审计：孤儿 Job×7 / 0 副本 RS×97 / 未用镜像 ≈19G；**falco inotify 根因修复**（默认 `max_user_instances` 128 导致崩了 23 天）([security.md](reference/security.md)) |
| 2026-07-12 | justfile 卫生：`deploy-prometheus` 双 `--version` 去重、`loki_version` 对齐 ArgoCD、Kopia 退役残留清除 |
| 2026-07-12 | 仓库级第二轮审计：**`sync-ebooks.sh` 真实 bug**（checksum 在孤儿 NFS 快照副本上核对，全程报绿但书从未入库）· PSA 清单漂移补 `kube-bench` · 死链修正 · 6 个 terraform root 的 lock 文件纳入版本控制 |
| 2026-07-12 | **Tailscale 根因修复**：mbpm5 停止广播 `192.168.50.0/24`，pve 保留为唯一 subnet router。`nfs-lan-route` ip-rule 经实测裁定**永久保留** ([tailscale-network.md](reference/tailscale-network.md)) |
| 2026-07-18 | **Vault 孤儿 secret 清理**：交叉核对后销毁 4 个无消费者的 path，剩余 16 个全部有消费者。⚠️ `secret/homelab/zitadel` 是活的，别和已删的 `zitadel-oidc` 搞混 |
| 2026-07-31 | 本地明文 Vault 清单 `vault_values.md` 实际删除。⚠️ 此前 07-18 就声明"已删除"但文件一直在磁盘上。它是 gitignored 的，**删除不产生 diff，所以声明落空没人发现** ([security.md §4](reference/security.md)) |
| 2026-08-03 | **ArgoCD Image Updater 退役**：0 个 CR、空转数月的控制器卸载，旧式注解一并移除。机制文档保留 ([决策](decisions/argocd-image-updater.md)) |
| 2026-08-06 | **oracle VM 清理**：`crictl rmi --prune` 删 32 个死镜像，回收 9GB。积压原因是镜像 GC 为阈值触发（磁盘 85%）而实际才 37%，**从未跑过** ([清理表](runbooks/stateful-service-cross-cluster-migration.md)) |
| 2026-08-06 | **image-updater 残留凭据清除**：退役 3 天后 kustomize 树里仍在**每分钟从 Vault 拉一次 GitHub 凭据**，产出两个无人消费的 Secret |
| 2026-08-06 | **孤儿资源复跑**（控制面迁 oracle 后首次双集群跑）：信号面各 6 条，**真孤儿 0 条**。另汇总 4 条永久孤儿（不入 git 的 bootstrap 依赖），刻意不进 ignore，那份清单就是「从 Git 重建会缺什么」([决策](decisions/orphaned-resources.md)) |
| 2026-08-13 | **月度恢复演练自动化**（原 #6）：`restic-restore-drill` CronJob 每月真恢复 + 8 条判据，配 3 条告警。☠️ 判据敏感度用损坏数据逐条实测，7 种坏法全判出 ([storage.md](reference/storage.md)) |
| 2026-08-13 | **Renovate + 版本配对 CI**（原 #12 之一）：`renovate.json5` + `check-version-pairs.py` 的 V1-V3，六个破坏场景实测全判红。⚠️ **仍待人工装一次 GitHub App** 才会真正开 PR ([决策](decisions/renovate-adoption.md)) |
| 2026-08-14 | **信息管道（Miniflux→KaraKeep）退役**：两个 Deployment + 路由 + 监控 + 备份白名单全删，Miniflux/RSSHub 保留；释放 oracle ~1Gi requests ([原方案](plans/archive/2026-02-28-info-pipeline-miniflux-karakeep-gotify.md)) |
