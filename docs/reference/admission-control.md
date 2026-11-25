# 准入管控：PSA + Kyverno + 资源护栏

> Last updated: 2026-11-25
> Status: 生效事实
> Scope: 纵深防御第 4、5 层（Pod Security Admission、Kyverno）与 LimitRange / ResourceQuota 护栏的生效事实。
> 2026-11-25 从 [security.md](security.md) §5 拆出；逐层状态总表仍在 security.md（R6）。
> 部署/验证/回滚见 [../runbooks/security-hardening.md](../runbooks/security-hardening.md)。

## 1. Pod Security Admission（基线地板，永远在线）

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

## 2. Kyverno（策略即代码，homelab）

- 拆分 controller 各 `replicas:1`、`backgroundScanInterval:24h`、**所有策略 `failurePolicy:Ignore`（fail-open）**：fail-closed 时 Kyverno 起不来全集群就无法调度，与恢复路径冲突。
- ☠️ 代价要说全：admission-controller 单副本、无反亲和、`priorityClassName:bulk`（内存压力下主动可驱逐），叠加 `failurePolicy:Ignore` 后，**`validationActions:[Deny]` 的实际语义是「该 controller 存活期间强制」**——重启/升级/被驱逐的窗口里新建 Pod 一律放行，且没有任何「这段时间没校验」的信号。机制级地板只有 PSA（§1）。
- **4 条 ValidatingPolicy**（`policies.kyverno.io/v1`，CEL；2026-11-19 由 legacy ClusterPolicy 迁入；最近对 live 核对：2026-11-19）：

  | 策略 | Action | 说明 |
  |------|--------|------|
  | disallow-latest-tag | **Deny** | digest-aware（只拦 `:latest`）；运行中工作负载零 `:latest`，零阻断 |
  | require-requests-limits | **Deny**（2026-11-18 提升） | 提升依据见下条方法论：11 条违规**全在 kube-system**，而它整 ns 被排除 → 受管控 ns 违规为 0，提升当下零新增阻断。⚠️ 此后 `cloudflare`/`databases`/`litellm`/`opencost`（无 LimitRange，§3）里任何不声明 resources 的 Pod 都会被拒 |
  | restrict-image-registries | Audit（长期） | 实测 91 条违规里**没有一个非可信来源**：11 个唯一镜像串只是省略了 `docker.io/` 前缀（隐式 docker.io，本就在白名单内，其中 10 个还是 digest 固定的），另两个是白名单确实漏了 `reg.kyverno.io`（Kyverno 官方源，只在 kyverno ns，不受准入管控，只污染后台报告）与 `mirror.gcr.io`。即它校验的是镜像串写法而非来源可信度，故长期保持 Audit；真正的供应链缺口在别处——digest 固定率不足一半（2026-11-18 业务容器 35/93），而 `mirror.gcr.io` 正是「无认证 Hub 透明镜像 + 不固定 digest」两个弱条件叠加。要收紧应新增一条要求 digest 固定的规则，而不是放宽本条 |
  | require-probes | Audit | 失败大头是 Job/CronJob（合理无 probe）+ 基础设施，Enforce 会误伤批处理 |

- **Audit→Deny 的分母是「本 webhook 真正 gate 的 ns」，不是 `polr` 原始计数**：原始计数同时混入了被排除的 `kube-system`/`kyverno`、0 副本历史 ReplicaSet 与一次性 Job，直接看既虚高又可能指向错误的 ns。正确做法是按规则聚合后剔除非 gate ns。现值（2026-11-18）：`registries` 91（受管控 68）、`readiness-probe` 18（受管控 13）、`requests-limits` 11（受管控 **0**）、`latest-tag` 0。Deny 只作用于新建 Pod。2026-11-19 迁 CEL 后 `require-requests-limits` 的 namespaceSelector 连后台扫描一起排除 kube-system，报告里不再有那 11 条。
- ⚠️ **豁免通道当前是关的**：admission-controller 带 `--enablePolicyException=false`，而 PolicyException 的 CRD（`kyverno.io/v2` 与 `policies.kyverno.io/v1`）都 served —— 今天创建例外对象会被静默收下、不生效。现有 2 条 Deny 都零违规所以不挡路，但要给改不动的上游 chart（jellyfin/navidrome 这类）提 Deny，得先实测例外 API 真的生效、在 chart 里怎么打开（v1.20 起 legacy 的 `kyverno.io` PolicyException 随 legacy 执行一起移除，只有 `policies.kyverno.io/v1` 那套有意义）。
- 系统 ns（CNI/控制面绝不 gate）：准入侧由 configmap 的 webhook namespaceSelector 排除 kube-system/kyverno，两条 Deny 策略另在自己的 `namespaceSelector` 里显式写了 kube-system/kube-public/kube-node-lease/kyverno，这样后台扫描也一致。ValidatingPolicy 不回填服务端默认字段，App 不再需要 `ignoreDifferences`。
- ✅ **legacy `kyverno.io` 策略类型已清零**（2026-11-19）：Kyverno v1.20 源码里已删掉 legacy 准入/后台/报告执行路径，且 chart 3.10 在集群里还有 legacy 策略时拒绝升级，所以升级前必须迁完。迁移要点（语义对应表在各策略文件头注释里）：① `objectSelector` 只在 webhook 层生效，**后台扫描不认**，要排除某类对象必须再写 `matchConditions`（`require-probes` 排除 Job Pod 就栽过：并跑对比时新版多出 25 个 CronJob Pod 的恒定误报）；② 迁移用**并跑 + 按资源逐条对比两个 source 的 PolicyReport**（`source=kyverno` vs `KyvernoValidatingPolicy`），不看 READY；③ 新写策略一律 `policies.kyverno.io/v1`，别再加 ClusterPolicy。
- 🚧 **oracle-k3s 没有策略引擎**：实测那边只有 CNPG/ESO 的 CRD schema 校验 webhook + PSA，`:latest`、无 requests、任意 registry 装进 oracle 不留任何记录。而它承载 GitOps 控制面 + ZITADEL + 生产 PG。不值得为它再跑 4 个 controller，候选做法是把 `disallow-latest-tag` 用原生 ValidatingAdmissionPolicy（CEL，v1.35 已 GA）单条装过去——零常驻成本，见 [security.md](security.md) §11。

## 3. 资源护栏：LimitRange + ResourceQuota

- **LimitRange**：`manifests/namespace-guardrails/namespace-guardrails.yaml`（App `namespace-guardrails`）给轻量应用 ns（external-secrets/vault/default；zitadel、argocd 已迁去 oracle）注入默认 `requests`(cpu25m/mem64Mi) + `limits.memory` 1Gi（宽松，避免 request>limit 被拒；不设 cpu limit，避免节流）。jobs-sg/media/personal-services 用各自清单里的 LimitRange。
- 作用：未声明资源的容器不再无界；LimitRanger 先于 Kyverno 注入默认值，新 Pod 自动满足 require-requests-limits。monitoring/kube-system 刻意不加，避免拒绝风险。
- ⚠️ **覆盖是按 ns 逐个铺的，不是全集群**：实测（2026-11-18）有 LimitRange 的只有 default/external-secrets/vault（guardrails）+ jobs-sg/media/personal-services（自带）6 个。`cloudflare`、`databases`、`litellm`、`opencost` 没有——那 4 个 ns 的 requests/limits 全靠清单自己写，由 §2 的 Enforce 拦住。新 ns 要不要加，先看这张覆盖表。
- **ResourceQuota 是另一条独立的线**，只限**对象数量**、不限 cpu/mem，别和 LimitRange 混为一谈：`jobs-sg-quota`（`count/jobs.batch` 现 9/限 25、`pods` 1/12）、`media-object-caps`（pods 3/15）、`personal-services-object-caps`（jobs 0/15、pods 7/30），清单与各自的 LimitRange 同文件（`k8s/helm/manifests/{jobs-sg,media,personal-services}/`）。
- 它防的是**节点级稀缺资源**：kubelet 的 pod 上限是硬天花板，一个失控的 CrashLoop Job 刷出几十个 Pod 就能把整节点填满，而 LimitRange 对「数量」完全无感——这正是当初驱逐事故的第二个成因面。
