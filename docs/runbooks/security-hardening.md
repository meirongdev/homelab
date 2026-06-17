# Security Hardening Runbook — 集群内部安全（Phase 0 + 1）

> Last updated: 2026-06-16

## Overview

补齐集群**内部**安全（南北向的 Cloudflare WAF / ZITADEL OIDC / Vault+ESO 已成熟）。本批五层：

| 层 | 组件 | 部署方式 | 集群 | 常驻开销 |
|----|------|----------|------|----------|
| Pod 安全基线 | Pod Security Admission (内置) | `just harden-psa`（homelab）+ kustomize 标签（oracle） | 双 | 零 |
| 准入策略 | Kyverno（先 Audit） | ArgoCD Helm App | homelab | 低（webhook + 24h 后台扫描） |
| 供应链/CVE | Trivy Operator | ArgoCD Helm App | homelab | 低（串行扫描 + DB 缓存） |
| 节点基线 | k3s `protect-kernel-defaults` + sysctl | ansible（需重启） | homelab | 零 |
| CIS 巡检 | kube-bench CronJob（每周） | ArgoCD plain-manifest | homelab | 极低（周期一次） |
| 网络可见性 | Hubble（已启用） | — | 双 | 已有 |

**硬约束**：homelab = 单节点 5600H 笔记本，idle ~74°C，重启需 `just homelab-recover`。故全部选型 fail-open、控 CPU。

**刻意延后**：Cilium 网络默认拒绝（单命名空间灰度，独立门控变更，见末节）；API 审计日志（磁盘紧）。

---

## ⚠️ 部署前必做：核对 Helm chart 版本

我无法保证 pin 的 chart 版本一定存在。**首次部署前**核对并按需改 `targetRevision`：

```bash
cd k8s/helm && just add-repos        # 确保 helm repo 已添加
helm search repo aqua/trivy-operator --versions | head    # → argocd/applications/trivy-operator.yaml
helm search repo kyverno/kyverno     --versions | head    # → argocd/applications/kyverno.yaml
```

kube-bench 镜像 tag（`k8s/helm/manifests/kube-bench.yaml`）与 k3s 基准名同理——见该层下方说明。

---

## 部署顺序（低风险高价值先行）

> 大部分经 `git push` → ArgoCD 3 分钟自动同步。`kubectl`/`helm` 上下文 = `k3s-homelab`。

### 0. 前置：注册 AppProject 的新 Helm 仓库

`argocd/projects/homelab.yaml` 的 `sourceRepos` 已加 kyverno + aquasecurity 仓库，但 AppProject 不归 ArgoCD 自动同步，需手动 apply 一次：

```bash
kubectl --context k3s-homelab apply -f argocd/projects/homelab.yaml
```

### 1. PSA Pod 安全基线（最先，最低风险）

```bash
cd k8s/helm && just harden-psa        # homelab：幂等打标签
just psa-status                       # 看各 ns enforce/warn 等级
git push                              # oracle：kustomize 树标签随 ArgoCD 同步
```

- baseline ns（实测零特权工作负载）：`default vault zitadel kopia database bifrost personal-services cloudflare external-secrets argocd`
- privileged ns（显式豁免，warn/audit 仍记 baseline）：`kube-system monitoring`
- PSA 仅在 Pod **创建/更新**时评估，不杀已运行 Pod。

**验证**：
```bash
kubectl --context k3s-homelab get ns -L pod-security.kubernetes.io/enforce
# baseline 拦截冒烟测试（应被拒绝）：
kubectl --context k3s-homelab -n personal-services run psa-test --image=busybox --privileged --rm -it --restart=Never -- true
```

### 2. kube-bench CIS 巡检

`git push` 后 ArgoCD 同步 `kube-bench` App。手动触发一次：
```bash
kubectl --context k3s-homelab create job --from=cronjob/kube-bench kube-bench-once -n kube-bench
kubectl --context k3s-homelab logs -n kube-bench job/kube-bench-once | less
```
**k3s 基准/镜像 tag 排错**：若日志报 "unable to find config / benchmark not found"，列出镜像内可用基准目录并改 `manifests/kube-bench.yaml` 的 `--benchmark`：
```bash
kubectl --context k3s-homelab run kb --rm -it --image=docker.io/aquasec/kube-bench:v0.15.6 --command -- ls /opt/kube-bench/cfg/
```
结果经 OTel→Loki，按 `{namespace="kube-bench"}` 查阅。

### 3. Trivy Operator

核对 chart 版本后 `git push`，ArgoCD 同步 `trivy-operator` App（ns `trivy-system`）。
```bash
kubectl --context k3s-homelab get pods -n trivy-system
kubectl --context k3s-homelab get vulnerabilityreports,configauditreports,exposedsecretreports -A
```
- 指标核对（首次扫描后）：`kubectl -n trivy-system port-forward svc/trivy-operator 8080:8080` 然后 `curl -s localhost:8080/metrics | grep trivy_`，确认 `trivy_image_vulnerabilities` / `trivy_exposedsecrets_findings` / `trivy_resource_configaudits` 名称与 `manifests/trivy-alerts.yaml` 一致（不同 chart 版本可能微调）。
- 看板：Grafana → `Security` 文件夹 → "Security / Trivy 漏洞概览"。
- 告警：critical CVE / 暴露密钥经 Alertmanager→Gotify。

### 4. Kyverno（Audit 起步）

核对 chart 版本后 `git push`。两个 App：`kyverno`（安装）+ `kyverno-policies`（策略）。
> `kyverno-policies` 首次同步可能因 ClusterPolicy CRD 未就绪短暂失败，待 `kyverno` 装好 CRD 后自动重试。

```bash
kubectl --context k3s-homelab get pods -n kyverno
kubectl --context k3s-homelab get cpol                 # 4 条策略 Ready
kubectl --context k3s-homelab get polr -A              # Audit 模式下的违规报告
```

**Audit → Enforce 提升流程**（逐条）：
1. 读 `kubectl get polr -A` 找出某策略的存量违规；
2. 修违规的工作负载 manifest（git）；
3. 确认该策略零违规后，把对应 `manifests/kyverno-policies/<策略>.yaml` 里每条 rule 的 `validate.failureAction: Audit` 改为 `Enforce`，`git push`。（Kyverno v1.11+ 用 per-rule `failureAction`，非旧的 spec 级 `validationFailureAction`。）
- `restrict-image-registries` 噪声最大（裸镜像名会被标记），长期建议保持 Audit，提 Enforce 前先把镜像写全限定名。
- 所有策略 `failurePolicy: Ignore`（fail-open）——Kyverno 宕机不阻断调度（保护单节点恢复路径）。

### 5. 节点 CIS 内核加固（需重启，放最后）

`k8s/ansible/playbooks/setup-k3s.yaml` 已加：`/etc/sysctl.d/31-k8s-protect-kernel.conf` + config.yaml `protect-kernel-defaults: true`。

```bash
cd k8s/ansible && just setup-k8s     # 幂等：写 sysctl drop-in（立即生效+持久化）+ 写 config.yaml
```
**现有节点不会自动生效**——`protect-kernel-defaults` 仅在 k3s 重启时校验。安排维护窗口：
```bash
ssh ubuntu@100.94.186.7 'sudo sysctl --system && sudo systemctl restart k3s'   # 或整机重启
kubectl --context k3s-homelab get nodes                                        # 确认 Ready
just homelab-recover                                                           # 重启后常规恢复
```
> 顺序保障：sysctl drop-in 先落盘且持久化（systemd-sysctl 每次启动应用），故 k3s 重启时 `protect-kernel-defaults` 检查必过。若误删 drop-in 则 k3s 拒启——重写该文件即可。

### 6. Hubble 流量可见性（网络默认拒绝的前置）

Hubble 已启用。确认能回答"谁在跟谁通信"：
```bash
cd k8s/helm && just hubble-ui        # 或 CLI：
kubectl --context k3s-homelab -n kube-system exec ds/cilium -- hubble observe --namespace personal-services
```

---

## 延后/门控：Cilium 网络默认拒绝（单命名空间灰度）

本批**不**做强制默认拒绝（本集群 DNS/ClusterMesh/Envoy/egress 链路复杂，单用户场景收益边际低、debug 成本高）。日后做时的安全路径：

1. 选无状态叶子 ns 试点（`personal-services` 或 `homepage`，无跨集群服务、无数据）；
2. `hubble observe --namespace <ns>` 基线真实流量；
3. 先开 Cilium 每端点 **policy audit mode**（`cilium endpoint config <id> PolicyAuditMode=Enabled`）只记不拦；
4. 写命名空间级 `CiliumNetworkPolicy`：默认拒绝 + 显式放行（DNS egress→kube-system CoreDNS、入站放行 gateway/Envoy 身份、必要 `toFQDNs`/`toCIDR` egress、如涉跨集群再放 ClusterMesh）；
5. soak 看 Hubble `DROPPED`，迭代后再翻成强制；
6. 逐 ns 评估——建议**只对对外暴露的 ns** 做默认拒绝，纯内部的不做。

## 回滚

- PSA：`kubectl label ns <ns> pod-security.kubernetes.io/enforce=privileged --overwrite`（或删标签）。
- Kyverno/Trivy/kube-bench：删对应 `argocd/applications/*.yaml` 并 push（ArgoCD prune），或 `kubectl delete app <name> -n argocd`。
- 节点加固：config.yaml 去掉 `protect-kernel-defaults: true` 后重启 k3s。
