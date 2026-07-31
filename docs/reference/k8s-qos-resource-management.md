# K8s 资源管理与 QoS 策略

> Last updated: 2026-07-31
> Status: 生效事实（本文只定**原则**，不存具体数值）

本文档记录 Homelab 中 CPU/Memory requests & limits 的设定**原则**。
**具体数值不在本文维护** —— 以 `k8s/helm/values/` 与集群实际为准
（`kubectl -n <ns> get deploy -o yaml`）。2026-07-06 那轮调整的推导过程见
[plans/architecture/2026-07-06-resource-optimization.md](../plans/architecture/2026-07-06-resource-optimization.md)（历史快照）。

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

loki、tempo、sloth、restic-backup 已从 Helm/kubectl 管理迁入 ArgoCD（2026-07-06）。

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

## requests/limits 该填多少？

不靠拍脑袋 —— **KRR 每周一出推荐报告**推到 Telegram（CPU 取 p95，内存取窗口内 max + 15%）。
双集群均已部署，见 [cost-and-rightsizing.md](cost-and-rightsizing.md#krr)。

采纳流程：KRR **只读不改**（`krr-enforcer` 刻意未部署，会与 ArgoCD selfHeal 死循环），
看完报告手工改 git 里的 `resources`。

两个读数注意事项：

- 标 `(No data)` / `(Not enough data)` 的是当前没有运行 Pod 的 Job/CronJob，忽略即可
- 内存推荐取 **7 天**窗口内的 max（对齐 Prometheus retention），跨周尖峰
  （如每周备份 CronJob）可能落在窗口外，这类工作负载要自行留余量

---

## 相关文档

- [cost-and-rightsizing.md](cost-and-rightsizing.md) — OpenCost 成本归因 + KRR 右尺寸
- [plans/architecture/2026-07-06-resource-optimization.md](../plans/architecture/2026-07-06-resource-optimization.md) — 2026-07-06 那轮调整的推导（历史快照，非当前值）
- [observability-multicluster.md](observability-multicluster.md) — 多集群监控架构
- [Kubernetes QoS 官方文档](https://kubernetes.io/docs/tasks/configure-pod-container/quality-service-pod/)
