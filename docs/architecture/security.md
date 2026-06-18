# K3s 集群安全架构 (Security Architecture)

> Last updated: 2026-06-18
> Scope: 双集群（homelab + oracle-k3s）的纵深防御模型 —— source of truth。
> 部署/验证/回滚步骤见 [../runbooks/security-hardening.md](../runbooks/security-hardening.md)；
> 实施决策与权衡见 [../plans/2026-06-16-k3s-security-hardening.md](../plans/2026-06-16-k3s-security-hardening.md)。

## 0. 设计原则（硬约束驱动）

- **单节点热笔记本约束**：homelab 是 Ryzen 5600H 笔记本（idle ~74°C、内存紧、重启需 `just homelab-recover`）。所有安全组件 **fail-open + 控 CPU**：不引入会在故障时阻断调度的 fail-closed 准入，周期/串行扫描优先于常驻高负载。
- **GitOps 优先**：除两类例外（PSA 标签用 `just`、Vault/ESO/argocd 用 Helm），安全策略均经 ArgoCD `git push` 声明式下发。
- **单用户威胁模型**：一个可信运维者、无敌对多租户。据此**有意延后**集群级网络默认拒绝（横向移动收益边际低、debug 成本高）。

## 1. 纵深防御总览

由外到内的层次，每层独立生效（任一层失效不会击穿其余层）：

| # | 层 | 组件 | 状态 | 配置位置 | 集群 |
|---|----|------|------|----------|------|
| 1 | 边缘 | Cloudflare WAF + Tunnel + 限流 | ✅ 生产 | `cloudflare/terraform/waf.tf` | 双（zone 级） |
| 2 | 身份 | ZITADEL OIDC + GitHub 联邦 | ✅ 生产 | `zitadel/`, 各 app values | homelab(IdP) |
| 3 | 密钥 | Vault + ESO + 健康告警 | ✅ 生产 | `k8s/helm/values/vault-*`, `manifests/eso-alerts.yaml` | 双 |
| 4 | 准入：Pod 基线 | Pod Security Admission | ✅ 生产 | `just harden-psa` / oracle ns 清单 | 双 |
| 5 | 准入：策略即代码 | Kyverno（Audit） | ✅ 生产 | `values/kyverno.yaml`, `manifests/kyverno-policies/` | homelab |
| 6 | 供应链/CVE | Trivy Operator | ✅ 生产 | `values/trivy-operator.yaml` | homelab |
| 7 | CIS 合规 | kube-bench（周巡检） | ✅ 已装 | `manifests/kube-bench.yaml` | homelab |
| 8 | 节点加固 | k3s `protect-kernel-defaults` + sysctl | ⏳ 待重启生效 | `k8s/ansible/playbooks/setup-k3s.yaml` | homelab |
| 9 | 网络 | Cilium NetworkPolicy + Hubble 可见性 | 🟡 仅可见性 | Cilium（默认拒绝刻意延后） | 双 |
| 10 | 运行时检测 | Tetragon(homelab) / Falco(oracle) | ❌ Phase 2 未做 | — | — |
| 11 | 备份/恢复 | Kopia（NFS 1Ti） | ✅ 生产（无离站副本） | `manifests/kopia*.yaml` | 双 |
| 12 | 安全可观测 | Prometheus/Loki → Alertmanager → Gotify | ✅ 生产 | `kube-prometheus-stack.yaml`, 各 `*-alerts.yaml` | 双 |

---

## 2. 边缘安全 (Edge) — Cloudflare

- **零暴露端口**：所有外部流量 `Internet → Cloudflare DNS → Tunnel(cloudflared) → Cilium Gateway → Service`，集群无公网入站端口。
- **WAF**（zone 级，覆盖两条 Tunnel 所有子域）：5 条自定义规则（拦 WordPress/PHP 扫描、敏感文件 `.env/.git`、漏扫 UA、非标 HTTP 方法、高威胁分 Managed Challenge）+ 认证端点限流（`/login`,`/oauth2`,`/signin`,`/v1/auth` 30 req/10s/IP）。
- **Zone settings**：SSL Full、TLS 1.2+、Always HTTPS、Browser Integrity Check 等。
- 细节见 CONVENTIONS.md › *Cloudflare WAF & Security*。

## 3. 身份与访问 (Identity) — ZITADEL OIDC

- **单一 IdP**：`auth.meirong.dev`。无共享 ingress 层 SSO；每个服务**要么公开、要么原生 ZITADEL OIDC、要么自带认证**。
- **原生 OIDC apps**：Grafana / Miniflux / Stirling-PDF / KaraKeep / ArgoCD / Bifrost(admin)。各自机密 client 由 `zitadel/scripts/*.sh`(REST) 幂等下发，creds 经 Vault→ESO。**本地账号保留为后备**（无锁死风险）。
- **GitHub 联邦锁定**：instance 级外部 IdP，`isCreationAllowed/isAutoCreation=false` + `autoLinking=EMAIL` —— 陌生人无法自助注册，GitHub 身份仅能按已验证邮箱链接到既有 ZITADEL 用户。
- 细节见 CONVENTIONS.md › *Identity*。

## 4. 密钥管理 (Secrets) — Vault + ESO

- **Vault = 所有 app 密钥的唯一真相源**；ESO 自动同步 Vault → K8s Secret。
- **路径约定**：homelab 用 `secret/homelab/<svc>`，oracle 用 `secret/oracle-k3s/<svc>`。
- **静默陈旧防护**：ESO 健康告警（`externalsecret`/`(cluster)secretstore` `Ready=False`）经 Gotify 报警——堵住"Vault 封印/token 过期 → Secret 不再刷新但 app 仍用旧值"的盲区。规则 `manifests/eso-alerts.yaml`。
- 本地 `.env` 仅用于 bootstrap token（gitignore）。

## 5. 准入管控 (Admission)

### 5.1 Pod Security Admission（基线地板，永远在线）
- 内置准入，零运行时开销，**即使 Kyverno 宕也生效**。
- **下发**：homelab 用 `just harden-psa`（幂等 `kubectl label`，**刻意不走 ArgoCD**——渲染 Namespace 对象的 App 配 prune+selfHeal 有"误同步删 ns + 级联删 PVC"的致命风险）；oracle 在 kustomize 树各 `*/namespace.yaml` 声明。
- **等级矩阵**：

  | enforce | namespace |
  |---------|-----------|
  | `baseline` | default, vault, zitadel, kopia, database, bifrost, personal-services, cloudflare, external-secrets, argocd, kyverno（homelab）；rss-system, homepage, personal-services, cloudflare（oracle） |
  | `privileged`（显式豁免, warn/audit 仍记 baseline） | kube-system, monitoring, kube-bench, trivy-system（homelab）；monitoring（oracle） |

- 不做 `restricted`（grafana 跑 root）；PSA 仅在 Pod 创建/更新时评估，不杀已运行 Pod。

### 5.2 Kyverno（策略即代码，homelab，先 Audit）
- 拆分 controller 各 `replicas:1`、`backgroundScanInterval:24h`、**所有策略 `failurePolicy:Ignore`（fail-open）** —— 单节点上 fail-closed = Kyverno 没起来时全集群无法调度，与恢复路径冲突。
- **4 条 ClusterPolicy（全 per-rule `failureAction:Audit` 起步）**：require-requests-limits / disallow-latest-tag / restrict-image-registries / require-probes。
- **Audit→Enforce 流程**：读 `kubectl get polr -A` 确认某策略零违规 → 改该文件 rule 的 `failureAction:Enforce` → push。当前存量违规（Audit 截图）：require-probes 106、restrict-registries 97（多为裸镜像名，**长期保持 Audit**）、require-limits 74、latest-tag 27。
- 系统 ns 由 Kyverno 默认 resourceFilters 排除（CNI/控制面绝不 gate）。ClusterPolicy 的服务端默认字段经 App `ignoreDifferences` 消除 OutOfSync。

## 6. 供应链与漏洞扫描 (Supply chain / CVE) — Trivy Operator

- **扫描面**：镜像 CVE + 配置审计 + RBAC 评估 + **镜像内暴露密钥**（最高信号）。结果以 CR 落地（`vulnerabilityreports`/`configauditreports`/`exposedsecretreports`/`rbacassessmentreports`）。
- **热节点调优**：`scanJobsConcurrentLimit:1`（串行，杜绝扫描器风暴）+ `builtInTrivyServer`(ClientServer + NFS PVC 持久化漏洞 DB，避免反复重下) + `severity:HIGH,CRITICAL` + `ignoreUnfixed` + 关 `clusterCompliance`（CIS 交给 kube-bench）。
- **接入可观测**：ServiceMonitor（带 `release:kube-prometheus-stack`）→ Prometheus 抓 `trivy_image_vulnerabilities` 等；告警 `manifests/trivy-alerts.yaml`（critical CVE→warning、暴露密钥 High/Critical→**critical**、absent 元告警）经 Gotify；看板 Grafana `Security` 文件夹。

## 7. CIS 合规与节点加固

- **kube-bench**：每周日 05:00 UTC CronJob，**k3s 基准**（`k3s-cis-*`，否则通用基准满屏假 FAIL），结果 stdout→Loki（按 `{namespace="kube-bench"}` 查）。专用 `kube-bench` ns 标 privileged（需 hostPID + host 挂载）。
- **节点加固**（`setup-k3s.yaml`）：`/etc/sysctl.d/31-k8s-protect-kernel.conf`（protect-kernel-defaults 所需 sysctl，先落盘持久化）+ config.yaml `protect-kernel-defaults:true`。**现网需维护窗口 `systemctl restart k3s` 才生效**。API 审计日志**刻意延后**（磁盘紧）。

## 8. 网络安全 (Network) — Cilium + Hubble

- **数据面**：双集群 Cilium（eBPF + VXLAN），具备 `CiliumNetworkPolicy` L3/L4/L7 能力；ClusterMesh 经 Tailscale 互联。
- **当前态：默认放行 + Hubble 可见性**。Hubble 已启用（relay 开），可 `hubble observe` 回答"谁在跟谁通信"——这是日后做默认拒绝的安全前置。
- **默认拒绝刻意延后**：见 §11。已有的 argocd chart 自带 NetworkPolicy 提供部分隔离。

## 9. 安全可观测与告警

- **统一管道**：所有信号 → Prometheus(metrics)/Loki(logs) → Alertmanager → `alertmanager-gotify-bridge` → Gotify。`severity:warning|critical` 路由，`info/Watchdog` 丢弃。
- **新增 `PrometheusRule`/`ServiceMonitor` 必须带 `release:kube-prometheus-stack`** 否则 operator selector 忽略。
- **安全相关规则**：ESO 健康（`eso-alerts.yaml`）、Trivy 发现（`trivy-alerts.yaml`）。多集群靠 `cluster` 标签区分。
- **看板**：Grafana `Security` 文件夹（Trivy 漏洞概览）；Hubble CLI 看网络流。

## 10. 威胁模型与覆盖矩阵

| 威胁 / 攻击面 | 缓解控制 | 覆盖 |
|--------------|----------|------|
| 外部漏洞利用 / 扫描 | Cloudflare WAF + 零暴露端口 + 限流 | ✅ |
| 凭据窃取 / 未授权访问 | ZITADEL OIDC（锁定注册）+ 各 app 认证 | ✅ |
| 密钥泄漏（静态） | Vault + ESO；镜像内密钥由 Trivy exposed-secret 扫描 | ✅ |
| 密钥静默陈旧 | ESO 健康告警 → Gotify | ✅ |
| 不安全 Pod（特权/逃逸） | PSA baseline（双集群） | ✅ |
| 配置劣化（无 limits/probes/latest/不可信仓库） | Kyverno（Audit；逐条转 Enforce） | 🟡 Audit |
| 镜像已知 CVE | Trivy（HIGH/CRITICAL）→ Gotify + 看板 | ✅ |
| 节点/控制面配置不合规 | kube-bench 周巡检 + protect-kernel-defaults | 🟡 待重启 |
| 容器内运行时入侵（起 shell/异常外联/提权） | Tetragon/Falco | ❌ Phase 2 |
| 东西向横向移动 | 网络默认拒绝 | ❌ 延后（仅 Hubble 可见性） |
| 数据丢失 | Kopia 自动备份（P0→P2） | 🟡 无离站副本 |

## 11. 已知缺口与路线图

1. **运行时检测（Phase 2）**：按集群选型——homelab→**Tetragon**（Cilium 原生、内核态过滤省 CPU、不加热）、oracle→**Falco + Falcosidekick→Gotify**（规则开箱即用，CPU 余量大）。
2. **网络默认拒绝（门控灰度）**：Hubble 基线流量 → Cilium 每端点 `PolicyAuditMode` 只记不拦 → 单无状态叶子 ns（personal-services/homepage）试点 CiliumNetworkPolicy（放行 DNS/Envoy/必要 egress）→ soak → 逐 ns 评估，**建议只对对外暴露 ns 做**。
3. **节点 API 审计日志**：延后（磁盘紧）；如开启用 Metadata 级策略 + 严格 maxsize/maxbackup，先确认磁盘余量。
4. **Kyverno Audit→Enforce**：逐条清理存量违规后提升；restrict-image-registries 最久保持 Audit。
5. **离站备份**：所有 Kopia 备份在 NFS 同一主机，无 offsite 副本（既有缺口）。

## 12. 运维入口

| 需求 | 入口 |
|------|------|
| 部署/验证/回滚（Phase 0+1） | [../runbooks/security-hardening.md](../runbooks/security-hardening.md) |
| 实施决策与权衡 | [../plans/2026-06-16-k3s-security-hardening.md](../plans/2026-06-16-k3s-security-hardening.md) |
| 约定速查 | CONVENTIONS.md › *集群内部安全* |
| 备份恢复 | [../runbooks/backup-recovery.md](../runbooks/backup-recovery.md) |
| 重启后恢复 | `just homelab-recover`（k8s/helm） |

### 常用核查命令（context: `k3s-homelab`）
```bash
just psa-status                                            # PSA 标签现状
kubectl get cpol                                           # Kyverno 策略
kubectl get polr -A                                        # Kyverno Audit 违规
kubectl get vulnerabilityreports,exposedsecretreports -A   # Trivy 发现
kubectl create job --from=cronjob/kube-bench kb-once -n kube-bench   # 手动跑 CIS
hubble observe --namespace <ns>                            # 网络流可见性
```
