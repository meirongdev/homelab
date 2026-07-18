# 技术债盘点与演进路线（含 Crossplane 评估）

> 日期: 2026-07-07
> 范围: 仓库技术债 + IaC/GitOps 工具链 2026 选型（软件/工具链层）
> 定位: 承接 [architecture-optimization-2026-07-04](architecture-optimization-2026-07-04.md)（物理层）。回答"是否引入 Crossplane"——**结论：不引入**（§三）。
> 背景: 2026-07-07 已完成一轮 repo↔集群一致性清理（helm pin 对齐、homelab postgres 残留移除、ReferenceGrant v1beta1 回退、gotify-bridge 双 App 争抢去重，22 App 全 Synced/Healthy）。本文是清理后的存量盘点与后续顺序。
> **2026-07-11 更新**: 本文列为"既列未做"/Phase E 的存储本地化迁移（nfs-client → local-path）已完成，见 `docs/plans/ROADMAP.md` Phase 4。

---

## 总诊断

GitOps 覆盖与安全纵深已成熟。剩余债务集中三处：

1. ~~**一个安全债**：ZITADEL 的数据库是 Bitnami 冻结镜像（§一 A）——全仓库唯一"不修会持续变糟"的项。~~ ✅ 2026-07-18 已清偿（Phase C 完成，迁 CNPG PG17）。
2. **一个结构性缺口**：5 个 Terraform root 的 state 全在笔记本本地（§一 B）——笔记本即全部 IaC 的单点。
3. **一个自动化缺口**：无 Renovate，版本 pin 靠手（§一 C）——2026-07-07 发现的 vault/ESO pin 漂移即此后果，会复发。

演进**不需要引入新平台**（Crossplane 属于此类），需要的是把既有工具链补完：CNPG、R2 state backend、Renovate、external-dns——每个都是"一个周末、马上兑现"的量级。

---

## 一、剩余问题清单

### A. 安全债（唯一"必须做"）— ✅ 2026-07-18 已解决

**ZITADEL DB ~~= `bitnamilegacy/postgresql:15.4.0-debian-11-r10`~~ → CNPG `zitadel-pg`（PG 17.6，operator 1.30.0）**。迁移按下方 Phase C 原计划执行，实际停机 ~4.5 分钟；旧 helm release `zitadel-db` + PVC + `zitadel-postgres-auth` ExternalSecret 已全部移除。以下为历史背景：

- 2023-08 构建的镜像；Bitnami 2025-08 商业化后 `bitnamilegacy/` 通道**永久冻结、不再收 CVE 补丁**（`cloud/oracle/manifests/zitadel/zitadel.yaml` 注释已记录）。
- 它存的是**全部 SSO 凭据**——安全债权重最高的一块。
- 流程教训：`zitadel.yaml:102` 写着 "track in TODO"，但一直没进 ROADMAP.md，掉出了跟踪体系（2026-07-07 已补录）。
- 对照：miniflux 的 `postgres:15-alpine`（rss-system）是官方镜像，PG 15 支持至 2027-11，**无债**。

### B. IaC 结构性缺口

1. **Terraform state 全本地**（×5：`cloudflare/terraform`、`proxmox/terraform`、`tailscale/terraform`、`cloud/oracle/terraform`、`cloud/oracle/cloudflare`）。
   - R2 backend 已在 `cloudflare/terraform/provider.tf:11` 写好但**注释掉**。
   - 后果：笔记本丢失/换机 = 逐资源 `import` 重建；state 含明文密钥（CF token 等）却只有一份本地副本；无锁。
   - state 文件未提交进 git（已核查，`.gitignore` 生效）——风险是"丢"，不是"泄"。
2. **新子域名两步走**：`cloudflare/terraform/terraform.tfvars` + `k8s/helm/manifests/gateway.yaml` 手动双改（CONVENTIONS 固定流程），可自动化掉 DNS 一半（§四 Phase D）。

### C. 自动化缺口

**Renovate 缺位**（ROADMAP P2 已列未做）。当前靠手维护的版本面：`k8s/helm/justfile` chart pins、ArgoCD Application `targetRevision`、oracle manifests 镜像 tag/digest。2026-07-07 实测漂移：vault 0.33.0 vs pin 0.32.0、ESO 2.6.0 vs pin 2.1.0——照 pin 重跑会**降级**。没有 Renovate 这类漂移必然复发。

### D. 既列未做（ROADMAP 已跟踪，此处不展开）

存储本地化迁移（nfs-client → local-path）、离站备份（restic → 云）、dead-man's switch、zpool/SMART 告警、DGX Spark 入编、恢复演练自动化。

### E. 卫生项（半小时）

- `justfile` `deploy-prometheus`/`deploy-prometheus-nowait` 各传两次 `--version`（helm 取末位故实际生效 87.6.0，不坏但误导）；死变量 `prometheus_stack_version := "82.10.1"`。
- ~~Vault 孤儿 `secret/homelab/postgres`（2026-07-07 postgres 清理后无消费者）。~~ ✅ 2026-07-18 已删（连同 zitadel-oidc / oracle-k3s/oauth2-proxy / kopia，见 ROADMAP「Vault 孤儿 secret 清理」）。

---

## 二、2026-07 技术现状快照（选型依据）

| 组件 | 2026-07 现状 | 与本仓库的关系 |
|---|---|---|
| [CloudNativePG](https://cloudnative-pg.io/releases/) | 1.28.x；1.26 起支持[声明式 in-place 大版本升级](https://cloudnative-pg.io/docs/1.27/postgres_upgrades/)（内部 `pg_upgrade`）；CNCF Sandbox | ZITADEL DB 迁移目标（Phase C） |
| [OpenTofu](https://opentofu.org/docs/language/settings/backends/s3/) | 1.10+ 原生 S3 锁（`use_lockfile=true`，条件写，免 DynamoDB）；R2 经 S3 兼容端点可用（[R2 原生 backend 讨论中](https://github.com/opentofu/opentofu/issues/3075)） | state 后端（Phase A） |
| [external-dns](https://kubernetes-sigs.github.io/external-dns/latest/docs/sources/gateway-api/) | Gateway API source 已迁 v1 API；HTTPRoute 上读 `cloudflare-proxied`/`ttl` 注解、Gateway 上读 `target`；新增 CF batch API | 子域名自动化（Phase D） |
| ArgoCD | 本仓库已在 v3.3.9（当前线）✅ | 无动作 |
| ESO | 本仓库已在 v2.6.0 ✅（pin 已对齐） | 无动作 |
| [Crossplane](https://docs.crossplane.io/latest/whats-new/) | [v2.0 2025-08 GA](https://www.infoq.com/news/2025/08/crossplane-applications-v2/)，现 v2.3：MR/XR 全面 namespaced、composition functions、去 claim、cluster-scoped MR 转 legacy | **不引入**（§三） |
| Talos Linux | homelab 圈 2026 主流趋势（不可变、纯声明、分钟级重建） | 现在不迁（§五） |

---

## 三、Crossplane 评估（结论：不引入）

### Provider 现实（2026-07 逐一核查）

| 本仓库云面 | Provider | 状态 | 结论 |
|---|---|---|---|
| Cloudflare（最大外部 API 面） | [cdloh/provider-cloudflare](https://github.com/cdloh/provider-cloudflare) | v0.1.0，**2023-01 后无更新**，13 stars，无 v2 支持 | ❌ 死 |
| OCI | [oracle/crossplane-provider-oci](https://github.com/oracle/crossplane-provider-oci) | 官方，upjet family，[已支持 v2](https://blogs.oracle.com/cloud-infrastructure/crossplane-provider-for-oci-crossplane-v2) | ✅ 活，但本仓库仅 1 台实例 |
| Proxmox | 社区 provider | 2026-02 仍有更新，但很年轻 | ⚠️ 不敢托付 VM 生命周期 |
| Tailscale | 无像样 provider | — | ❌ |

### 结构性理由（即使 provider 都活着也不该用）

1. **问题不匹配**。Crossplane v2 的设计目标是"平台团队向多租户提供自助式基础设施 API"（namespaced MR、functions 都为此服务）。单人、两个单节点集群、云资源少而静态（1 台 OCI 实例、1 份 CF zone 配置、几台 PVE VM、1 份 Tailscale ACL），控制器 7×24 reconcile 的收益趋近零。
2. **鸡生蛋**。Crossplane 跑在集群里，去管理"集群赖以存在"的资源（OCI 实例、PVE VM）。集群挂 → 修复工具跟着挂，DR 路径反而变复杂。与母文档"故障域集中"诊断直接冲突。
3. **资源开销**。upjet 系 provider 每 family 常驻数百 MB 内存，吃的正是 homelab 单节点最紧张的资源（母文档 P1-4）。

### 已有痛点的更轻解法

| 痛点 | Crossplane 路线 | 更轻的解 |
|---|---|---|
| 子域名两步走 | CF provider（已死） | **external-dns**（~20MB 控制器，Phase D） |
| Terraform 缺 GitOps 感 | provider-terraform 套娃 | **R2 state + `use_lockfile`**（Phase A）；仍想要 PR 流程再加 GH Actions plan-on-PR |
| 学习/履历动机 | — | oracle-k3s 上装官方 OCI provider 管一个非关键 bucket 当沙箱，**不迁生产路径** |

### 重新评估条件（满足其一再议）

- 出现真实多租户/自助需求（他人向本平台申请资源）；
- Cloudflare 出现官方或活跃维护的 provider，**且** homelab 已有多节点（控制面不再是单点）。

---

## 四、演进顺序（Phase A–E）

排序原则沿用母文档：**数据不可再生 > 告警可达 > 安全债 > 自动化 > 可选**。Phase B 的既有 P0 项仍排在安全债之前——"不可逆损失"比"未打补丁"更致命。

### Phase A — 卫生 + state 上云（半天）

1. §一 E 卫生项清零；ROADMAP.md 勾选状态更新（本次已做）。
2. 5 个 TF root 启用 R2 backend：现成注释配置为底，`use_lockfile = true` + `skip_credentials_validation`/`skip_region_validation`/`skip_requesting_account_id`/`skip_s3_checksum`，逐 root `init -migrate-state`。bucket 私有（state 含密钥）。
3. 可选：顺手切 OpenTofu（`tofu init -migrate-state`）。最小改动 = 只换 backend 不换工具，两条路都通，**先换 backend 再说**。

### Phase B — 既有 P0 收尾（下个周末；顺序维持母文档）

离站备份（restic 仓库 → OCI always-free 20GB / B2）→ dead-man's switch（Watchdog → oracle Uptime Kuma push）→ zpool/SMART PrometheusRule。见 [2026-07-06 计划](../plans/storage/2026-07-06-storage-local-migration-and-backup-redesign.md)。

### Phase C — ZITADEL DB → CloudNativePG ✅ 2026-07-18 完成（实际停机 ~4.5 分钟）

按原计划 1-3 执行完毕：CNPG operator ArgoCD App(`cnpg-operator`,chart 0.29.0) + `Cluster` CR
(`zitadel-pg`,PG 17.6,单实例,local-path 8Gi,凭据复用 Vault `secret/homelab/zitadel`) +
pg_dump/restore 迁移(逐表行数核对) + OIDC/console 实测验证 + 旧 `zitadel-db` 退役。
第 4 条可选项(miniflux 收编 / barman)均未做,维持原"不做也成立"判断。
⚠️ 落地新增经验:备份容器需 `postgresql17-client`(pg_dump 16 拒绝 dump PG17,alpine 升 3.22)。
原计划留档：

1. CNPG operator 以 ArgoCD App 部署到 oracle-k3s（chart 版本 pin 进 Application）。
2. 建 `Cluster` CR：官方 PG 镜像、storage 用 oracle **local-path**（与现 zitadel-db 一致，PG 同步写不走 NFS）、`instances: 1`（单节点集群无 HA 意义，不过度工程）。
3. 迁移：停 ZITADEL → `pg_dump`（restic 备份链已演练过同流程）→ restore 进 CNPG → ZITADEL DSN 指向新 Service → 验证 OIDC → 退役 `zitadel-db` helm release。
4. 可选跟进：miniflux PG 同 operator 收编（无安全债，纯摊薄运维面，不做也成立）；CNPG 原生备份（barman）与现 pg_dump CronJob 二选一，避免双份。

### Phase D — 自动化补课

1. **Renovate**（ROADMAP P2 既有项）：管 `justfile` pins、Application `targetRevision`、oracle manifests 镜像 digest。直接防 §一 C 漂移复发。
2. **external-dns**：`--source=gateway-httproute` + Gateway 上 `external-dns.alpha.kubernetes.io/target: <tunnel-id>.cfargotunnel.com` + HTTPRoute 注解 `cloudflare-proxied`。此后加子域名只写 HTTPRoute 一个文件；Terraform 收缩为 zone/WAF/tunnel 骨架。

### Phase E — 大项（按 ROADMAP 原样，不改优先级）

存储本地化迁移（nfs-client → local-path）、DGX Spark 入编、恢复演练自动化。

---

## 五、明确不做（延续母文档"防过度工程"）

- **Crossplane** — §三。
- **Talos 迁移** — 2026-03 刚在 Ubuntu 24.04 重建完且流程已顺，单节点下收益不抵重建成本。重评条件：新增第二台 worker（届时不可变 OS + 分钟级重建的收益才成立）。
- **cert-manager / Vault HA** — 母文档已否，维持（TLS 边缘终结；单节点 HA 无意义）。

---

## 来源

[Crossplane v2 docs](https://docs.crossplane.io/latest/whats-new/) · [InfoQ: Crossplane v2.0](https://www.infoq.com/news/2025/08/crossplane-applications-v2/) · [oracle/crossplane-provider-oci](https://github.com/oracle/crossplane-provider-oci) · [Oracle blog: OCI provider × Crossplane v2](https://blogs.oracle.com/cloud-infrastructure/crossplane-provider-for-oci-crossplane-v2) · [cdloh/provider-cloudflare](https://github.com/cdloh/provider-cloudflare) · [CloudNativePG releases](https://cloudnative-pg.io/releases/) · [CNPG postgres upgrades](https://cloudnative-pg.io/docs/1.27/postgres_upgrades/) · [OpenTofu S3 backend](https://opentofu.org/docs/language/settings/backends/s3/) · [OpenTofu state in R2](https://blog.jroddev.com/opentofu-state-in-cloudflare-r2-without-giving-cloudflare-plaintext/) · [R2 原生 backend issue](https://github.com/opentofu/opentofu/issues/3075) · [external-dns Gateway API](https://kubernetes-sigs.github.io/external-dns/latest/docs/sources/gateway-api/) · [VSHN: Best K8s Distributions 2026](https://www.vshn.ch/en/blog/best-kubernetes-distributions-in-2026-and-why-you-might-not-want-to-run-them-yourself/)
