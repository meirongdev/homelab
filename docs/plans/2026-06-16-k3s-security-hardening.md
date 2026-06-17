# K3s 集群内部安全加固 — Phase 0 + Phase 1

> 状态: 🛠️ 已实现待部署（GitOps 清单已落库；按 runbook 部署/验证）
> 结论: 以 PSA（永远在线基线）+ Kyverno（先 Audit）+ Trivy（CVE/密钥）+ kube-bench（CIS）+ 节点 protect-kernel-defaults 五层补集群内部安全；网络默认拒绝刻意延后。
> 部署/验证/回滚: `docs/runbooks/security-hardening.md`

## Context

南北向安全（Cloudflare WAF + Tunnel、ZITADEL OIDC、Vault+ESO）已成熟；缺口在**集群内部**——无准入管控、无镜像 CVE/配置扫描、无 Pod 安全基线、无节点 CIS。本批补齐。

**硬约束**：homelab 单节点 5600H 笔记本，idle ~74°C 触及散热上限，重启需 `just homelab-recover`。全部选型 **fail-open + 控 CPU**。

## 范围决策

用户选「Phase 0+1」。经设计评审，**把"强制网络默认拒绝"从本批延后**（本集群 DNS/ClusterMesh/Envoy/egress 链路复杂，单用户横向移动收益边际低、debug 成本高、易把 DNS 抖动放大成全站故障），本批改为只上 **Hubble 流量审计可见性**作为日后单命名空间灰度的前置。其余 Phase 0/1 全做。运行时检测（Tetragon/Falco）= Phase 2，未做。

## 落地内容（已实现的文件）

| 层 | 文件 | 说明 |
|----|------|------|
| PSA | `k8s/helm/justfile`（`harden-psa`/`psa-status`）；`cloud/oracle/manifests/*/namespace.yaml` | homelab 用幂等 label（不走 ArgoCD，避免 prune 删 ns）；oracle 在 kustomize 树声明 |
| Kyverno 安装 | `k8s/helm/values/kyverno.yaml`；`argocd/applications/kyverno.yaml` | replicas:1、backgroundScanInterval:24h |
| Kyverno 策略 | `argocd/applications/kyverno-policies.yaml`；`k8s/helm/manifests/kyverno-policies/*.yaml` | 4 条，全 Audit + failurePolicy:Ignore |
| Trivy | `k8s/helm/values/trivy-operator.yaml`；`argocd/applications/trivy-operator.yaml`；`manifests/trivy-alerts.yaml`；`manifests/trivy-dashboard.yaml` | 串行扫描 + DB 持久化；告警/看板复用现有管道 |
| kube-bench | `k8s/helm/manifests/kube-bench.yaml`；`argocd/applications/kube-bench.yaml` | 每周 CronJob，k3s 基准，结果→Loki |
| 节点 CIS | `k8s/ansible/playbooks/setup-k3s.yaml` | sysctl drop-in + `protect-kernel-defaults:true`（需重启） |
| AppProject | `argocd/projects/homelab.yaml` | sourceRepos 加 kyverno + aquasecurity 仓库 |
| include | `argocd/applications/monitoring-dashboards.yaml` | 加 trivy-alerts/trivy-dashboard |

## 关键设计决策

1. **PSA 用 `just label` 而非 ArgoCD**：本仓库 namespace 由 justfile/Helm/kustomize 混合创建，无 ns 归专门 App 拥有。渲染 Namespace 对象的 App 配 prune+selfHeal 有"误同步 prune 删 ns + 级联删 PVC（Vault/postgres/kopia）"的致命风险；label 纯元数据、幂等、不删任何东西。oracle 侧 ns 本就被 kustomize 拥有，改现有资源声明式且无风险。
2. **Kyverno `failurePolicy: Ignore`**：单节点 fail-closed = Kyverno 没起来时全集群无法调度，与重启恢复路径冲突。本批无策略值得 Fail。
3. **全部 Audit 起步**：未先盘点存量是否都设 limits/probes，必须 audit-first，逐条提 Enforce。
4. **Trivy ClientServer + builtInTrivyServer + 串行扫描**：内置长驻 server 持久化漏洞 DB，避免每 Job 重下 DB（网络+CPU）；串行杜绝热节点扫描器风暴。
5. **CIS 分工**：kube-bench 管节点 CIS；Trivy 关 clusterCompliance 避免重复跑 node-collector。

## 判定为过度（单用户 homelab）

Kyverno `failurePolicy: Fail`；PSA `restricted`（baseline 才是可达地板）；集群级默认拒绝；kube-bench 自建 parser；磁盘紧时的 API 审计日志；本批就镜像 Kyverno/Trivy 到 oracle（先 homelab 验证）。

## 延后/门控

**Cilium 网络默认拒绝（单命名空间灰度）**：Hubble 基线流量 → Cilium 每端点 PolicyAuditMode 只记不拦 → 命名空间级 CiliumNetworkPolicy（默认拒绝 + 放行 DNS/Envoy/必要 egress）→ soak → 逐 ns 评估，建议只对对外暴露 ns 做。

**Phase 2 运行时检测**：homelab→Tetragon、oracle→Falco+Falcosidekick→Gotify。
