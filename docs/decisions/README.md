# Decisions

> 关键技术决策记录（轻量 ADR）：当时的场景、可选项、为什么这么选。

| 决策 | 结论 |
|------|------|
| [gateway-controller-evaluation](gateway-controller-evaluation.md) | Traefik vs Cilium Gateway → 选 Cilium Gateway API 作唯一入口 |
| [external-dns-adoption](external-dns-adoption.md) | 子域名 DNS 从 Terraform 手管 → HTTPRoute 声明式（`upsert-only` 共存安全） |
| [crossplane-not-adopted](crossplane-not-adopted.md) | ❌ 不引入 Crossplane：最大云面 provider 已死 2 年、控制面管"集群赖以存在"会把 DR 搞复杂 |
| [manual-helm-to-argocd-adoption](manual-helm-to-argocd-adoption.md) | 采纳渲染等价性验证法 + `skipCrds` 解耦 CRD；跨集群同 chart 用 `helm.releaseName` 而非 `fullnameOverride` |
| [manifests-directory-per-app](manifests-directory-per-app.md) | 一个 App 一个目录（目录即清单），废除 `directory.include` glob |
| [no-helm-chart-for-in-house-apps](no-helm-chart-for-in-house-apps.md) | 自研应用一律 kustomize/目录源**不打 chart**；Helm 只用于消费上游 chart |
| [otel-2026-alignment](otel-2026-alignment.md) | homelab collector 首次落地 + oracle 现代化（container operator、持久队列、0.120→0.156） |
| [alerting-telegram-migration](alerting-telegram-migration.md) | gotify-bridge 并发崩溃 → 改 Alertmanager 原生 Telegram，Gotify 整体退役 |
| [opencost-krr-data-sources](opencost-krr-data-sources.md) | 同一 cAdvisor 缺口：OpenCost 走 collector 旁路、KRR 补窄口径采集；否决 krr-enforcer |
| [orphaned-resources](orphaned-resources.md) | 否决 kor（信噪比 0.6%、误判 secret），改用 ArgoCD 原生 `orphanedResources` + `warn: false` |
| [argocd-image-updater](argocd-image-updater.md) | CRD 模型与约束（⚠️ 当前闲置，集群内无 `ImageUpdater` CR） |
| [storage106-experiment-vm](storage106-experiment-vm.md) | ⛔ 已被取代 → `storage106-as-homelab-worker`；原结论"实验田独立小集群"，估算实测偏保守 |
| [storage106-as-homelab-worker](storage106-as-homelab-worker.md) | 106 VM 以 `k8s-worker-106` 入编 homelab（取代上一条）；实测入伙税远低于估算，含三条与控制面不同的约束 |
| [cluster-placement-for-new-services](cluster-placement-for-new-services.md) | 计算密集/大流量走 homelab、轻量无状态默认 oracle-k3s；含必写 CPU limit 与 thermal 代价 |
| [multica-email-delivery](multica-email-delivery.md) | Multica 验证码改走 Gmail SMTP（动机是**停止把验证码写进 Loki**）；否决 Cloudflare（Workers Free 档 Outbound 不可用，实测卡在域名 onboard）与 Resend（接线成本不成比例） |
| [dgx-clustermesh-not-adopted](dgx-clustermesh-not-adopted.md) | ❌ DGX 双机**不接 ClusterMesh**（共享节点不带 subnet route，VXLAN 节点 IP 不可达）；改 homelab Service + 手写 Endpoints |
| [shared-postgres-platform](shared-postgres-platform.md) | 每集群一个共享实例：oracle 手搓 `rss-postgres` → CNPG `apps-pg`（**不**并入 `zitadel-pg`）；homelab 2026-08-25 合并 `litellm-pg`+`multica-postgres`，但**刻意不装 CNPG**；备份都改逐库 `pg_dump` |
| [slo-availability-targets](slo-availability-targets.md) | 99% 推导 + 两维判据；☠️ 实测揭穿分母（vault/argocd 真实流量≈0）；预算只做信号不做闸门 |
| [renovate-adoption](renovate-adoption.md) | 采纳 Renovate 管版本钉扎（🚧 待装 GitHub App）；与 V1-V3 分工；三条自我约束（不 automerge · 不开 pinDigests · 不管 docs/） |
| [cf-analytics-custom-exporter](cf-analytics-custom-exporter.md) | 按域名访问 IP 数自写 exporter：官方/lablabs 实测在 Free zone 全废（`httpRequests1mGroups` 403），且**都只有 zone 级 uniques** |
| [cronjob-and-job-hygiene](cronjob-and-job-hygiene.md) | CronJob 只强制两个 deadline（`activeDeadlineSeconds` 断卡死 + `startingDeadlineSeconds` 防 100-missed 永久停摆）；配额改用 `pods` 而非 `count/pods`；**否决**强制 TTL（与 history limit 重复）与 Kyverno `require-job-ttl`（Enforce 会炸 5 个 Helm hook、Audit 无告警消费） |
| [litellm-llm-gateway](litellm-llm-gateway.md) | 旧 LLM 网关 → **LiteLLM**：配置进 git + 自带认证 + Postgres；双自托管来源 DGX 主 + Mac 兜底 fallback |
| [multimedia-repository-nfs-readonly](multimedia-repository-nfs-readonly.md) | 媒体 serving 重新引入 NFS，但**只读 + 只媒体 + 不装 provisioner**：2026-07-11 退役后的唯一例外；☠️ 副作用是 106 从此不再是"非运行时依赖" |
| [prometheus-series-reduction](prometheus-series-reduction.md) | 砍 series 而非继续抬 limit：k3s 单进程让 kubelet 重复暴露 apiserver/etcd（占该 job 80%）→ 按 job 分别 drop，234k→110k（−53%）；三层证据（规则/看板/抓取层）+ chart 默认值必须原样保留再追加 |
| [omlx-speech-model-selection](omlx-speech-model-selection.md) | ❌ Mac 新增的 4 个语音模型全部不采纳，STT/TTS 接线不动：两个新 TTS **结构上**驱动不了（只能传 `voice`，它们要 `instruct`/参考音频），两个新 ASR 在生产口径（10 分钟 mp3 切段）各有一种 HTTP 200 的静默失败：截断在 45s / 长音频重复崩塌 |
| [argocd-project-per-cluster](argocd-project-per-cluster.md) | 每集群一个 AppProject（homelab / oracle-k3s，各只一条 destination），root / projects 元 App 挂 `default`；写错 destination 改由 ArgoCD 服务端拒绝，H2 加查 project ↔ destination；AppProject 从此由 `projects` App 托管 |
| [home-stack-repo-boundary](home-stack-repo-boundary.md) | `stack.meirong.dev` 上线后两个仓库同写一个 zone：**按资源类型切**（否决「homelab 全管」与「home-stack 全管」）；home-stack 只拥有 Worker + 那一条 DNS 记录，homelab 独占隧道/WAF/zone 设置；☠️ 那条记录别声明第二份、别当游离记录清理 |

## 写新 ADR

- **命名**：描述性 kebab-case `<topic>.md`（如 `external-dns-adoption.md`），日期写在文首、不靠文件名排序。
- **必含**：标题 / 日期 / 状态 / 上下文 Context / 决策 Decision / 后果 Consequences。
- **决策被推翻时不删旧文件**：把文首状态改成 `已废弃`，并链到取代它的记录。
