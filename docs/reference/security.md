# K3s 集群安全架构 (Security Architecture)

> Last updated: 2026-10-28
> Status: 生效事实
> Scope: 双集群（homelab + oracle-k3s）的纵深防御模型，本文是 source of truth。
> 部署/验证/回滚步骤见 [../runbooks/security-hardening.md](../runbooks/security-hardening.md)；
> 实施决策与权衡见 [../plans/2026-06-16-k3s-security-hardening.md](../plans/2026-06-16-k3s-security-hardening.md)。

## 速览

- **11 层纵深防御**：WAF → OIDC → Vault+ESO → PSA → Kyverno → Trivy → CIS →
  节点加固 → 网络 → 运行时 → restic。
- **第 9 层（网络）只到"可见性"**：无自建 CiliumNetworkPolicy，集群级默认拒绝刻意延后。
- **硬约束**：热笔记本 fail-open + 控 CPU；GitOps 优先（PSA 标签 / Vault / ESO / argocd 例外）。
- 威胁覆盖矩阵见 § 10，已知缺口与路线图见 § 11。

## 0. 设计原则（硬约束驱动）

- **热笔记本约束**：homelab 控制面 `k8s-node` 是 Ryzen 5600H 笔记本（空闲 ~60–62°C、内存紧、重启需 `just homelab-recover`，见 [homelab-host-power-thermal.md](homelab-host-power-thermal.md)）；有了 worker `k8s-worker-106` 也仍以控制面为准。所有安全组件 **fail-open + 控 CPU**：不引入故障时会阻断调度的准入，周期/串行扫描优先于常驻高负载。
- **GitOps 优先**：例外只有两类，清单外 ns 的 PSA 标签用 `just`、Vault/ESO/argocd 用 Helm。
- **单用户威胁模型**：一个可信运维者、无敌对多租户，据此延后集群级网络默认拒绝（横向移动收益边际低、debug 成本高）。

## 1. 纵深防御总览

由外到内，每层独立生效：

| # | 层 | 组件 | 状态 | 配置位置 | 集群 |
|---|----|------|------|----------|------|
| 1 | 边缘 | Cloudflare WAF + Tunnel + 限流 | ✅ 生产 | `cloudflare/terraform/waf.tf` | 双（zone 级） |
| 2 | 身份 | ZITADEL OIDC + GitHub 联邦 | ✅ 生产 | `zitadel/`, 各 app values | oracle-k3s（IdP） |
| 3 | 密钥 | Vault + ESO + 健康告警 | ✅ 生产 | `k8s/helm/values/vault-*`, `eso-alerts.yaml` | 双 |
| 4 | 准入：Pod 基线 | Pod Security Admission | ✅ 生产 | `just harden-psa` / ns 清单 | 双 |
| 5 | 准入：策略即代码 | Kyverno（3 Audit + 1 Enforce，§5.2）| ✅ 生产 | `values/kyverno.yaml`, `manifests/kyverno-policies/` | homelab |
| 6 | 供应链/CVE | Trivy Operator（运行中镜像）| ✅ 生产 | 两集群各自的 `values/trivy-operator.yaml` | 双 |
| 7 | CIS 合规 | kube-bench（周巡检，钉 control-plane；worker node 级未覆盖，有意接受） | ✅ 生产 | `manifests/kube-bench/kube-bench.yaml` | homelab |
| 8 | 节点加固 | k3s `protect-kernel-defaults` + sysctl | ✅ 生效（两节点 k3s 都在配置之后重启过，2026-10-28 核） | `k8s/ansible/playbooks/setup-k3s.yaml` | homelab |
| 9 | 网络 | Cilium NetworkPolicy + Hubble 可见性 | 🟡 仅可见性 | Cilium（默认拒绝刻意延后） | 双 |
| 10 | 运行时检测 | Tetragon(homelab) / Falco+Falcosidekick(oracle) | ✅ 已实现 | `values/{tetragon,falco}.yaml` | 双（分别选型） |
| 11 | 备份/恢复 | restic（106 ZFS 加密仓库）| 🟡 Phase1（每夜备份 + 恢复演练通过；**离站副本待做**）| `runbooks/backup-recovery.md` | 双 |
| 12 | 安全可观测 | Alertmanager → Telegram（homelab）/ Falcosidekick → Telegram（oracle Falco） | ✅ 生产 | `kube-prometheus-stack.yaml`, 各 `*-alerts.yaml` | 双 |

---

## 2. 边缘安全 (Edge) — Cloudflare

- **应用流量零暴露**：外部流量只经 Tunnel 进来（cloudflared 出站连边缘），DNS 全是 proxied 的 `CNAME → <tunnel_id>.cfargotunnel.com`，无 A 记录指向节点公网 IP。链路见 [networking-ingress.md](networking-ingress.md)。
- ⚠️ **「零暴露」只指应用流量**。homelab 在 NAT 后无公网 IP；oracle 的 OCI Security List 现存 3 条入站：`22/tcp`（tailnet 全挂时唯一入口，密钥认证）· `41641/udp`（Tailscale 穿透，缺了全走 DERP）· `ICMP 3/4`（PMTU）。6443 不开公网（`tailscale0` 属 firewalld `trusted` zone，tailnet 访问不受影响）。依据在 `cloud/oracle/terraform/main.tf` 注释。
- **WAF**（zone 级，覆盖两条隧道全部子域；`cd cloudflare/terraform && just apply`）：自定义规则 4 条（WordPress/PHP 扫描 · 敏感文件 · 漏扫 UA · 非标方法），Free 额度 5、**剩 1 槽**。新敏感路径并进「敏感文件」，term 一律套 `lower()`（`contains` 区分大小写）；刻意不拦的见行内注释。限流 1 条（Free 上限，共用计数器）：认证端点（`/login`,`/oauth2`,`/api/login`,`/signin`,`/v1/auth`）+ `draw.meirong.dev` 的 `/socket.io/`（Excalidraw 公开协作中继），30 req/10s/IP+colo → 封 10s。Managed Ruleset / OWASP CRS / 泄漏凭据检测要 Pro。
- ☠️ **Free 档没有信誉/评分类防护**：`cf.threat_score` [恒为 0](https://developers.cloudflare.com/ruleset-engine/rules-language/fields/reference/cf.threat_score/)（基于它的规则已删），`cf.waf.score` 仅 Enterprise（Business 只有 `cf.waf.score.class`）。现存防护全是确定性规则 + Browser Integrity Check：评估 WAF 效果别算信誉类，空槽位别硬塞规则，Security Level 只剩 Under Attack 开关的作用（`medium` = 常态）。可疑访问判读见 [suspicious-traffic-investigation.md](../runbooks/suspicious-traffic-investigation.md)。
- **Zone settings**：SSL Full、TLS 1.2+、Always HTTPS、Security Level Medium、Browser Integrity Check、Email Obfuscation、Hotlink Protection、Opportunistic Encryption。**API Token**：Zone DNS / WAF / Settings Edit + Cloudflare Tunnel Edit。

## 3. 身份与访问 (Identity) — ZITADEL OIDC

- **单一 IdP** `auth.meirong.dev`（oracle-k3s），无共享入口层 SSO：每个服务要么公开、要么原生 ZITADEL OIDC（Grafana / Miniflux / ArgoCD，client 由 `zitadel/scripts/*.sh` 幂等下发，creds 经 Vault→ESO，本地账号保留为后备）、要么自带认证。
- **刻意公开无认证**：`pdf.meirong.dev`(BentoPDF，纯客户端 WASM，文件不出浏览器)、`draw.meirong.dev`(Excalidraw)。
- **GitHub 联邦锁定注册**：`isCreationAllowed/isAutoCreation=false` + `autoLinking=EMAIL`，GitHub 身份只能按已验证邮箱链接到既有用户。
- 部署形态与各 app 接入的唯一真相源是 [identity.md](identity.md)。

## 4. 密钥管理 (Secrets) — Vault + ESO

- **Vault 是所有 app 密钥的唯一真相源**，ESO 同步到 K8s Secret。路径约定：homelab `secret/homelab/<svc>`，oracle `secret/oracle-k3s/<svc>`。
- **静默陈旧防护**：`externalsecret`/`(cluster)secretstore` `Ready=False` 经 Telegram 告警（`manifests/monitoring/alerts/eso-alerts.yaml`），防 Vault 封印/token 过期后 app 静默用旧值。
- 本地 `.env` 仅用于 bootstrap token（gitignore）。
- ☠️ 密钥别进命令行：argv 会被 Tetragon 送进 Loki（§8.5）。
- **不留常驻明文 Vault 清单**：`vault_values.md` 一类 dump 按需生成、用完即删，`.gitignore` 的 `**/vault_values.md` 作护栏。陈旧 dump 比没有更糟（死路径与漏掉的活路径并存）。

## 5. 准入管控 (Admission)

### 5.1 Pod Security Admission（基线地板，永远在线）
- 内置准入，零运行时开销，Kyverno 宕了也生效。只在 Pod 创建/更新时评估、**不杀已运行 Pod**：翻标签当下总是「看着没事」，代价到下一次 Pod 重建才兑现。
- **下发按「ns 是谁建的」分两条路**：

  | ns 由谁创建 | 谁打标签 | 兜底 |
  |---|---|---|
  | 仓库清单（`*/namespace.yaml`） | ArgoCD | CI 的 H5：漏写等级直接失败 |
  | Helm chart / k3s 自建（`kube-system`、`external-secrets`、`cnpg-system`、`trivy-system`、`default`…） | `just harden-psa`（列表在 `k8s/helm/justfile`、`cloud/oracle/justfile`） | `just psa-check`：有 Pod 无标签 → 非零退出 |

  ☠️ 别给第二类补 Namespace 清单：等于把 ns 交给 ArgoCD prune（[2026-08-03 级联删除](../records/2026-08-03-namespace-prune-cascade.md)的成因）。代价是命令式标签不随 ns 重建复活，由 `psa-check` 兜底。⚠️ 一个 ns 只能有一个写者：清单管的 ns（如 `kube-bench`）不得再进 `psa_*` 列表。

- **等级矩阵**（最近一次对 live 核对：2026-08-20）：

  | enforce | namespace |
  |---------|-----------|
  | `baseline` | default, vault, personal-services, cloudflare, external-secrets, kyverno, external-dns, opencost, media, litellm, databases（homelab；官方 postgres 镜像先以 root 建/chown 数据目录再 gosu 降权，restricted 会挡住）；argocd, cloudflare, external-dns, homepage, personal-services, rss-system, opencost, default, external-secrets, cnpg-system（oracle） |
  | `restricted` | jobs-sg（homelab）；databases（oracle，CNPG `apps-pg`）· zitadel（oracle，SSO + 身份库 zitadel-pg） |
  | `privileged`（显式豁免, warn/audit 仍记 baseline） | kube-system, monitoring, trivy-system, tetragon, kube-bench, backup（homelab）；kube-system, monitoring, trivy-system, falco, backup（oracle） |

  只剩 `cilium-secrets` / `kube-node-lease` / `kube-public` 无标签：它们不跑 Pod，`psa-check` 据此放行（判据是「有没有 Pod」，不维护会漂的白名单）。

- ⚠️ `trivy-system` 两集群都是 `privileged`，别照 dry-run 的干净结果降档：node-collector 是挂 `/var/lib/etcd` 等 hostPath 的周期 Job，dry-run 时不在场；降档的症状是合规扫描静默停更。
- ⚠️ `zitadel-pg` 在 `zitadel` ns（`cloud/oracle/manifests/zitadel/zitadel-pg-cluster.yaml`），不在 `databases`；`databases` 只承载 `apps-pg`。
- ☠️ `zitadel` ns 的 restricted 依赖 [`zitadel.yaml`](../../cloud/oracle/manifests/zitadel/zitadel.yaml) `valuesContent` 里的 `securityContext`/`podSecurityContext`（chart 默认缺 `allowPrivilegeEscalation:false` / `capabilities.drop[ALL]` / `seccompProfile`）。删了运行中 Pod 无异样，下次 helm upgrade 时 `zitadel-init`/`zitadel-setup` Job 被拒，升级卡在 DB 迁移中途。收紧任何 ns 都先补 securityContext 并复核，再翻 enforce（H5 由来见 [manifest-safety-checks.md](manifest-safety-checks.md)）。
- **收紧前先用 dry-run 问准入自己**，PSA 会列出现存违规 Pod；它只看当下存在的 Pod，周期 Job 不在场时干净不等于安全：

  ```bash
  kubectl --context oracle-k3s label ns <ns> \
      pod-security.kubernetes.io/enforce=restricted --overwrite --dry-run=server
  ```
- 不做全局 `restricted`（monitoring 的 grafana 跑 root），按 ns 逐个上。

### 5.2 Kyverno（策略即代码，homelab）
- 拆分 controller 各 `replicas:1`、`backgroundScanInterval:24h`、**所有策略 `failurePolicy:Ignore`（fail-open）**：fail-closed 时 Kyverno 起不来全集群就无法调度，与恢复路径冲突。
- **4 条 ClusterPolicy**（per-rule `failureAction`）：

  | 策略 | Action | 说明 |
  |------|--------|------|
  | disallow-latest-tag | **Enforce** | digest-aware（只拦 `:latest`）；运行中工作负载全 digest 固定，零阻断 |
  | require-requests-limits | Audit | 失败主要在 monitoring/kube-system；应用 ns 经 LimitRange(§5.3) 达标后再按 ns 考虑 Enforce |
  | restrict-image-registries | Audit（长期） | 失败多为裸镜像名（隐式 docker.io），Enforce 需全限定名，churn 大收益低 |
  | require-probes | Audit | 失败大头是 Job/CronJob（合理无 probe）+ 基础设施，Enforce 会误伤批处理 |

- **Audit→Enforce**：`kubectl get polr -A` 确认零（活动）违规 → 改该 rule 的 `failureAction:Enforce` → push。`polr` 含 0 副本的历史 ReplicaSet 与一次性 Job，数字虚高；Enforce 只作用于新建 Pod。
- 系统 ns 由默认 resourceFilters 排除（CNI/控制面绝不 gate）；ClusterPolicy 的服务端默认字段经 App `ignoreDifferences` 消除 OutOfSync。

### 5.3 LimitRange 资源护栏
- `manifests/namespace-guardrails/namespace-guardrails.yaml`（App `namespace-guardrails`）给轻量应用 ns（external-secrets/vault/default；zitadel、argocd 已迁去 oracle）注入默认 `requests`(cpu25m/mem64Mi) + `limits.memory` 1Gi（宽松，避免 request>limit 被拒；不设 cpu limit，避免节流）。personal-services 用自带的 `personal-services-limits.yaml`。
- 作用：未声明资源的容器不再无界；LimitRanger 先于 Kyverno 注入默认值，新 Pod 自动满足 require-requests-limits。monitoring/kube-system 刻意不加，避免拒绝风险。

## 6. 供应链与漏洞扫描 (Supply chain / CVE) — Trivy Operator

- **扫描面**：运行中镜像的 CVE（`HIGH,CRITICAL` + `ignoreUnfixed`）+ 配置审计 + RBAC 评估 + 镜像内暴露密钥（最高信号），结果落为 CR；告警 `trivy-alerts.yaml` → Telegram，看板在 Grafana `Security` 文件夹。homelab 扫描串行（`scanJobsConcurrentLimit:1`，热约束；oracle 2），CIS 交给 kube-bench。
- ☠️ **失败几乎全静默**：告警只数现存报告，缺报告按 0 计，「漏扫」与「已清零」外观一致。**判据永远是报告数 vs 工作负载数**，不是告警绿不绿。
- 配置、各类静默失败的机制、强制重扫与覆盖率体检见 [trivy-cve-ops.md](trivy-cve-ops.md)（唯一真相源）。

## 7. CIS 合规与节点加固

- **kube-bench**：每周日 05:00 UTC CronJob，k3s 基准（`k3s-cis-*`，通用基准会满屏假 FAIL），结果 stdout→Loki（`{k8s_namespace_name="kube-bench"}`，标签是 OTel 风格，写 `namespace=` 查不到）。专用 ns 标 privileged（hostPID + host 挂载）。
  - ⚠️ 必须钉 control-plane（`nodeSelector: node-role.kubernetes.io/control-plane`）：控制面检查项只在控制面节点上有意义，排到 `k8s-worker-106` 会「看起来通过」而实际没审控制面。
  - 残余缺口（有意接受）：worker 的 node 级检查项（kubelet 文件权限等）无覆盖。要补就改 DaemonSet 式逐节点审计，或给 worker 加一个 `--targets node` 的第二 CronJob。
- **节点加固**（`setup-k3s.yaml`）：先落盘 `/etc/sysctl.d/31-k8s-protect-kernel.conf`，再在 config.yaml 开 `protect-kernel-defaults:true`。**现网需维护窗口 `systemctl restart k3s` 才生效**。API 审计日志刻意延后（磁盘紧）。

## 8. 网络安全 (Network) — Cilium + Hubble

- **数据面**：双集群 Cilium（eBPF + VXLAN），具备 `CiliumNetworkPolicy` L3/L4/L7 能力；ClusterMesh 经 Tailscale 互联。
- **当前态：默认放行 + Hubble 可见性**（relay 开，`hubble observe` 回答「谁在跟谁通信」，是日后默认拒绝的前置）。默认拒绝刻意延后（§11）；argocd chart 自带 4 条 NetworkPolicy 提供部分隔离。
- **唯一自建的网络管控**（oracle）：`readlist-snapshot-no-egress` / `readlist-score-no-egress`，标准 `networking.k8s.io/v1` NetworkPolicy（Cilium 照常执行，不需要 CNP），`egress: []` 即全拒（含 DNS）。按数据敏感度切分：能读 calibre 书库与 `app.db`（含密码 hash/OIDC 凭据）的 snapshot/score 零出口，能出网的 ingest 挂不到 calibre 卷。可复用到其它碰敏感卷的 Job，但**只覆盖这两个短命 Job**，不代表有 ns 级或集群级默认拒绝。

## 8.5 运行时检测 (Runtime detection) — 按集群分别选型

eBPF 运行时威胁检测（容器内起 shell、读敏感文件、提权、异常外联），按集群硬件选型：

- **homelab → Tetragon**（`values/tetragon.yaml`，ns `tetragon`，Helm App）。Cilium 原生，内核态过滤只上报命中事件，省 CPU。v1 = 默认进程 exec/exit 可见性 → `export-stdout` → OTel → Loki（`{k8s_namespace_name="tetragon"}`）+ Prometheus 指标（ServiceMonitor 带 release 标签）。TracingPolicy 与基于其指标的告警未做（§11 第 1 条）。
  - ☠️ **进程事件带完整 argv，命令行里的密钥会进 Loki**。密钥改用 env，或 curl 的 `--variable %VAR` + `--expand-*`（curl ≥ 8.3，命令行只剩 `{{VAR}}`）。exit 事件也带 argv，Tetragon 重启时还会给存量进程补发 exec 事件（`flags=procFS`），所以长期运行的进程同样会漏。
  - `redactionFilters` 兜底 6 条：bot token / `-u` 口令 / Bearer / URL 里的 `user:pass@` / `-token`、`--token` 的参数值 / `…Token:` 请求头的值。兜底不是正解：带空格且加引号的口令只能打掉一半。
  - oracle 没有 Tetragon，argv 只在 `/proc` 可见、不进 Loki，写法同样照改。泄露经过与未轮换项见 [records/2026-10-24](../records/2026-10-24-intrusion-sweep-argv-secrets-in-loki.md)。
- **oracle → Falco + Falcosidekick**（`cloud/oracle/values/falco.yaml`，ns `falco`，Helm App）。规则库开箱即用，oracle CPU 余量大；`driver: modern_ebpf`（CO-RE，无需内核模块）。**双出口**：① JSON → stdout → OTel → Loki（always-on，零依赖）；② Falcosidekick 原生 Telegram output（warning+，与 homelab 告警同一 bot/话题）。
  - bot token：Vault `secret/homelab/telegram`（与 Alertmanager 共用，跨集群读）→ ESO `cloud/oracle/manifests/falco/falcosidekick-secret.yaml` → secret `falcosidekick-telegram`（key `TELEGRAM_TOKEN`）；chatid/messagethreadid 明文在 `falco.yaml`。缺 token 只影响推送。falco ns（PSA 标签 + ESO secret）归 oracle-k3s kustomize App，工作负载归独立的 `falco` Helm App（`CreateNamespace=false`）。
  - ⚠️ **规则误报会吃掉整条通道，还会冒充心跳**。已知一条：宿主 systemd 拉起带 `User=` 的单元时读 `/etc/shadow`、`/etc/pam.d/*`，触发 `Read sensitive file untrusted`；`systemd-executor` 的 comm 是纯数字，`proc.name` 白名单接不住，只能按 `proc.exepath` 排除（override 在 `falco.yaml`）。
  - **自身健康告警 5 条**：otel 抓 `falco`(falco-metrics:8765) 与 `falcosidekick`(:2801) → homelab Prometheus，规则 `falco-alerts.yaml`（见 [observability-alerting-slo.md](observability-alerting-slo.md)）。
  - ⚠️ **依赖 inotify**：oracle 节点必须 `fs.inotify.max_user_instances=8192`（Ubuntu 默认 128 会被占满，falco 启动即 `could not initialize inotify handler` CrashLoop），已固化在 `cloud/oracle/ansible/playbooks/setup-k3s.yaml`。慢性 `KubePodCrashLooping` warning 易被噪音淹没，要人定期扫一眼。

## 9. 安全可观测与告警

- **告警链路**（Alertmanager → Telegram、`Watchdog` 死人开关）的唯一真相源是 [observability-alerting-slo.md](observability-alerting-slo.md)；⚠️ 死人开关有已证实的失明盲区（[dead-mans-switch.md](dead-mans-switch.md)）。oracle Falco 走 Falcosidekick 直推（§8.5），与 Alertmanager 代码路径独立、互不依赖。Gotify 与旧 bridge 已退役（[决策](../decisions/alerting-telegram-migration.md)）。
- **新增 `PrometheusRule`/`ServiceMonitor` 必须带 `release:kube-prometheus-stack`**，否则 operator selector 忽略。
- **安全相关规则**：`eso-alerts.yaml`、`trivy-alerts.yaml`、`falco-alerts.yaml`，多集群靠 `cluster` 标签区分。
- **看板**：Grafana `Security` 文件夹 3 张：Trivy 漏洞概览（Prometheus）、Kyverno 准入策略（Prometheus，各 controller ServiceMonitor）、运行时与审计事件（Falco + Tetragon + kube-bench，Loki）。网络流用 Hubble CLI。
- **别处的可见性**：Kyverno 存量违规看 `kubectl get polr -A`（counter 指标只适合看趋势）；PSA violation 在 `kubectl get events`。

## 10. 威胁模型与覆盖矩阵

| 威胁 / 攻击面 | 缓解控制 | 覆盖 |
|--------------|----------|------|
| 外部漏洞利用 / 扫描 | WAF + 应用流量零暴露 + 限流；oracle 节点公网入站只剩 3 条（§2） | ✅ |
| 凭据窃取 / 未授权访问 | ZITADEL OIDC（锁定注册）+ 各 app 认证 | ✅ |
| 密钥泄漏（静态） | Vault + ESO；Trivy exposed-secret 扫镜像；gitleaks 扫公开仓库（本地 `just check`/pre-push + CI `secret-scan.yml` 扫全历史） | ✅ |
| 密钥静默陈旧 | ESO 健康告警 → Telegram | ✅ |
| 不安全 Pod（特权/逃逸） | PSA baseline（双集群） | ✅ |
| 镜像用 :latest | Kyverno disallow-latest-tag（digest-aware） | ✅ Enforce |
| 配置劣化（无 limits/probes/不可信仓库） | Kyverno Audit + LimitRange 护栏 | 🟡 Audit + 护栏 |
| 镜像已知 CVE | Trivy（HIGH/CRITICAL）→ Telegram + 看板 | ✅ |
| 节点/控制面配置不合规 | kube-bench 周巡检 + protect-kernel-defaults | ✅ |
| 容器内运行时入侵 | Tetragon（homelab，进程可见性→Loki）/ Falco（oracle，规则→Loki+Telegram） | ✅ v1 可见性，调优持续 |
| 东西向横向移动 | 网络默认拒绝 | ❌ 延后（仅 Hubble 可见性） |
| 数据丢失 | restic 双集群 CronJob（Vault raft / pg_dump / sqlite）→ 106 ZFS + 恢复演练通过 | 🟡 本地单副本，无离站 |

## 11. 已知缺口与路线图

1. **运行时检测调优**（v1 已部署，§8.5）：① Tetragon TracingPolicy（敏感文件/提权/异常外联）+ 基于其指标的 Telegram 告警；② Falco 噪声规则按环境裁剪。
2. **网络默认拒绝（门控灰度）**：Hubble 基线流量 → 每端点 `PolicyAuditMode` 只记不拦 → 单个无状态叶子 ns（personal-services/homepage）试点 CiliumNetworkPolicy（放行 DNS/Envoy/必要 egress）→ soak → 逐 ns 评估，**建议只对对外暴露 ns 做**。
3. **节点 API 审计日志**：延后（磁盘紧）；如开启用 Metadata 级策略 + 严格 maxsize/maxbackup，先确认磁盘余量。
4. **Kyverno Audit→Enforce**：逐条清理存量违规后提升；restrict-image-registries 最久保持 Audit。
5. **离站备份**：restic 仓库只有 106 本地 ZFS 单副本，未同步到云端（OCI always-free / B2）。见 [backup-recovery.md](../runbooks/backup-recovery.md)、[ROADMAP.md](../ROADMAP.md)。
6. **oracle 节点 OS 层防火墙口子过多**（未处理）：firewalld `public` zone 开着 `10250 / 2380 / 4240 / 4244 / 32379 / 16443 / 25000 / 19001 / 12379 / 10248-10259 / 7800 / 1338 / …`，多为早期 CNI（`cali+`、`flannel.1`、`cni0` 仍挂在 `trusted` zone）与 microk8s 试验残留，只靠 OCI Security List 一层挡。收口前逐端口确认归属：`enp0s3` 也在 `public` zone，误删可能切断节点到 API 的路径；`firewall-cmd --reload` 会冲掉 Cilium iptables（[records/2026-10-01](../records/2026-10-01-oracle-firewalld-flushes-cilium-iptables.md)）。在那之前**别往 Security List 加任何 `0.0.0.0/0` 规则**。背后真在监听的 3 个手工遗留（Dante SOCKS `:10080`、WireGuard `wg0 :51420`、root 的 node_exporter `:19898`）已停用，文件在节点 `/root/decommissioned-2026-10-24/`（0700）（[records/2026-10-24](../records/2026-10-24-intrusion-sweep-argv-secrets-in-loki.md)）。
7. **Nakama 管理控制台裸挂公网**（有意接受）：`nakama-console.meirong.dev` → console(7351)，能看/删账号、改任意存储、调任意 RPC，只有 Nakama 自带口令（无 ZITADEL / oauth2-proxy / Cloudflare Access），是公网可达却不过第 2 层身份的管理面之一（另一个是 Timeslot `/admin/`，见第 10 条；Grafana/ArgoCD 在 OIDC 后面，Vault 用自带认证）。缓解：口令 32 字节随机（Vault `secret/homelab/nakama` → `console_password`），6 个带不安全默认值的 key 全已换掉。⚠️ 收紧要在 HTTPRoute（`k8s/helm/manifests/gateway/route-nakama-console.yaml`）前加 oauth2-proxy 或 Cloudflare Access，改口令不减暴露面。
8. **git 历史里的旧对象**：公网 IP 与两个已失效的 ZITADEL 凭据已从全历史抹除并 force-push，但 GitHub 上重写前的悬空对象**仍可按 commit SHA 访问**，直到向 GitHub Support 申请 GC。替代手段是轮换 OCI 公网 IP，让旧值失去意义。
9. **公网集群上的 ArgoCD 持有 homelab 的 cluster-admin**（有意接受）：控制面在暴露面最大的 oracle-k3s，经 ESO 从 Vault 拿 homelab 的 `argocd-manager` 凭据，ArgoCD 被攻破 = 两个集群一起丢。AppProject 按集群拆分（[决策](../decisions/argocd-project-per-cluster.md)）只收窄「误投」，不收窄凭据；真收窄要给 homelab 侧 SA 降权到实际需要的资源类型，另评。现有缓解：ArgoCD 在 ZITADEL OIDC 之后、token 在 Vault、oracle 节点有 firewalld。
10. **Timeslot 管理面只有 Basic Auth**：`slot.meirong.dev/admin/` 无 OIDC（[app-native-oidc-sso](../decisions/app-native-oidc-sso.md) 的已知代价），口令是 Vault `secret/oracle-k3s/timeslot` 的 32 位随机值，经 ESO 下发（原为公开 chart 默认值，2026-09-03 已修，helm 遗留的 `timeslot-secrets` 已删）。☠️ 别用 `--set x=$(vault kv get …)` 给 helm 喂密钥：路径不存在时 shell 给空串，helm 照样成功、chart 用默认值兜底，零报错；这类配置只能读一次线上值来确认生效。

## 12. 运维入口

| 需求 | 入口 |
|------|------|
| 部署/验证/回滚 | [../runbooks/security-hardening.md](../runbooks/security-hardening.md) |
| 身份/OIDC 接入 | [identity.md](identity.md) |
| 备份恢复 | [../runbooks/backup-recovery.md](../runbooks/backup-recovery.md) |
| 重启后恢复 | `cd k8s/helm && just homelab-recover` |

### 常用核查命令（在 `k8s/helm` 下执行，context: `k3s-homelab`）
```bash
just psa-status                                            # PSA 标签现状（仅 homelab）
just psa-check                                             # PSA 漂移哨兵：有 Pod 却无标签 → 非零退出
cd ../../cloud/oracle && just psa-status && just psa-check # oracle 侧同两条（各自的 ctx 与列表）
kubectl get cpol                                           # Kyverno 策略
kubectl get polr -A                                        # Kyverno Audit 违规
kubectl get vulnerabilityreports,exposedsecretreports -A   # Trivy 发现
kubectl create job --from=cronjob/kube-bench kb-once -n kube-bench   # 手动跑 CIS
hubble observe --namespace <ns>                            # 网络流可见性
```
