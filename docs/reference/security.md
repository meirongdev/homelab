# K3s 集群安全架构 (Security Architecture)

> Last updated: 2026-08-04
> Status: 生效事实
> Scope: 双集群（homelab + oracle-k3s）的纵深防御模型 —— source of truth。
> 部署/验证/回滚步骤见 [../runbooks/security-hardening.md](../runbooks/security-hardening.md)；
> 实施决策与权衡见 [../plans/security/2026-06-16-k3s-security-hardening.md](../plans/security/2026-06-16-k3s-security-hardening.md)。

## 0. 设计原则（硬约束驱动）

- **单节点热笔记本约束**：homelab 是 Ryzen 5600H 笔记本（idle ~74°C、内存紧、重启需 `just homelab-recover`）。所有安全组件 **fail-open + 控 CPU**：不引入会在故障时阻断调度的 fail-closed 准入，周期/串行扫描优先于常驻高负载。
- **GitOps 优先**：除两类例外（PSA 标签用 `just`、Vault/ESO/argocd 用 Helm），安全策略均经 ArgoCD `git push` 声明式下发。
- **单用户威胁模型**：一个可信运维者、无敌对多租户。据此**有意延后**集群级网络默认拒绝（横向移动收益边际低、debug 成本高）。

## 1. 纵深防御总览

由外到内的层次，每层独立生效（任一层失效不会击穿其余层）：

| # | 层 | 组件 | 状态 | 配置位置 | 集群 |
|---|----|------|------|----------|------|
| 1 | 边缘 | Cloudflare WAF + Tunnel + 限流 | ✅ 生产 | `cloudflare/terraform/waf.tf` | 双（zone 级） |
| 2 | 身份 | ZITADEL OIDC + GitHub 联邦 | ✅ 生产 | `zitadel/`, 各 app values | oracle-k3s(IdP，2026-07-06 迁自 homelab，见 [zitadel-to-oracle-k3s.md](../plans/apps/2026-07-04-zitadel-to-oracle-k3s.md)) |
| 3 | 密钥 | Vault + ESO + 健康告警 | ✅ 生产 | `k8s/helm/values/vault-*`, `manifests/monitoring/alerts/eso-alerts.yaml` | 双 |
| 4 | 准入：Pod 基线 | Pod Security Admission | ✅ 生产 | `just harden-psa` / oracle ns 清单 | 双 |
| 5 | 准入：策略即代码 | Kyverno（Audit） | ✅ 生产 | `values/kyverno.yaml`, `manifests/kyverno-policies/` | homelab |
| 6 | 供应链/CVE | Trivy Operator | ✅ 生产 | `values/trivy-operator.yaml` · `values/trivy-operator-oracle.yaml` | **双集群**（oracle 2026-08-03 补齐）|
| 7 | CIS 合规 | kube-bench（周巡检） | ✅ 已装 | `manifests/kube-bench/kube-bench.yaml` | homelab |
| 8 | 节点加固 | k3s `protect-kernel-defaults` + sysctl | ⏳ 待重启生效 | `k8s/ansible/playbooks/setup-k3s.yaml` | homelab |
| 9 | 网络 | Cilium NetworkPolicy + Hubble 可见性 | 🟡 仅可见性 | Cilium（默认拒绝刻意延后） | 双 |
| 10 | 运行时检测 | Tetragon(homelab) / Falco+Falcosidekick(oracle) | ✅ 已实现（Falco→Telegram 已接通，2026-07 起原生 output，不再经 Gotify） | `values/{tetragon,falco}.yaml` | 双（分别选型） |
| 11 | 备份/恢复 | restic（106 ZFS 加密仓库）| 🟡 Phase1 上线（双集群每夜备份 + 恢复演练通过；**离站副本待做**）| `runbooks/backup-recovery.md` | 双 |
| 12 | 安全可观测 | Prometheus/Loki → Alertmanager → Telegram（homelab）/ Falcosidekick → Telegram 直推（oracle Falco） | ✅ 生产 | `kube-prometheus-stack.yaml`, 各 `*-alerts.yaml` | 双 |

---

## 2. 边缘安全 (Edge) — Cloudflare

- **零暴露端口**：所有外部流量 `Internet → Cloudflare DNS → Tunnel(cloudflared) → Cilium Gateway → Service`，集群无公网入站端口。入口链路细节见 [networking-ingress.md](networking-ingress.md)。
- **WAF**（zone 级，覆盖两条 Tunnel 所有子域；`cloudflare/terraform/waf.tf`，`just apply` 部署）：5 条自定义规则用满免费额度（拦 WordPress/PHP 扫描、敏感文件 `.env/.git`、漏扫 UA、非标 HTTP 方法、高威胁分 Managed Challenge）+ **1 条**限流规则（免费额度就 1 条，共用一个计数器）：认证端点（`/login`,`/oauth2`,`/api/login`,`/signin`,`/v1/auth`）**外加** `draw.meirong.dev` 的 `/socket.io/`（Excalidraw 2026-08-04 去掉 SSO 后，那是个公开的协作中继），30 req/10s/IP+colo → 封 10s。Pro 计划才有 Managed Ruleset (SQLi/XSS/RCE)/OWASP CRS/泄漏凭据检测（见 `waf.tf` 注释段）。
- **Zone settings**：SSL Full、TLS 1.2+、Always HTTPS、Security Level Medium、Browser Integrity Check、Email Obfuscation、Hotlink Protection、Opportunistic Encryption。
- **API Token 权限**：Zone DNS Edit + Zone WAF Edit + Zone Settings Edit + Cloudflare Tunnel Edit。

## 3. 身份与访问 (Identity) — ZITADEL OIDC

- **单一 IdP**：`auth.meirong.dev`。无共享 ingress 层 SSO；每个服务**要么公开、要么原生 ZITADEL OIDC、要么自带认证**。
- **原生 OIDC apps**：Grafana / Miniflux / Stirling-PDF / KaraKeep / ArgoCD / Bifrost(admin)。各自机密 client 由 `zitadel/scripts/*.sh`(REST) 幂等下发，creds 经 Vault→ESO。**本地账号保留为后备**（无锁死风险）。
- **GitHub 联邦锁定**：instance 级外部 IdP，`isCreationAllowed/isAutoCreation=false` + `autoLinking=EMAIL` —— 陌生人无法自助注册，GitHub 身份仅能按已验证邮箱链接到既有 ZITADEL 用户。
- 部署形态与各 app 接入细节见 [identity.md](identity.md)。

## 4. 密钥管理 (Secrets) — Vault + ESO

- **Vault = 所有 app 密钥的唯一真相源**；ESO 自动同步 Vault → K8s Secret。
- **路径约定**：homelab 用 `secret/homelab/<svc>`，oracle 用 `secret/oracle-k3s/<svc>`。
- **静默陈旧防护**：ESO 健康告警（`externalsecret`/`(cluster)secretstore` `Ready=False`）经 Telegram 报警——堵住"Vault 封印/token 过期 → Secret 不再刷新但 app 仍用旧值"的盲区。规则 `manifests/monitoring/alerts/eso-alerts.yaml`。
- 本地 `.env` 仅用于 bootstrap token（gitignore）。
- **不留常驻明文 Vault 清单**：旧的 `k8s/helm/values/vault_values.md` dump 已删（2026-07-31），不得重建为常驻文件——按需生成、用完即删；`.gitignore` 的 `**/vault_values.md` 规则保留作护栏。Vault 本身就是真相源（有夜备）；陈旧 dump 比没有更糟——最后那份有 10 条死路径、漏 12 条活路径。

## 5. 准入管控 (Admission)

### 5.1 Pod Security Admission（基线地板，永远在线）
- 内置准入，零运行时开销，**即使 Kyverno 宕也生效**。
- **下发**：homelab 用 `just harden-psa`（幂等 `kubectl label`，**刻意不走 ArgoCD**——渲染 Namespace 对象的 App 配 prune+selfHeal 有"误同步删 ns + 级联删 PVC"的致命风险）；oracle 在 kustomize 树各 `*/namespace.yaml` 声明。
- **等级矩阵**：

  | enforce | namespace |
  |---------|-----------|
  | `baseline` | default, vault, bifrost, personal-services, cloudflare, external-secrets, argocd, kyverno（homelab）；rss-system, homepage, personal-services, cloudflare（oracle） |
  | `privileged`（显式豁免, warn/audit 仍记 baseline） | kube-system, monitoring, trivy-system, tetragon, kube-bench（homelab）；monitoring（oracle） |

- 不做 `restricted`（grafana 跑 root）；PSA 仅在 Pod 创建/更新时评估，不杀已运行 Pod。

### 5.2 Kyverno（策略即代码，homelab）
- 拆分 controller 各 `replicas:1`、`backgroundScanInterval:24h`、**所有策略 `failurePolicy:Ignore`（fail-open）** —— 单节点上 fail-closed = Kyverno 没起来时全集群无法调度，与恢复路径冲突。
- **4 条 ClusterPolicy**（per-rule `failureAction`），**2026-06-18 audit 后的状态**：

  | 策略 | Action | 说明 |
  |------|--------|------|
  | disallow-latest-tag | **Enforce** | digest-aware（只拦 `:latest`，放行 digest/正常 tag）；运行中工作负载全 digest 固定，零阻断 |
  | require-requests-limits | Audit | 失败主要在 monitoring/kube-system(chart/系统)；应用 ns 经 LimitRange 护栏(§5.3)逐步达标后再考虑按 ns Enforce |
  | restrict-image-registries | Audit（长期） | 失败多为裸镜像名(隐式 docker.io，可信源)，Enforce 需全限定名、churn 大收益低 |
  | require-probes | Audit | 失败大头是 Job/CronJob(合理无 probe)+基础设施，Enforce 会误伤批处理 |

- **Audit→Enforce 流程**：读 `kubectl get polr -A` 确认某策略零（活动）违规 → 改该文件 rule 的 `failureAction:Enforce` → push。注意 `polr` 含 replicas=0 历史 ReplicaSet 与一次性 Job，数字虚高；Enforce 只作用新建 Pod。
- 系统 ns 由 Kyverno 默认 resourceFilters 排除（CNI/控制面绝不 gate）。ClusterPolicy 的服务端默认字段经 App `ignoreDifferences` 消除 OutOfSync。

### 5.3 LimitRange 资源护栏
- `manifests/namespace-guardrails/namespace-guardrails.yaml`（ArgoCD `namespace-guardrails` App）给轻量应用 ns（external-secrets/zitadel/argocd/vault/default）注入默认 `requests`(cpu25m/mem64Mi) + `limits.memory`(宽松 1Gi，避免 request>limit 拒绝；不设 cpu limit 避免节流）。personal-services 用自带的 `personal-services-limits.yaml`。
- 双重作用：① 节点保护（未声明资源的容器不再无界）；② LimitRanger 在 Kyverno 校验前注入默认值 → 新建 Pod 自动满足 require-requests-limits。**monitoring(重量级)/kube-system(系统) 刻意不加**，避免拒绝风险。

## 6. 供应链与漏洞扫描 (Supply chain / CVE) — Trivy Operator

- **扫描面**：镜像 CVE + 配置审计 + RBAC 评估 + **镜像内暴露密钥**（最高信号）。结果以 CR 落地（`vulnerabilityreports`/`configauditreports`/`exposedsecretreports`/`rbacassessmentreports`）。
- **热节点调优（homelab）**：`scanJobsConcurrentLimit:1`（串行，杜绝扫描器风暴；oracle 无热约束，用 2）+ `builtInTrivyServer`(ClientServer + `local-path` PVC 持久化漏洞 DB，避免反复重下；2026-07-11 随存储本地化迁移离开 NFS) + `severity:HIGH,CRITICAL` + `ignoreUnfixed` + 关 `clusterCompliance`（CIS 交给 kube-bench）。
- **oracle 侧差异（2026-08-03 新增）**：该集群没有 Prometheus Operator（`monitoring.coreos.com` CRD 为 0），
  故 `serviceMonitor.enabled=false`，指标由 otel-collector 直抓再 remote-write。
  ⚠️ 抓取目标必须写**容器端口 8080** 而非 Service 端口 80 —— chart 的 trivy-operator Service 是
  headless(`ClusterIP: None`)，DNS 直接返回 pod IP，端口映射不生效（实测 :80 refused / :8080 200）。
  且 values 需 `fullnameOverride: trivy-operator`，否则 ArgoCD 会用 Application 名当 release 名 → NXDOMAIN。
  上这份的动机：2026-08 的迁移把 ArgoCD/Loki/Tempo/Calibre 搬去 oracle，那些镜像原本脱离了扫描。
- **⚠️ `scanJobTTL` 决定的是扫描吞吐，不只是清理时间（2026-08-03 实测定性）**：Complete 状态的
  扫描 Job 在被 TTL 回收前**一直占着 `scanJobsConcurrentLimit` 的槽**，所以
  **吞吐上限 = limit ÷ TTL**。原先两集群都是 `TTL=1h` ⇒ homelab 1 个镜像/小时、
  oracle 2 个/小时；oracle 首次部署当天就此停摆在 7/46（无活动 Job、无报错、
  operator 日志 45 分钟不出一行）。已统一降到 **`5m`**（commit `9c760bf`），
  并发上限维持原值（散热约束由 `scanJobsConcurrentLimit` 独立保证，与 TTL 正交）。
  **别改回 1h。** 代价：失败 Job 也 5m 内回收，但扫描容器的报错原文会被
  trivy-operator 抄进自己的日志，排障不受影响。
  改这个值时注意两点：① env 来自 `configMapRef`，需 operator 重启才生效——chart 带
  `checksum/config` 注解，ArgoCD 同步 ConfigMap 时会自动滚动，不必手动 `rollout restart`；
  ② `ttlSecondsAfterFinished` 在 Job 创建时就写进 spec，**已存在的 Job 仍按旧 TTL 滞留**，
  要等它们自然回收后吞吐才真正提上来（改完别急着判断"没效果"）。
  ☠️ **这种"扫描覆盖不全"是静默的**——`TrivyImageCriticalVulnerabilities` 只数
  *现存报告*里的 Critical，`TrivyOperatorMetricsAbsent` 只在序列**整体**消失时才响，
  覆盖率塌到 15% 两头都不占，表现为 `trivy_image_vulnerabilities{cluster="…"}`
  恒为 0 的**假阴性**。体检方式见下（报告数 vs 工作负载数）。
- **⚠️ 改 `ignoreFile` 不会触发重扫（2026-08-05 实测）**：报告只在两种情况下重新生成
  —— ① 工作负载的 `resource-spec-hash` 变了（改镜像/改 pod spec）；
  ② `OPERATOR_SCANNER_REPORT_TTL`（**24h**）到期。报告上**没有** plugin-config 的哈希，
  所以新增一条 accepted-risk 豁免后，**镜像没变的那些工作负载会继续按旧报告计数最多 24 小时**，
  `TrivyImageCriticalVulnerabilities` 也就继续 firing —— 这不是豁免写错了。
  想立刻生效就强制重扫。**删报告只是第一步，必须跟一次 operator 重启**
  （2026-08-05 实测：删掉 6 份报告后只有 2 份被重建，另外 4 份十分钟内既没有
  扫描 Job 也没有任何报错 —— 删 report 不能可靠触发所属工作负载的 reconcile；
  重启后立刻排上队）：

  ```bash
  # ① 只删仍带 Critical 的报告，别全删（55 个负载 ÷ 并发 2 会排很久）
  kubectl get vulnerabilityreports -A -o json \
    | jq -r '.items[] | select((.report.summary.criticalCount // 0) > 0)
             | "\(.metadata.namespace) \(.metadata.name)"' \
    | while read -r ns n; do kubectl -n "$ns" delete vulnerabilityreport "$n"; done

  # ② 强制全量 reconcile（重启是安全的：报告是 CR，不随 pod 走）
  kubectl -n trivy-system rollout restart deploy/trivy-operator

  # ③ 必须回查报告真的回来了 —— 缺报告 = 计数为 0 的假阴性，和"已修好"长得一样
  kubectl get vulnerabilityreports -A --no-headers | wc -l
  ```

  ⚠️ **删了报告却没重建，比不删更危险**：告警只数现存报告，缺失的那几个
  按 0 计入，于是"漏扫"表现为"已清零"。删完务必按 ③ 核对数量。
  改 `ignoreFile` 后**不需要**重启 operator 才让豁免生效（实测：operator pod
  2d 未重启，删掉的报告重建后豁免已生效）—— 重启只是用来把漏掉的重扫排上队。

  排查豁免是否真的生效，别看告警看**报告本身**：`ignoreFile` 里已有的 ID 若仍出现在
  `vulnerabilityreports` 中，只有两种可能——报告是旧的（等重扫），或格式踩了
  `values/trivy-operator-oracle.yaml` 文件头记的那两个坑（必须 `.trivyignore.yaml`；
  不能用 `expired_at`）。
  ⚠️ `ignoreFile` 按 **CVE ID 全集群**生效，不能限定镜像：给 A 镜像写的豁免会连带
  掩盖 B 镜像上同 ID 的问题。所以每条 statement 要写清适用镜像，并注明
  "若在别处又出现说明镜像回退了"（现有条目已按此口径写）。
- **⚠️ 两类"扫不到"会静默变成 0（2026-08-05 oracle 实测，各有实例）**——都表现为
  **没有报告**，而告警只数现存报告，于是漏扫 == 已清零：
  1. **arm64-only 镜像扫不了**。扫描 Job 跑的是 `trivy image <ref>`，**不带 `--platform`**，
     trivy 远程解析默认 `linux/amd64`；镜像索引里没有 amd64 子项就直接 FATAL：
     `no child with platform linux/amd64 in index …`。本集群是 arm64 单节点，
     `ghcr.io/meirongdev/trends:main` 只出 arm64 → **从未被扫过**。
     多架构镜像（it-tools / squoosh 都是 amd64+arm64）不受影响，所以这个坑只咬自建的单架构镜像。
     chart 0.33.1 **没有**平台开关（`extraEnv` 只作用于 operator 自身，不进扫描 Job；
     trivy 插件配置里也没有 platform 键）→ 想修只能让镜像出多架构，
     或接受该镜像不被扫描。**自建 arm64 镜像时顺手加 amd64，扫描才有覆盖。**
  2. **Docker Hub 匿名拉取限流**。`TOOMANYREQUESTS: You have reached your unauthenticated
     pull rate limit` 会让扫描 FATAL（实测命中 browserless/chrome、stirlingtools/stirling-pdf、
     docker.redpanda.com/redpandadata/connect）。**强制批量重扫最容易触发**——删一批报告
     再重启 operator 会短时间打出几十次 manifest 请求，配额瞬间见底。
     限流是按小时恢复的，所以这类缺口会自愈；但"自愈前"的窗口里计数偏低，
     别在这个窗口下结论说"已清零"。
- **接入可观测**：ServiceMonitor（带 `release:kube-prometheus-stack`，仅 homelab）→ Prometheus 抓 `trivy_image_vulnerabilities` 等；告警 `manifests/monitoring/alerts/trivy-alerts.yaml`（critical CVE→warning、暴露密钥 High/Critical→**critical**、absent 元告警）经 Telegram；看板 Grafana `Security` 文件夹。
- **扫描覆盖率体检**（两个数字应接近，差得多 = 队列被堵或扫描在失败）：

  ```bash
  kubectl get vulnerabilityreports -A --no-headers | wc -l          # 已产出报告数
  kubectl get deploy,sts,ds,cronjob -A --no-headers \
    | grep -vE '^(kube-system|kube-public|kube-node-lease|trivy-system)' | wc -l   # 应扫工作负载数
  kubectl get jobs -n trivy-system                                  # 滞留的 Complete Job = 堵点
  ```

  ⚠️ **别按报告名 grep 判断"某负载有没有被扫"**：报告名超过 63 字符时 trivy-operator
  会把它压成纯哈希（实测 `replicaset-5c4986ccc7` / `statefulset-78579cd8ff` 分别是
  argocd 的 applicationset-controller 和 application-controller）—— 按名字 grep 会把
  这些误判成"没扫"。要认哪个负载就看 **label**。精确到容器级的缺口清单：

  ```bash
  kubectl get vulnerabilityreports -A -o json | jq -r '.items[] |
    "\(.metadata.namespace)|\(.metadata.labels."trivy-operator.resource.name")|\(.metadata.labels."trivy-operator.container.name")"' \
    | sort -u > /tmp/have.txt
  kubectl get pods -A -o json | jq -r '.items[]
    | select(.metadata.namespace|test("^(kube-system|kube-public|kube-node-lease|trivy-system)$")|not)
    | select(.status.phase=="Running") | .metadata.namespace as $ns
    | (.metadata.ownerReferences[0].name // .metadata.name) as $o
    | .spec.containers[] | "\($ns)|\($o)|\(.name)"' | sort -u > /tmp/want.txt
  comm -23 /tmp/want.txt /tmp/have.txt          # 真正没有报告的容器
  ```

  该比对对 CNPG 有一个已知假阳性：pod 的 ownerReference 是 Cluster（`zitadel-pg`），
  而报告 label 记的是实例名（`zitadel-pg-1`）—— 出现 `zitadel-pg` 时按实例名再核一次。
  查到缺口后**必须看扫描 Job 的报错原文**定因（上面那两类静默失败都只在日志里）：
  `kubectl -n trivy-system logs deploy/trivy-operator --since=30m | grep -i 'scan job container'`

## 7. CIS 合规与节点加固

- **kube-bench**：每周日 05:00 UTC CronJob，**k3s 基准**（`k3s-cis-*`，否则通用基准满屏假 FAIL），结果 stdout→Loki（按 `{namespace="kube-bench"}` 查）。专用 `kube-bench` ns 标 privileged（需 hostPID + host 挂载）。
- **节点加固**（`setup-k3s.yaml`）：`/etc/sysctl.d/31-k8s-protect-kernel.conf`（protect-kernel-defaults 所需 sysctl，先落盘持久化）+ config.yaml `protect-kernel-defaults:true`。**现网需维护窗口 `systemctl restart k3s` 才生效**。API 审计日志**刻意延后**（磁盘紧）。

## 8. 网络安全 (Network) — Cilium + Hubble

- **数据面**：双集群 Cilium（eBPF + VXLAN），具备 `CiliumNetworkPolicy` L3/L4/L7 能力；ClusterMesh 经 Tailscale 互联。
- **当前态：默认放行 + Hubble 可见性**。Hubble 已启用（relay 开），可 `hubble observe` 回答"谁在跟谁通信"——这是日后做默认拒绝的安全前置。
- **默认拒绝刻意延后**：见 §11。已有的 argocd chart 自带 NetworkPolicy 提供部分隔离。

## 8.5 运行时检测 (Runtime detection) — 按集群分别选型

eBPF 运行时威胁检测（容器内起 shell、读敏感文件、提权、异常外联）。**按集群硬件选型**：

- **homelab → Tetragon**（`values/tetragon.yaml`，ns `tetragon`，Helm App）。Cilium 原生、**内核态过滤**只上报命中事件 → 省 CPU，适配热笔记本。v1：默认进程 exec/exit 可见性 → `export-stdout` → 现有 OTel→Loki（按 pod=tetragon 查，可见容器内 shell/kubectl exec/异常进程）+ Prometheus 指标(ServiceMonitor 带 release 标签)。自定义 TracingPolicy（敏感文件/提权检测）+ 基于其指标的告警为后续调优。
- **oracle → Falco + Falcosidekick → Telegram**（`values/falco.yaml`，ns `falco`，Helm App 部署到 oracle 集群）。规则库开箱即用；oracle VM CPU 余量大。`driver: modern_ebpf`(CO-RE 无需内核模块)。**双出口**：① Falco JSON→stdout→OTel→Loki（always-on，零依赖）；② Falcosidekick→Telegram（原生 output，warning+，併入群 MatthewDaily「🚨 Homelab 告警」话题——2026-07 前曾经 Gotify 转发，已随其下线迁移，见 `decisions/alerting-telegram-migration.md`）。
  - **Telegram 推送前置（一次性）**：token 走 Vault `secret/homelab/telegram`（与 homelab Alertmanager 共用同一个 bot，跨集群读取）→ ESO(`cloud/oracle/manifests/falco/falcosidekick-secret.yaml`)生成 `falcosidekick-telegram` secret(key `TELEGRAM_TOKEN`)；chatid/messagethreadid 明文配在 `values/falco.yaml`。token 未配好不影响 Falco→Loki 检测，只是 falcosidekick 推送失败。
  - falco ns（含 PSA privileged 标签 + ESO secret）由 oracle-k3s kustomize App 拥有；Falco 工作负载由独立 `falco` Helm App 部署（`CreateNamespace=false`）。
  - **⚠️ falco 依赖 inotify**：oracle 节点必须 `fs.inotify.max_user_instances=8192`（Ubuntu 默认 128 会被占满，falco 启动即 `could not initialize inotify handler` CrashLoop——2026-07-12 发现时已崩 23 天/2000+ 次重启；sysctl 已固化于 `cloud/oracle/ansible/playbooks/setup-k3s.yaml`）。教训：期间 `KubePodCrashLooping`(warning) 一直在触发但淹没在噪音里——**长期 Progressing/慢性 warning 需要人定期扫一眼兜底**。

## 9. 安全可观测与告警

- **统一管道**（2026-07 起）：homelab 侧 Prometheus(metrics)/Loki(logs) → Alertmanager → 原生 `telegramConfigs`(无 bridge) → Telegram 群 MatthewDaily 的「🚨 Homelab 告警」话题。`severity:warning|critical` 路由，`info` 丢弃；**`Watchdog` 不丢弃**——由 `watchdog` AlertmanagerConfig 抢先路由到 oracle Uptime Kuma push monitor 作 dead-man's switch。旧 `alertmanager-gotify-bridge` 因 `concurrent map writes` 崩溃 bug + 上游无维护已下线。oracle 侧 Falco 走独立的 Falcosidekick 原生 Telegram output(§8.5)——两条链路各自直连 Telegram Bot API，同一个 bot/话题，但代码路径不同，互不依赖。Gotify 本体已随本次迁移彻底下线（Deployment/PVC/网关路由/DNS 全部移除），详见 `decisions/alerting-telegram-migration.md`。
- **新增 `PrometheusRule`/`ServiceMonitor` 必须带 `release:kube-prometheus-stack`** 否则 operator selector 忽略。
- **安全相关规则**：ESO 健康（`eso-alerts.yaml`）、Trivy 发现（`trivy-alerts.yaml`）。多集群靠 `cluster` 标签区分。
- **看板**：Grafana `Security` 文件夹 3 张——**Trivy 漏洞概览**（CVE/暴露密钥/配置审计，Prometheus）、**Kyverno 准入策略**（评估结果/Enforce 拦截/各策略 fail/webhook 延迟，Prometheus，Kyverno 各 controller ServiceMonitor）、**运行时与审计事件**（Falco 告警 + Tetragon 进程事件 + kube-bench CIS，Loki）。Hubble CLI 看网络流。
- **散在别处的可见性**：Kyverno 当前存量违规 `kubectl get polr -A`（counter 指标只适合看趋势/速率）；PSA violation 在 `kubectl get events`；所有 warning|critical 告警(homelab) → Telegram。

## 10. 威胁模型与覆盖矩阵

| 威胁 / 攻击面 | 缓解控制 | 覆盖 |
|--------------|----------|------|
| 外部漏洞利用 / 扫描 | Cloudflare WAF + 零暴露端口 + 限流 | ✅ |
| 凭据窃取 / 未授权访问 | ZITADEL OIDC（锁定注册）+ 各 app 认证 | ✅ |
| 密钥泄漏（静态） | Vault + ESO；镜像内密钥由 Trivy exposed-secret 扫描 | ✅ |
| 密钥静默陈旧 | ESO 健康告警 → Telegram | ✅ |
| 不安全 Pod（特权/逃逸） | PSA baseline（双集群） | ✅ |
| 镜像用 :latest（不可复现） | Kyverno disallow-latest-tag（digest-aware） | ✅ Enforce |
| 配置劣化（无 limits/probes/不可信仓库） | Kyverno（Audit）+ LimitRange 护栏（注入默认 requests/limits） | 🟡 Audit + 护栏 |
| 镜像已知 CVE | Trivy（HIGH/CRITICAL）→ Telegram + 看板 | ✅ |
| 节点/控制面配置不合规 | kube-bench 周巡检 + protect-kernel-defaults | 🟡 待重启 |
| 容器内运行时入侵（起 shell/异常外联/提权） | Tetragon(homelab,进程可见性→Loki) / Falco(oracle,规则→Loki+Telegram) | ✅ 已部署（v1 可见性；TracingPolicy/规则调优持续） |
| 东西向横向移动 | 网络默认拒绝 | ❌ 延后（仅 Hubble 可见性） |
| 数据丢失 | restic 双集群 CronJob（Vault raft / pg_dump / sqlite）→ 106 ZFS 仓库 + 恢复演练通过 | 🟡 本地单副本，离站备份未上线 |

## 11. 已知缺口与路线图

1. **运行时检测调优（Phase 2 已部署，见 §8.5）**：v1 已上 Tetragon(homelab,进程可见性)+Falco(oracle,规则，Telegram token 已配好)。后续：① Tetragon 写 TracingPolicy（敏感文件/提权/异常外联）+ 基于其指标的告警（Telegram）；② Falco 噪声规则按环境裁剪。
2. **网络默认拒绝（门控灰度）**：Hubble 基线流量 → Cilium 每端点 `PolicyAuditMode` 只记不拦 → 单无状态叶子 ns（personal-services/homepage）试点 CiliumNetworkPolicy（放行 DNS/Envoy/必要 egress）→ soak → 逐 ns 评估，**建议只对对外暴露 ns 做**。
3. **节点 API 审计日志**：延后（磁盘紧）；如开启用 Metadata 级策略 + 严格 maxsize/maxbackup，先确认磁盘余量。
4. **Kyverno Audit→Enforce**：逐条清理存量违规后提升；restrict-image-registries 最久保持 Audit。
5. **离站备份**：restic 仓库（Vault raft / pg_dump / sqlite，含恢复演练通过）目前仅 106 本地 ZFS 单副本，尚未同步到云端（OCI always-free / B2）。详见 docs/runbooks/backup-recovery.md 与 ROADMAP.md。

## 12. 运维入口

| 需求 | 入口 |
|------|------|
| 部署/验证/回滚（Phase 0+1） | [../runbooks/security-hardening.md](../runbooks/security-hardening.md) |
| 实施决策与权衡 | [../plans/security/2026-06-16-k3s-security-hardening.md](../plans/security/2026-06-16-k3s-security-hardening.md) |
| 身份/OIDC 接入细节 | [identity.md](identity.md) |
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
