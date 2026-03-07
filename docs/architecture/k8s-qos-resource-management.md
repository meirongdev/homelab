# K8s 资源管理与 QoS 策略

本文档记录 Homelab 中 CPU/Memory requests & limits 的设定原则和实际配置。

> 延伸阅读：[K8s CPU 配置：QoS、Throttling 与驱逐策略](https://meirong.dev/posts/k8s-cpu-qos-resource-management/)

---

## 背景

Homelab 由 homelab（Proxmox K3s）和 oracle-k3s（Oracle Cloud A1.Flex 4 OCPU / 24GB）两个集群组成，日常用户约 1–2 人，偶发突发至 ~10 人同时访问。

### 目标

- **节省资源**：requests 反映常态负载，不过度预留
- **支撑突发**：limits 给足 burst 空间，10 人访问不卡顿
- **防止饥饿**：补全所有缺失的 CPU limit，避免单 pod 独占 CPU

---

## QoS 类别说明

| 类别 | 条件 | 驱逐优先级 |
|------|------|-----------|
| **Guaranteed** | 所有容器 requests == limits（CPU + Memory 均设置且相等）| 最后被驱逐 |
| **Burstable** | 至少一个容器设置了 requests 或 limits，但不完全相等 | 中等 |
| **BestEffort** | 所有容器均未设置任何 requests/limits | 最先被驱逐 |

**本 Homelab 策略：全部使用 Burstable。**

- `Guaranteed` 会把 requests 锁死等于 limits，浪费空闲资源，不适合单节点家用场景
- `BestEffort` 在内存压力下会被第一个干掉，不可接受
- `Burstable` 兼顾两者：正常时占用 requests 量，空闲 CPU 时可 burst 到 limit

---

## CPU Limit 设定依据

CPU limit 通过 Linux CFS 配额实现，**只在节点整体 CPU 紧张时才产生 throttle**。
在节点空闲时，pod 可以自由超过 limit 使用更多 CPU（实际上不会）。

因此 limit 的作用是**防止单个 pod 在节点高负载时无限抢占 CPU**，而非限制正常性能。

### 各类服务的 CPU limit 档位

| 类型 | CPU Limit | 代表服务 |
|------|-----------|---------|
| 入口流量（cloudflared × 2 副本）| `500m` | cloudflared |
| CPU 密集型（浏览器内核）| `1000m` | chrome（KaraKeep）、browserless（RSSHub）|
| 备份服务 | `1000m` | kopia（压缩运算） |
| 用户 Web 服务 | `500m` | calibre-web、miniflux、karakeep、rsshub、n8n |
| 数据库 | `500m` | postgres |
| 后台/轻量服务 | `200m` | gotify、homepage、oauth2-proxy、uptime-kuma、redis、redpanda-connect |
| 极轻量 sidecar | `10–100m` | log-exporter、postgres-exporter、argocd-image-updater |

---

## 完整配置一览

### homelab 集群

| 文件 | 容器 | CPU req | CPU limit | Mem req | Mem limit | QoS |
|------|------|---------|-----------|---------|-----------|-----|
| `gotify.yaml` | gotify | 50m | 200m | 64Mi | 128Mi | Burstable |
| `cloudflare-tunnel.yaml` | cloudflared | 50m | 500m | 64Mi | 256Mi | Burstable |
| `calibre-web.yaml` | calibre-web | 100m | 500m | 256Mi | 1024Mi | Burstable |
| `calibre-web.yaml` | log-exporter | 1m | 10m | 8Mi | 16Mi | Burstable |
| `kopia.yaml` | kopia | 100m | 1000m | 256Mi | 1Gi | Burstable |

Helm 管理的服务（Prometheus、Grafana、Loki、Tempo、ArgoCD、Vault、ZITADEL、Traefik）resources 在对应 `values/*.yaml` 中配置，均已设置完整的 CPU + Memory requests/limits。

### oracle-k3s 集群

| 文件 | 容器 | CPU req | CPU limit | Mem req | Mem limit | QoS |
|------|------|---------|-----------|---------|-----------|-----|
| `base/cloudflare-tunnel.yaml` | cloudflared | 50m | 500m | 64Mi | 256Mi | Burstable |
| `auth-system/oauth2-proxy.yaml` | oauth2-proxy | 10m | 200m | 32Mi | 64Mi | Burstable |
| `homepage/homepage.yaml` | homepage | 50m | 200m | 128Mi | 256Mi | Burstable |
| `rss-system/miniflux.yaml` | miniflux | 50m | 500m | 64Mi | 256Mi | Burstable |
| `rss-system/miniflux.yaml` | postgres | 50m | 500m | 128Mi | 512Mi | Burstable |
| `rss-system/miniflux.yaml` | postgres-exporter | 10m | 50m | 32Mi | 64Mi | Burstable |
| `rss-system/karakeep.yaml` | karakeep | 100m | 500m | 256Mi | 512Mi | Burstable |
| `rss-system/karakeep.yaml` | chrome | 100m | 1000m | 256Mi | 1Gi | Burstable |
| `rss-system/karakeep.yaml` | meilisearch | 100m | 500m | 256Mi | 768Mi | Burstable |
| `rss-system/n8n.yaml` | n8n | 100m | 500m | 256Mi | 1Gi | Burstable |
| `rss-system/rsshub.yaml` | rsshub | 100m | 500m | 256Mi | 512Mi | Burstable |
| `rss-system/rsshub.yaml` | redis | 50m | 200m | 64Mi | 128Mi | Burstable |
| `rss-system/rsshub.yaml` | browserless | 100m | 1000m | 256Mi | 1Gi | Burstable |
| `rss-system/redpanda-connect.yaml` | webhook-to-karakeep | 50m | 200m | 64Mi | 128Mi | Burstable |
| `rss-system/redpanda-connect.yaml` | karakeep-to-gotify | 50m | 200m | 64Mi | 128Mi | Burstable |
| `personal-services/it-tools.yaml` | it-tools | 20m | 200m | 32Mi | 128Mi | Burstable |
| `personal-services/squoosh.yaml` | squoosh | 20m | 200m | 64Mi | 256Mi | Burstable |
| `personal-services/stirling-pdf.yaml` | stirling-pdf | 100m | 1000m | 256Mi | 1Gi | Burstable |
| `uptime-kuma/uptime-kuma.yaml` | uptime-kuma | 50m | 200m | 128Mi | 256Mi | Burstable |
| `monitoring/otel-collector.yaml` | otel-collector | 50m | 250m | 64Mi | 256Mi | Burstable |
| `monitoring/exporters.yaml` | node-exporter | 20m | 100m | 32Mi | 64Mi | Burstable |
| `monitoring/exporters.yaml` | kube-state-metrics | 20m | 100m | 32Mi | 128Mi | Burstable |

---

## 验证 QoS 类别

```bash
# 查看某个 pod 的 QoS 类别
kubectl get pod <pod-name> -n <namespace> -o jsonpath='{.status.qosClass}'

# 批量查看所有 pod 的 QoS
kubectl get pods -A -o custom-columns=\
'NAMESPACE:.metadata.namespace,NAME:.metadata.name,QOS:.status.qosClass'
```

## 检测 CPU Throttling

```bash
# 在节点上查看某 pod 的 CFS 配额统计
cat /sys/fs/cgroup/cpu,cpuacct/kubepods/burstable/<pod-cgroup-id>/cpu.stat
# 关注 nr_throttled 和 throttled_time 字段

# 通过 Prometheus 查询 throttling 率（需要 cadvisor 指标）
rate(container_cpu_cfs_throttled_seconds_total[5m])
  / rate(container_cpu_cfs_periods_total[5m])
```

---

## 相关文档

- [Kubernetes QoS 官方文档](https://kubernetes.io/docs/tasks/configure-pod-container/quality-service-pod/)
- [Node Pressure Eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/)
- [groundcover: CPU Throttling](https://www.groundcover.com/blog/kubernetes-cpu-throttling)
- [observability-multicluster.md](observability-multicluster.md) — 多集群监控架构
