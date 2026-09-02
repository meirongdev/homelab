# Homelab Changelog

> Last updated: 2026-09-03
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
| 2026-09-03 | **DGX 主力模型全线换引用**：上游 nv-dgx-spark 2026-09-02 把 :8000 从 `deepseek-v4-flash` 换成 `qwen38-flash-next`（NVFP4，ctx 1M→262k，冷启动 8–11min），旧名已从 `/v1/models` 消失。跟着改的是网关别名 + jobs-sg 直连 + Open Notebook 接线 + oracle calibre 作业，另把 `DgxSparkVllmDown` 的 `for` 10m→15m（新栈加载 8–11min，10m 会被正常重启烧掉）。☠️ 爆炸半径实测：**8 把虚拟 key 的白名单**要同步改 ([网关事实](reference/litellm-gateway.md) · [决策修订](decisions/litellm-llm-gateway.md)) |

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
