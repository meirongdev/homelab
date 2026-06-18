# Phase 2 运行时检测 — Tetragon (homelab) + Falco (oracle)

> 状态: 🛠️ 已实现待部署（Falco→Gotify 推送需手动配 token；详见末节）
> 结论: 按集群硬件分别选型——homelab 用内核态过滤省 CPU 的 Tetragon，oracle 用规则开箱即用的 Falco+Falcosidekick→Gotify。
> 架构总览见 [../architecture/security.md](../architecture/security.md) §8.5。

## Context

Phase 0+1（PSA/Kyverno/Trivy/kube-bench/节点 CIS）补齐了准入与扫描，但缺**运行时**检测（容器内起 shell、读敏感文件、提权、异常外联）。本期补上，eBPF 实现。

## 选型（按集群约束）

- **homelab → Tetragon**：单节点 5600H 热笔记本，Tetragon 内核态(eBPF)过滤只上报命中事件，比 Falco 用户态逐 syscall 省 CPU、不加热；且 Cilium 原生同生态。
- **oracle → Falco + Falcosidekick**：OCI VM CPU 余量大；Falco 社区规则开箱即用，Falcosidekick 原生支持 Gotify 推送。

## 落地文件

| 组件 | 文件 | 集群 |
|------|------|------|
| Tetragon 安装 | `k8s/helm/values/tetragon.yaml` + `argocd/applications/tetragon.yaml`（ns `tetragon`） | homelab |
| Falco 安装 | `k8s/helm/values/falco.yaml` + `argocd/applications/falco.yaml`（dest=oracle 端点，ns `falco`） | oracle |
| Falco ns + Gotify token | `cloud/oracle/manifests/falco/{namespace.yaml,falcosidekick-secret.yaml}`（kustomize 拥有） | oracle |
| 仓库白名单 | `argocd/projects/homelab.yaml` sourceRepos += cilium + falcosecurity | — |
| PSA | `harden-psa` privileged += `tetragon`；falco ns 自带 privileged 标签 | — |

## 关键设计

1. **Tetragon v1 = 进程可见性**：默认 exec/exit 事件 → `export-stdout` → 现有 OTel→Loki（零额外配置）。自定义 TracingPolicy + 告警留作调优（避免一上来写错 kprobe / 加 CPU）。Prometheus 指标 ServiceMonitor 带 `release:kube-prometheus-stack`（已 helm template 验证注入成功）。
2. **Falco 双出口**：JSON→stdout→Loki（always-on，零依赖）+ Falcosidekick→Gotify（需 token）。`driver:modern_ebpf` CO-RE 免内核模块。
3. **ns 所有权**：falco ns + ESO secret 由 oracle kustomize App 拥有（含 PSA privileged 标签），Falco 工作负载由独立 falco Helm App 部署（`CreateNamespace=false`），避免双重所有权。
4. **资源**：Tetragon agent 50m/256Mi、Falco 100m/512Mi —— 均设上限保护节点。

## 手动前置（Falco→Gotify）

```bash
# 1) Gotify(notify.meirong.dev) 建 Application，取 token
# 2) 写入 Vault（oracle 路径）
vault kv put secret/oracle-k3s/falco gotify_token=<token>
```
未配前：ESO ExternalSecret Ready=False（触发现有 ESO 告警提示），falcosidekick 待启动，但 **Falco→Loki 检测照常**。

## 验证

```bash
# Tetragon（homelab）
kubectl --context k3s-homelab -n tetragon get pods
kubectl --context k3s-homelab -n tetragon logs ds/tetragon -c export-stdout --tail=5   # 进程事件 JSON
# 在某 pod 内起 shell，应在 Loki(pod=tetragon) 看到 process_exec 事件

# Falco（oracle）
kubectl --context oracle-k3s -n falco get pods
kubectl --context oracle-k3s -n falco logs ds/falco --tail=10                          # 告警 JSON
# 触发 Falco 内置规则（如容器内 `cat /etc/shadow`）应在 Loki 看到，token 配好后 Gotify 收到
```

## 后续调优（路线图）

Tetragon 写 TracingPolicy（敏感文件/提权/异常外联）+ 基于其指标的 Gotify 告警；Falco 噪声规则按本环境裁剪（`customRules`）。
