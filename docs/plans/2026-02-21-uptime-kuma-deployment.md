# Uptime Kuma 部署实施计划

**日期：** 2026-02-21
**状态：** ✅ 已完成 (Completed 2026-02-21)

## 目标
部署 Uptime Kuma 到 Kubernetes 集群，用于监控 Homelab 各项服务的外部可用性、证书状态及网络延迟。

---

## 架构设计

### 1. 资源规格
| 组件 | 规格 |
|------|------|
| **Namespace** | `personal-services` |
| **镜像** | `louislam/uptime-kuma:1` |
| **存储** | 10Gi (NFS / `nfs-client` StorageClass) |
| **外部访问** | `status.meirong.dev` (Cloudflare Tunnel -> Traefik) |

### 2. Kubernetes 资源
*   **PersistentVolumeClaim**: `uptime-kuma-pvc` 用于持久化 SQLite 数据库。
*   **Deployment**: 运行 Uptime Kuma 容器，挂载数据目录 `/app/data`。
*   **Service**: ClusterIP 暴露端口 3001。
*   **HTTPRoute**: 在 `manifests/gateway.yaml` 中定义路由规则。

---

## 实施步骤

### Task 1: 编写清单 (Manifests)
- 创建 `k8s/helm/manifests/uptime-kuma.yaml`，包含 PVC, Service, Deployment。
- 更新 `k8s/helm/manifests/gateway.yaml`，添加 `status.meirong.dev` 的 HTTPRoute 规则。

### Task 2: GitOps 注册
- 修改 `argocd/applications/personal-services.yaml`，在 `include` 列表中添加 `uptime-kuma.yaml`。

### Task 3: 域名解析
- 修改 `cloudflare/terraform/terraform.tfvars`，添加 `status` 子域名。
- 执行 `cd cloudflare/terraform && just apply`。

### Task 4: 验证与配置
- 在 ArgoCD 中确认应用同步状态。
- 访问 `https://status.meirong.dev` 进行初始化配置。
- 设置报警通知（Discord/Telegram）。

---

## 实际实施说明

- 监控配置通过 ArgoCD **PostSync Hook Job** 自动完成，无需手动在 UI 中添加
- 监控列表定义在 `manifests/uptime-kuma.yaml` 的 `uptime-kuma-provisioner` ConfigMap 中
- 新增服务时，只需在 ConfigMap 的 `MONITORS` 列表追加一条记录并 `git push` 即可
- Admin 凭证存储在 Vault `secret/homelab/uptime-kuma`，通过 ESO 同步为 K8s Secret

## 回滚方案
1. 从 `personal-services.yaml` 的 include 列表中移除。
2. `kubectl delete -f k8s/helm/manifests/uptime-kuma.yaml`。
