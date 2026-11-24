# K3s 集群安全架构 (Security Architecture)

> Last updated: 2026-11-25
> Status: 生效事实
> Scope: 双集群（homelab + oracle-k3s）的纵深防御模型，本文是 source of truth。
> 部署/验证/回滚步骤见 [../runbooks/security-hardening.md](../runbooks/security-hardening.md)；

## 速览

- **11 层纵深防御**：WAF → OIDC → Vault+ESO → PSA → Kyverno → Trivy → CIS →
  节点加固 → 网络 → 运行时 → restic。
- **第 9 层（网络）只到"可见性"**：自建的 Cilium 策略只有 oracle 一条拦 IMDS 的 CCNP（§8），集群级默认拒绝刻意延后。
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
| 5 | 准入：策略即代码 | Kyverno（2 Audit + 2 Enforce，§5.2）| ✅ 生产 | `values/kyverno.yaml`, `manifests/kyverno-policies/` | homelab（oracle 无引擎，§11） |
| 6 | 供应链/CVE | Trivy Operator（运行中镜像）+ Renovate（镜像 digest/版本 PR，🚧 待配 token）| ✅ 生产 | 两集群各自的 `values/trivy-operator.yaml` · `.github/renovate.json5` | 双 |
| 7 | CIS 合规 | kube-bench（周巡检，钉 control-plane；worker node 级未覆盖，有意接受） | ✅ 生产 | `manifests/kube-bench/kube-bench.yaml` | homelab |
| 8 | 节点加固 | k3s `protect-kernel-defaults` + sysctl | ✅ 生效（两节点 k3s 都在配置之后重启过，2026-10-28 核） | `k8s/ansible/playbooks/setup-k3s.yaml` | homelab |
| 9 | 网络 | Cilium NetworkPolicy + Hubble 可见性 | 🟡 仅可见性 | Cilium（默认拒绝刻意延后） | 双 |
| 10 | 运行时检测 | Tetragon（两集群统一，2026-11-24 起；Falco 退役） | ✅ 已实现 | `security/tetragon/`（共用策略 + values）、各集群 `values/tetragon.yaml` | 双 |
| 11 | 备份/恢复 | restic（106 ZFS 加密仓库）| 🟡 Phase1（每夜备份 + 恢复演练通过；**离站副本待做**）| `runbooks/backup-recovery.md` | 双 |
| 12 | 安全可观测 | Alertmanager → Telegram（运行时检测经 Loki ruler 进同一个 Alertmanager） | ✅ 生产 | `kube-prometheus-stack.yaml`, 各 `*-alerts.yaml`, `loki-rules.yaml` | 双 |

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
- **Terraform state 是 Vault 之外另一处成规模的明文密钥**（两台 VM 的 cloud-init 用户密码、Tailscale 预授权 key、Aiven 服务的连接信息与密码；Cloudflare/Oracle 那三个 root 没有）：
  放在 R2 私有桶 `homelab-tfstate`，token 只授权这一个桶，☠️ 不与公开仓库 home-stack 的 CI 共用桶；
  执行机本地另有改动前快照 `.tfstate-snapshots/`（0600、gitignored）→ [terraform-state.md](terraform-state.md)。
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

- **等级矩阵**（最近一次对 live 核对：2026-11-18，两集群逐 ns 全量比对，与下表一致）：

  | enforce | namespace |
  |---------|-----------|
  | `baseline` | default, vault, personal-services, cloudflare, external-secrets, kyverno, external-dns, opencost, media, litellm, databases（homelab；官方 postgres 镜像先以 root 建/chown 数据目录再 gosu 降权，restricted 会挡住）；argocd, cloudflare, external-dns, homepage, personal-services, rss-system, opencost, default, external-secrets, cnpg-system（oracle） |
  | `restricted` | jobs-sg（homelab）；databases（oracle，CNPG `apps-pg`）· zitadel（oracle，SSO + 身份库 zitadel-pg） |
  | `privileged`（显式豁免, warn/audit 仍记 baseline） | kube-system, monitoring, trivy-system, tetragon, kube-bench, backup（homelab）；kube-system, monitoring, trivy-system, tetragon, backup（oracle） |

  只剩 `cilium-secrets` / `kube-node-lease` / `kube-public` 无标签：它们不跑 Pod，`psa-check` 据此放行（判据是「有没有 Pod」，不维护会漂的白名单）。
  一处不对称值得记着：oracle 的 `argocd` / `opencost` 是 `enforce=baseline` 而 `warn=restricted`（比 enforce 高一档的预演，warn 只记事件不阻断），对账时别当成标签写错。

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
- ☠️ 代价要说全：admission-controller 单副本、无反亲和、`priorityClassName:bulk`（内存压力下主动可驱逐），叠加 `failurePolicy:Ignore` 后，**`validationActions:[Deny]` 的实际语义是「该 controller 存活期间强制」**——重启/升级/被驱逐的窗口里新建 Pod 一律放行，且没有任何「这段时间没校验」的信号。机制级地板只有 PSA（§5.1）。
- **4 条 ValidatingPolicy**（`policies.kyverno.io/v1`，CEL；2026-11-19 由 legacy ClusterPolicy 迁入；最近对 live 核对：2026-11-19）：

  | 策略 | Action | 说明 |
  |------|--------|------|
  | disallow-latest-tag | **Deny** | digest-aware（只拦 `:latest`）；运行中工作负载零 `:latest`，零阻断 |
  | require-requests-limits | **Deny**（2026-11-18 提升） | 提升依据见下条方法论：11 条违规**全在 kube-system**，而它整 ns 被排除 → 受管控 ns 违规为 0，提升当下零新增阻断。⚠️ 此后 `cloudflare`/`databases`/`litellm`/`opencost`（无 LimitRange，§5.3）里任何不声明 resources 的 Pod 都会被拒 |
  | restrict-image-registries | Audit（长期） | 实测 91 条违规里**没有一个非可信来源**：11 个唯一镜像串只是省略了 `docker.io/` 前缀（隐式 docker.io，本就在白名单内，其中 10 个还是 digest 固定的），另两个是白名单确实漏了 `reg.kyverno.io`（Kyverno 官方源，只在 kyverno ns，不受准入管控，只污染后台报告）与 `mirror.gcr.io`。即它校验的是镜像串写法而非来源可信度，故长期保持 Audit；真正的供应链缺口在别处——digest 固定率不足一半（2026-11-18 业务容器 35/93），而 `mirror.gcr.io` 正是「无认证 Hub 透明镜像 + 不固定 digest」两个弱条件叠加。要收紧应新增一条要求 digest 固定的规则，而不是放宽本条 |
  | require-probes | Audit | 失败大头是 Job/CronJob（合理无 probe）+ 基础设施，Enforce 会误伤批处理 |

- **Audit→Deny 的分母是「本 webhook 真正 gate 的 ns」，不是 `polr` 原始计数**：原始计数同时混入了被排除的 `kube-system`/`kyverno`、0 副本历史 ReplicaSet 与一次性 Job，直接看既虚高又可能指向错误的 ns。正确做法是按规则聚合后剔除非 gate ns。现值（2026-11-18）：`registries` 91（受管控 68）、`readiness-probe` 18（受管控 13）、`requests-limits` 11（受管控 **0**）、`latest-tag` 0。Deny 只作用于新建 Pod。2026-11-19 迁 CEL 后 `require-requests-limits` 的 namespaceSelector 连后台扫描一起排除 kube-system，报告里不再有那 11 条。
- ⚠️ **豁免通道当前是关的**：admission-controller 带 `--enablePolicyException=false`，而 PolicyException 的 CRD（`kyverno.io/v2` 与 `policies.kyverno.io/v1`）都 served —— 今天创建例外对象会被静默收下、不生效。现有 2 条 Deny 都零违规所以不挡路，但要给改不动的上游 chart（jellyfin/navidrome 这类）提 Deny，得先实测例外 API 真的生效、在 chart 里怎么打开（v1.20 起 legacy 的 `kyverno.io` PolicyException 随 legacy 执行一起移除，只有 `policies.kyverno.io/v1` 那套有意义）。
- 系统 ns（CNI/控制面绝不 gate）：准入侧由 configmap 的 webhook namespaceSelector 排除 kube-system/kyverno，两条 Deny 策略另在自己的 `namespaceSelector` 里显式写了 kube-system/kube-public/kube-node-lease/kyverno，这样后台扫描也一致。ValidatingPolicy 不回填服务端默认字段，App 不再需要 `ignoreDifferences`。
- ✅ **legacy `kyverno.io` 策略类型已清零**（2026-11-19）：Kyverno v1.20 源码里已删掉 legacy 准入/后台/报告执行路径，且 chart 3.10 在集群里还有 legacy 策略时拒绝升级，所以升级前必须迁完。迁移要点（语义对应表在各策略文件头注释里）：① `objectSelector` 只在 webhook 层生效，**后台扫描不认**，要排除某类对象必须再写 `matchConditions`（`require-probes` 排除 Job Pod 就栽过：并跑对比时新版多出 25 个 CronJob Pod 的恒定误报）；② 迁移用**并跑 + 按资源逐条对比两个 source 的 PolicyReport**（`source=kyverno` vs `KyvernoValidatingPolicy`），不看 READY；③ 新写策略一律 `policies.kyverno.io/v1`，别再加 ClusterPolicy。
- 🚧 **oracle-k3s 没有策略引擎**：实测那边只有 CNPG/ESO 的 CRD schema 校验 webhook + PSA，`:latest`、无 requests、任意 registry 装进 oracle 不留任何记录。而它承载 GitOps 控制面 + ZITADEL + 生产 PG。不值得为它再跑 4 个 controller，候选做法是把 `disallow-latest-tag` 用原生 ValidatingAdmissionPolicy（CEL，v1.35 已 GA）单条装过去——零常驻成本，见 §11。

### 5.3 资源护栏：LimitRange + ResourceQuota
- **LimitRange**：`manifests/namespace-guardrails/namespace-guardrails.yaml`（App `namespace-guardrails`）给轻量应用 ns（external-secrets/vault/default；zitadel、argocd 已迁去 oracle）注入默认 `requests`(cpu25m/mem64Mi) + `limits.memory` 1Gi（宽松，避免 request>limit 被拒；不设 cpu limit，避免节流）。jobs-sg/media/personal-services 用各自清单里的 LimitRange。
- 作用：未声明资源的容器不再无界；LimitRanger 先于 Kyverno 注入默认值，新 Pod 自动满足 require-requests-limits。monitoring/kube-system 刻意不加，避免拒绝风险。
- ⚠️ **覆盖是按 ns 逐个铺的，不是全集群**：实测（2026-11-18）有 LimitRange 的只有 default/external-secrets/vault（guardrails）+ jobs-sg/media/personal-services（自带）6 个。`cloudflare`、`databases`、`litellm`、`opencost` 没有——那 4 个 ns 的 requests/limits 全靠清单自己写，由 §5.2 的 Enforce 拦住。新 ns 要不要加，先看这张覆盖表。
- **ResourceQuota 是另一条独立的线**，只限**对象数量**、不限 cpu/mem，别和 LimitRange 混为一谈：`jobs-sg-quota`（`count/jobs.batch` 现 9/限 25、`pods` 1/12）、`media-object-caps`（pods 3/15）、`personal-services-object-caps`（jobs 0/15、pods 7/30），清单与各自的 LimitRange 同文件（`k8s/helm/manifests/{jobs-sg,media,personal-services}/`）。
- 它防的是**节点级稀缺资源**：kubelet 的 pod 上限是硬天花板，一个失控的 CrashLoop Job 刷出几十个 Pod 就能把整节点填满，而 LimitRange 对「数量」完全无感——这正是当初驱逐事故的第二个成因面。

## 6. 供应链与漏洞扫描 (Supply chain / CVE) — Trivy Operator

- **扫描面**：运行中镜像的 CVE（`HIGH,CRITICAL` + `ignoreUnfixed`）+ 配置审计 + RBAC 评估 + 镜像内暴露密钥（最高信号），结果落为 CR；告警 `trivy-alerts.yaml` → Telegram，看板在 Grafana `Security` 文件夹。homelab 扫描串行（`scanJobsConcurrentLimit:1`，热约束；oracle 2），CIS 交给 kube-bench。
- ☠️ **失败几乎全静默**：告警只数现存报告，缺报告按 0 计，「漏扫」与「已清零」外观一致。**判据永远是报告数 vs 工作负载数**，不是告警绿不绿。
- 配置、各类静默失败的机制、强制重扫与覆盖率体检见 [trivy-cve-ops.md](trivy-cve-ops.md)（唯一真相源）。

## 7. CIS 合规与节点加固

- **kube-bench**：每周日 05:00 UTC CronJob，k3s 基准（`k3s-cis-*`，通用基准会满屏假 FAIL），结果 stdout→Loki（`{k8s_namespace_name="kube-bench"}`，标签是 OTel 风格，写 `namespace=` 查不到）。专用 ns 标 privileged（hostPID + host 挂载）。
  - ⚠️ 必须钉 control-plane（`nodeSelector: node-role.kubernetes.io/control-plane`）：控制面检查项只在控制面节点上有意义，排到 `k8s-worker-106` 会「看起来通过」而实际没审控制面。
  - 残余缺口（有意接受）：worker 的 node 级检查项（kubelet 文件权限等）无覆盖。要补就改 DaemonSet 式逐节点审计，或给 worker 加一个 `--targets node` 的第二 CronJob。
- **主机 SSH 与防火墙**：全舰队 sshd 只认 key。三台 Ubuntu 节点（k8s-node / worker / oracle）cloud-init 出厂即如此；两台 PVE 宿主（pve-1 / storage-106）由 `proxmox/ansible` 的 `just sshd-harden` 落 drop-in `00-homelab-hardening.conf`，盖掉 PVE 安装器写死的 `PermitRootLogin yes`（2026-11-06 起，此前宿主可被局域网爆破 root 密码）。8006 网页的 root 密码走 pveproxy+PAM，不受影响，是 SSH 进不去时的后门。⚠️ 主机防火墙只有 oracle 开着（firewalld + fail2ban，公网实测只通 22）；homelab 四台全关（pve-firewall disabled、k8s 节点的 ufw 被 `setup-k3s.yaml` 故意关），靠「NAT 后无公网入站」挡，局域网与 tailnet 内全端口可达。
- **节点加固**（`setup-k3s.yaml`）：先落盘 `/etc/sysctl.d/31-k8s-protect-kernel.conf`，再在 config.yaml 开 `protect-kernel-defaults:true`。**现网需维护窗口 `systemctl restart k3s` 才生效**。API 审计日志刻意延后（磁盘紧）。

## 8. 网络安全 (Network) — Cilium + Hubble

- **数据面**：双集群 Cilium（eBPF + VXLAN），具备 `CiliumNetworkPolicy` L3/L4/L7 能力；ClusterMesh 经 Tailscale 互联。
- **当前态：默认放行 + Hubble 可见性**（relay 开，`hubble observe` 回答「谁在跟谁通信」，是日后默认拒绝的前置）。默认拒绝刻意延后（§11）；argocd chart 自带 4 条 NetworkPolicy 提供部分隔离。
- **自建网络管控之一：readlist Job 零出口**（oracle）：`readlist-snapshot-no-egress` / `readlist-score-no-egress`，标准 `networking.k8s.io/v1` NetworkPolicy（Cilium 照常执行，不需要 CNP），`egress: []` 即全拒（含 DNS）。按数据敏感度切分：能读 calibre 书库与 `app.db`（含密码 hash/OIDC 凭据）的 snapshot/score 零出口，能出网的 ingest 挂不到 calibre 卷。可复用到其它碰敏感卷的 Job，但**只覆盖这两个短命 Job**，不代表有 ns 级或集群级默认拒绝。
- **自建网络管控之二：oracle 的 IMDS**（2026-11-10）。pod 的出口经节点 SNAT，IMDS 分不出请求来自 pod 还是节点；此前任何 pod 发一个不带头的 GET，就能取到实例主体的证书和私钥。现在有两层：①实例关了 IMDSv1（`cloud/oracle/terraform/main.tf` 的 `instance_options`），v2 必须带 `Authorization: Bearer Oracle` 头，SSRF 带不上；②CCNP `deny-oci-imds` 拦所有 pod 到 `169.254.169.254:80`，防 pod 被拿下 RCE 后自己加头。hostNetwork 进程（oracle-cloud-agent）不受影响。☠️ 只拦 80：同一地址的 `:53` 是 VCN DNS，CoreDNS 的 `oraclevcn.com` 块只转发给它，误拦会重演 2026-08-13 的 musl SERVFAIL 故障。2026-11-10 在控制台核对过，没有 dynamic group 匹配这台实例，实例主体凭据当前没有任何权限；以后要用实例主体授权，先确认这两层都还在。

## 8.5 运行时检测 (Runtime detection) — 两集群统一 Tetragon

eBPF 运行时威胁检测（容器内起 shell、读敏感文件、提权、无文件执行、攻击工具）。**2026-11-24 起两集群统一用
Tetragon**，oracle 原来的 Falco + Falcosidekick 同日退役（取舍与 Falco 规则逐条去向见
[ADR](../decisions/runtime-detection-tetragon-both-clusters.md)，经过见
[records/2026-11-24](../records/2026-11-24-oracle-kernel-7-falco-to-tetragon.md)）。

- **部署**：两集群各一个 Helm App（homelab `tetragon`、oracle `tetragon-oracle`，ns `tetragon`，chart 版本由 V1 强制
  一致），都先引用两集群共用的 `security/tetragon/values-common.yaml`（导出过滤、argv 脱敏、优先级），再叠加各自的
  `values/tetragon.yaml`（agent 资源；homelab 另开 ServiceMonitor）。`security/tetragon/` 是 H2 登记的共用树
  （[manifest-safety-checks.md](manifest-safety-checks.md)）。内核态过滤只上报命中事件，省 CPU。
  默认进程 exec/exit → `export-stdout` → 各集群 OTel → oracle 上的 Loki（`{k8s_namespace_name="tetragon"}`，`cluster`
  标签区分）。指标：homelab 走 ServiceMonitor；oracle 由 OTel 抓 `tetragon:2112`，只留告警用的三个指标。
- **策略**（`security/tetragon/policies/`，两集群同一份，独立 App `tetragon-policies` / `tetragon-policies-oracle`，
  拆法同 kyverno-policies）：`container-escape-syscalls`（容器内 ptrace / process_vm_writev / 内核模块装卸 / kexec /
  open_by_handle_at）与 `sensitive-file-access`（`security_file_open` 上内核态匹配 /etc/shadow、sudoers、/root/.ssh 等
  凭据路径）。全部**只观察、不拦截**：仓库硬约束是安全组件 fail-open，拦截型策略误报即杀生产进程。
- **告警分两路**。健康走 Prometheus（`alerts/tetragon-alerts.yaml`：`TetragonDown` / `TetragonPolicyLoadFailed` /
  `TetragonPolicyNotEnabled` / `TetragonEventsLost`，按 `(cluster, node)` 分组，`TetragonDown` 每集群一个 absent；
  promtool 用例在 `scripts/alert-rule-tests/tetragon-alerts.test.yaml`）。检测走 **Loki ruler**
  （`cloud/oracle/manifests/monitoring/loki-rules.yaml` 的 tetragon-runtime 组，不按集群过滤，warning）：
  - `TetragonRuntimePolicyHit`：上面两条策略的命中，`tp-` 前缀的策略视为临时测试不告警。夜备精确放行三条
    （restic 调 ssh 读自己的 `/root/.ssh/{id_ed25519,known_hosts,config}`、`backup.sh` 写 config、apk 的 `adduser` 改
    `/etc/shadow`）：策略 11-20 上线起每晚误报 ~130 次，11-24 才发现并补上。
  - `TetragonAppSpawnedShell`（11-22）：父进程是应用（node、python…）的 shell，webshell / 命令注入最典型的形态。
    父进程是 containerd-shim / runc 的（容器入口、exec 探针、`kubectl exec`）分不开，homelab 7 天 689 次 shell 里约 600 次
    是这类，**不报**，所以 `kubectl exec` 起的 shell 不在视野里。放行按「父进程参数 + 命令」精确写，不按 namespace：
    Prisma 的 `ldconfig -p`、supervisord；11-24 补 oracle 独有的 CNPG `manager wal-archive`、s6 的 `./run`、browserless
    读 `/proc/stat`、rsshub 的 npm 入口。
  - `TetragonFilelessExec`（11-24，移植自 Falco）：从 `/dev/shm`、memfd（`/proc/*/fd/N`）、`/tmp`、`/var/tmp` 执行或
    二进制已删除。`/dev/shm` 在容器里实测可执行。
  - `TetragonAttackToolExec`（11-24，移植自 Falco）：`nc`/`ncat`/`socat` 带 `-e`/`-c`/`EXEC:`；grep/find/rg 翻私钥标记、
    ssh key、云凭据、kubeconfig；shred/wipefs/mkfs/debugfs；truncate `/var/log`；`busybox nc -e` 直接调用一支（经软链
    调用时 Tetragon 报调用路径 `/bin/grep`，不是 busybox）。
  命中不用指标，因为 **Tetragon 会在 pod 删除后清掉该 pod 的指标序列**（实测），寿命短的 pod 里的命中可能在被评估前
  就没了，日志行不会。
- ☠️ **集群独有负载只在那个集群的基线里**：oracle 上线头一小时，「应用起 shell」就被 homelab 没有的负载触发（见上）。
  oracle 的基线截至 11-24 只有数小时，日/小时级的合法 shell 还可能冒出来，照同样写法补精确放行并重放。
- ☠️ **换内核前把 eBPF 组件当成要过闸门的东西**：unattended-upgrades 装好新内核、下次重启即生效。Falco 就是这样在
  7.0 上被 BPF 校验器的内存顶破 limit 的。重启后核：`tetra tracingpolicy list` 两条 enabled、agent 的 `memory.peak`
  离 limit 有余量（oracle 首次加载 185Mi / limit 768Mi，homelab 策略更新路径峰值 373Mi / 512Mi）。
- ⚠️ **增删策略要同步改 `TetragonPolicyNotEnabled` 里的 `2`**，否则要么永远报警、要么少一条也不报。
- ☠️ **`matchBinaries NotIn` 在这里不生效**（Tetragon 1.7.0、内核 6.8/7.0，对照实验：排除 python3 的策略照样上报 python3）。别指望用它排噪声，要排就在告警表达式 / `exportDenyList` 里做，并且做完拿真事件验证。已知噪声：apps-pg 的就绪探针 `pg_isready -U postgres` 每次都打开 /etc/shadow；它不在 Loki 里（`exportDenyList` 已挡），但在 Prometheus 指标里。
- **`exportDenyList` 也会挡策略事件**：kube-system / cilium / 宿主（namespace 为空）的命中不会进 Loki，也就不会告警；宿主进程本来就被策略的 `matchNamespaces Pid NotIn host_ns` 排除（已用宿主 `sudo cat /etc/shadow` 实测不触发）。
- **CRD 会回填服务端默认值**（`return` / `maxData` / `resolve` / `returnCopy` / `followChildren`），App 永久 OutOfSync，已用 `ignoreDifferences` 忽略。新策略用到别的可选字段时可能再冒出新键：逐字段对比 git 与 live 再补，别写 `*`。
- **验证要两个方向都测，而且别往群里发消息**：测试 pod 放 kube-system（`exportDenyList` 不导出 → 不进 Loki、不告警），
  在 agent 上 `tetra getevents --namespace kube-system --pods <pod>` 看策略命中；ptrace 用 `PTRACE_PEEKDATA` 打向不存在的
  pid，无副作用，再读一个普通文件当对照。只测 exec 类规则时测试 pod 才放导出的 ns，再用规则表达式直接查 Loki。
  ☠️ 别在导出的 ns 里 `grep -r … /etc`：会顺带打开 /etc/shadow（11-24 就这么误发过一条）。`tetra tracingpolicy list`
  显示 `enabled` 不等于探针真的在工作。
- ☠️ **进程事件带完整 argv，命令行里的密钥会进 Loki**（2026-11-24 起两集群都是）。密钥改用 env，或 curl 的 `--variable %VAR` + `--expand-*`（curl ≥ 8.3，命令行只剩 `{{VAR}}`）。exit 事件也带 argv，Tetragon 重启时还会给存量进程补发 exec 事件（`flags=procFS`），所以长期运行的进程同样会漏。
- `redactionFilters` 兜底 6 条（两集群共用）：bot token / `-u` 口令 / Bearer / URL 里的 `user:pass@` / `-token`、`--token` 的参数值 / `…Token:` 请求头的值。兜底不是正解：带空格且加引号的口令只能打掉一半。泄露经过与未轮换项见 [records/2026-10-24](../records/2026-10-24-intrusion-sweep-argv-secrets-in-loki.md)。
- ☠️ **跨文件挪 values 要拆两次提交**：多源 App 的 `$values` 跟 `main` 立即生效，valueFiles 列表要等 root App 同步；
  11-24 拆共用 values 时中间态把 tetragon-config 的 redaction-filters 写空了 6 分钟（agent 未重启，未生效）。

## 9. 安全可观测与告警

- **告警链路**（Alertmanager → Telegram、`Watchdog` 死人开关）的唯一真相源是 [observability-alerting-slo.md](observability-alerting-slo.md)；⚠️ 死人开关有已证实的失明盲区（[dead-mans-switch.md](dead-mans-switch.md)）。运行时检测（两集群 Tetragon）经 Loki ruler 进同一个 Alertmanager（§8.5）；Falcosidekick 那条绕过 Alertmanager 的直推通路随 Falco 于 2026-11-24 退役，Alertmanager 本身的失效靠死人开关兜。Gotify 与旧 bridge 已退役（[决策](../decisions/alerting-telegram-migration.md)）。
- **新增 `PrometheusRule`/`ServiceMonitor` 必须带 `release:kube-prometheus-stack`**，否则 operator selector 忽略。
- **安全相关规则**：`eso-alerts.yaml`、`trivy-alerts.yaml`、`tetragon-alerts.yaml`（Prometheus）+ `loki-rules.yaml` 的 tetragon-runtime 组（Loki ruler），多集群靠 `cluster` 标签区分。
- **看板**：Grafana `Security` 文件夹 3 张：Trivy 漏洞概览（Prometheus）、Kyverno 准入策略（Prometheus，各 controller ServiceMonitor）、运行时与审计事件（两集群 Tetragon + kube-bench，Loki）。网络流用 Hubble CLI。
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
| 容器内运行时入侵 | Tetragon（两集群：2 条观察版 TracingPolicy + Loki ruler 的应用起 shell / 无文件执行 / 攻击工具命令行 → Telegram） | ✅ 观察版，调优持续 |
| 东西向横向移动 | 网络默认拒绝 | ❌ 延后（仅 Hubble 可见性） |
| 数据丢失 | restic 双集群 CronJob（Vault raft / pg_dump / sqlite）→ 106 ZFS + 恢复演练通过 | 🟡 本地单副本，无离站 |

## 11. 已知缺口与路线图

1. **运行时检测调优**（观察版已部署，§8.5）：① Tetragon 还没做的：异常外联、ServiceAccount token 读取（都要先有「谁该读 / 该连谁」的基线，否则满屏误报）；`kubectl exec` 起的 shell 有意不报；观察一段时间后再评估是否提严，**拦截型策略要先写 ADR**；② 有意未移植的 Falco 规则（访问 K8s API、packet socket、release_agent、链接覆盖敏感文件、非标端口 SSH，理由见 [ADR](../decisions/runtime-detection-tetragon-both-clusters.md)）；③ oracle 的「应用起 shell」基线只有上线后数小时；④ oracle agent 的 memory limit（768Mi）待测过策略更新路径的峰值后收紧。
2. **网络默认拒绝（门控灰度）**：Hubble 基线流量 → 每端点 `PolicyAuditMode` 只记不拦 → 单个无状态叶子 ns（personal-services/homepage）试点 CiliumNetworkPolicy（放行 DNS/Envoy/必要 egress）→ soak → 逐 ns 评估，**建议只对对外暴露 ns 做**。
3. **节点 API 审计日志**：延后（磁盘紧）；如开启用 Metadata 级策略 + 严格 maxsize/maxbackup，先确认磁盘余量。
4. **Kyverno Audit→Enforce**（§5.2）：`require-requests-limits` 已于 2026-11-18 提升，剩 `require-probes`（先按 ns 豁免批处理）与 `restrict-image-registries`（长期保持 Audit——它抓的是镜像串写法，不是来源）。提下一条之前有两个前置：① 打开并实测 PolicyException 通道（现在是关的）；② 顺手把 `disallow-latest-tag` 改成原生 ValidatingAdmissionPolicy，填上 oracle 零引擎的空子——`--generateValidatingAdmissionPolicy=true` 已开，per-rule 开关是 `rules[].validate.cel.generate: true`，两集群都 v1.35（VAP 自 1.30 GA，homelab 已有 Cilium 的一条在跑）。⚠️ Kyverno 生成的 VAP 是否真生效**尚未实测**，先拿一个 ns 试一条并 `kubectl get vap` 核对。
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
kubectl get validatingpolicies.policies.kyverno.io         # Kyverno 策略（CEL）
kubectl get polr -A                                        # Kyverno Audit 违规
kubectl get vulnerabilityreports,exposedsecretreports -A   # Trivy 发现
kubectl create job --from=cronjob/kube-bench kb-once -n kube-bench   # 手动跑 CIS
hubble observe --namespace <ns>                            # 网络流可见性
```
