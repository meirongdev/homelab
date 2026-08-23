# Reference

> 当前生效的架构事实 source of truth。所有文档中的命令必须注明执行上下文 (cluster/path)。

## 生效事实

改架构就必须同步这些文档。

### 命名与用语

- [terminology.md](terminology.md) — **术语与命名正典唯一真相源**：标识符 vs 散文用语的分界、
  ☠️ 同一个集群在 6 个层各有不同官方名（context `k3s-homelab` 但 Cilium/ArgoCD/指标那层叫
  `homelab`）、`oracle-k3s` 同时是集群名和节点名、"单节点"/"NFS 已退役"的确切范围。
  CI 由 `scripts/check-terminology.py` 强制 T1-T3

### 服务与应用

- [services.md](services.md) — **服务清单唯一真相源**（哪个服务在哪个集群/ns/域名）+ 按服务的运维备忘
- [open-notebook.md](open-notebook.md) — AI 研读知识库：部署形态、模型接线（DGX + Mac OMLX）、配置真相源地图、备份口径
- [jobs-sg.md](jobs-sg.md) — SG 岗位周报：独立 ns + 3 个 CronJob、digest 固定、备份两条路径、bootstrap 依赖
- [calibre-metadata.md](calibre-metadata.md) — 书库元数据：覆盖率实测、mtime 冒充出版日期（487 本）、回补匹配门与判据、拿不到书评/评分的边界

### 网络

- [networking-ingress.md](networking-ingress.md) — 入口链路（Tunnel → Cilium Gateway）、HTTPRoute 约定、external-dns DNS 自动化、节点地址速查
- [tailscale-network.md](tailscale-network.md) — 双集群互联（Tailscale 只做 node underlay、pod 走 ClusterMesh VXLAN）+ 路由踩坑（fwmark 撞车 1/256 抽签）
- [cloudflare-tunnel-observability.md](cloudflare-tunnel-observability.md) — Tunnel + Gateway 流量可观测（能看到什么、看不到什么）
- [public-traffic-analysis.md](public-traffic-analysis.md) — 公网访问分析**唯一真相源**：谁在访问哪个域名、来源分类法（真人/爬虫/自建监控）与可信度、☠️ 自建监控占请求 45%、PromQL 配方、免费版能力边界

### 可观测

- [observability-multicluster.md](observability-multicluster.md) — 日志/指标/链路追踪统一架构（含 dgx-spark/macbook 外部主机与 SMART 采集）
- [observability-otel-logging.md](observability-otel-logging.md) — OTel 日志管道细节 + 4 种应用接入模式
- [observability-alerting-slo.md](observability-alerting-slo.md) — 告警路由（Telegram）与覆盖盲区、Dashboards 组织约定、SLI/SLO（Sloth）
- [omlx-inference-metrics.md](omlx-inference-metrics.md) — Mac OMLX 推理指标：**OMLX 无原生 `/metrics`**，靠**两条互补链路**（json-exporter 两个 job 拿实时状态 + node_exporter textfile 快照拿 `omlx_alltime_*` 的**秒数分母与 per-model 账本**）；☠️ 累计平均 TPS 不是当前速度 / 天花板核算 ≠ 实际内存 / 两套计数器同名不同义（已靠抓取时改名分开）/ null 字段的日志噪音；并发上限 2 与 TTL 900s 等物理约束
- [dead-mans-switch.md](dead-mans-switch.md) — 唯一判定方不与被监控方共命运的告警：目的、6 跳链路、覆盖矩阵与三处失明盲区、演练程序
- [k8s-qos-resource-management.md](k8s-qos-resource-management.md) — 资源配额与 QoS 约定
- [cost-and-rightsizing.md](cost-and-rightsizing.md) — OpenCost 成本归因 + KRR 右尺寸（定价模型、指标语义、运维操作）

### 硬件与功耗

- [homelab-host-power-thermal.md](homelab-host-power-thermal.md) — homelab 宿主功耗/散热事实 + 降温度抓手（AGENTS/security 硬约束唯一真相源）

### 安全与身份

- [security.md](security.md) — 纵深防御 11 层逐层状态 + 威胁覆盖矩阵。⚠️ 第 9 层网络**只到可见性**，无自建 CiliumNetworkPolicy
- [identity.md](identity.md) — ZITADEL 部署形态（HelmChart CR + CNPG）、各应用原生 OIDC 接入、per-app oauth2-proxy、GitHub 联邦 IdP

### 存储与备份

- [storage.md](storage.md) — 全 `local-path` 布局、NFS 退役事实与故障签名、PVC 清单与迁移程序、restic 备份设计

### GitOps

- [argocd-app-patterns.md](argocd-app-patterns.md) — 控制面部署形态、30 个 Application 清单与备注、pattern 对比、新增 Application 的 4 个坑
- [manifest-safety-checks.md](manifest-safety-checks.md) — CI 强制的清单结构规则 H1-H5 + 「静态查不出、只能靠人」的那几类

---

> **本目录只放常青事实。** 带日期的诊断/建议（架构优化、技术债盘点、资源右尺寸建议）
> 属于快照，一律放 [`plans/architecture/`](../plans/architecture/README.md)——2026-07-31 已把 4 篇迁出。
