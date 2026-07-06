# K8s 资源管理与 QoS 策略

本文档记录 Homelab 中 CPU/Memory requests & limits 的设定原则和实际配置。
**当前值参见** [resource-optimization-2026-07-06.md](resource-optimization-2026-07-06.md)（含最新调整明细）。

> 延伸阅读：[K8s CPU 配置：QoS、Throttling 与驱逐策略](https://meirong.dev/posts/k8s-cpu-qos-resource-management/)

---

## 背景

Homelab 由两个集群组成：
- **homelab**（Proxmox K3s, 5600H, 12GB VM）— 有状态/数据面服务
- **oracle-k3s**（Oracle Cloud A1.Flex 4 OCPU / 24GB）— 公网无状态 + 告警面

日常用户约 1–2 人，偶发突发至 ~10 人。

### 目标

- **节省资源**：requests 反映常态负载，不过度预留
- **支撑突发**：limits 给足 burst 空间
- **防止饥饿**：补全所有缺失的 CPU limit，避免单 pod 独占 CPU

---

## QoS 类别

所有工作负载使用 **Burstable**（requests ≤ limits）：

| 类别 | 条件 | 驱逐优先级 |
|------|------|-----------|
| **Guaranteed** | requests == limits | 最后被驱逐 |
| **Burstable** | 设置了 requests 或 limits，但不完全相等 | 中等 |
| **BestEffort** | 均未设置 | 最先被驱逐 |

`Burstable` 兼顾稳态预留和空闲时 burst，适合单节点家用场景。

---

## CPU Limit 档位

| 类型 | CPU Limit | 代表服务 |
|------|-----------|---------|
| 入口流量（cloudflared × 2 副本）| `200m` | cloudflared（2026-07-06 下调） |
| 用户 Web 服务 | `500m–1000m` | calibre-web、bifrost、karakeep |
| 数据库 | `500m` | postgres |
| 可观测性 | `300m–500m` | Loki, Tempo, Prometheus, Grafana |
| 后台/轻量服务 | `100m–200m` | alertmanager, kube-state-metrics, oauth2-proxy |
| 极轻量 sidecar | `10–100m` | log-exporter, permission-fixer, argocd-image-updater |
| Batch/CronJob | `200m–300m` | restic-backup, kube-bench |
| 元数据处理 | `1000m` | calibre-metadata（每日凌晨） |

---

## 管理方式

| 方式 | 范围 | 同步策略 |
|------|------|---------|
| **ArgoCD**（raw YAML）| `k8s/helm/manifests/` 下的个人服务 | auto-sync / 120s reconciliation |
| **ArgoCD**（Helm chart）| 安全/可观测组件（kyverno、tetragon、trivy、falco、**loki、tempo、sloth**） | auto-sync / 120s reconciliation |
| **just deploy-X**（Helm）| 基础设施层（kube-prometheus-stack、vault、cilium、external-secrets）| 手动触发（bootstrapping/恢复场景） |

2026-07-06 将 loki、tempo、sloth、restic-backup 从 Helm/kubectl 管理迁入 ArgoCD。

---

## 验证 QoS

```bash
# 查看某 pod 的 QoS
kubectl get pod <pod-name> -n <namespace> -o jsonpath='{.status.qosClass}'

# 批量查看所有 pod
kubectl get pods -A -o custom-columns=\
'NAMESPACE:.metadata.namespace,NAME:.metadata.name,QOS:.status.qosClass'
```

## 检测 CPU Throttling

```bash
# CFS 配额统计
cat /sys/fs/cgroup/cpu,cpuacct/kubepods/burstable/<cgroup-id>/cpu.stat
# PromQL
rate(container_cpu_cfs_throttled_seconds_total[5m])
  / rate(container_cpu_cfs_periods_total[5m])
```

---

## 相关文档

- [resource-optimization-2026-07-06.md](resource-optimization-2026-07-06.md) — 最新资源优化明细
- [observability-multicluster.md](observability-multicluster.md) — 多集群监控架构
- [Kubernetes QoS 官方文档](https://kubernetes.io/docs/tasks/configure-pod-container/quality-service-pod/)
