# ArgoCD Image Updater 实现计划

**Goal:** 安装 ArgoCD Image Updater，自动监控 `ghcr.io/meirongdev/it-tools` 镜像，有新版本时自动提交 Git 并由 ArgoCD 部署。

**Architecture:** Image Updater 以 Helm 方式部署在 `argocd` namespace，通过 ESO 从 Vault 获取 GitHub PAT，用于 GHCR 镜像拉取和 Git 写回。`it-tools` 从 `personal-services` Directory Application 中拆分为独立的 Kustomize Application，以支持 Image Updater 的 Git write-back。

**Tech Stack:** ArgoCD Image Updater (Helm chart `argo/argocd-image-updater`)、ESO、HashiCorp Vault、Kustomize、GitHub PAT

---

## 关键文件路径

| 操作 | 文件 |
|------|------|
| 修改 | `argocd/projects/homelab.yaml` — 添加 argo-helm 到 sourceRepos |
| 修改 | `argocd/applications/personal-services.yaml` — 移除 it-tools.yaml |
| 修改 | `argocd/applications/vault-eso.yaml` — 添加 github-external-secret.yaml |
| 新建 | `k8s/helm/manifests/github-external-secret.yaml` — 两个 ESO ExternalSecret |
| 新建 | `k8s/helm/manifests/it-tools/deployment.yaml` |
| 新建 | `k8s/helm/manifests/it-tools/service.yaml` |
| 新建 | `k8s/helm/manifests/it-tools/kustomization.yaml` |
| 新建 | `argocd/applications/it-tools.yaml` — 带 Image Updater 注解 |
| 新建 | `argocd/applications/argocd-image-updater.yaml` — Helm Application |
| 新建 | `k8s/helm/values/argocd-image-updater.yaml` — Helm values |
| 删除 | `k8s/helm/manifests/it-tools.yaml` |

---

## Task 0: 保存计划到项目 docs 目录

```bash
mkdir -p docs/plans
```

---

## Task 1: 将 GitHub PAT 存入 Vault

**前提：** 需要一个具有 `read:packages` + `contents:write` 权限的 GitHub PAT。

```bash
kubectl exec -n vault vault-0 -- \
  vault kv put secret/homelab/github \
    username=meirongdev \
    pat=<YOUR_GITHUB_PAT>
```

验证：
```bash
kubectl exec -n vault vault-0 -- vault kv get secret/homelab/github
# 预期：显示 username 和 pat 字段
```

---

## Task 2: 创建 ESO ExternalSecret（GHCR auth + Git write-back）

新建 `k8s/helm/manifests/github-external-secret.yaml` 并修改 `argocd/applications/vault-eso.yaml` include 列表。

---

## Task 3: 将 it-tools 拆分为 Kustomize 结构

新建 `k8s/helm/manifests/it-tools/` 目录结构，移除旧 `it-tools.yaml`，更新 `personal-services.yaml`。

---

## Task 4: 创建 it-tools 独立 ArgoCD Application

新建 `argocd/applications/it-tools.yaml` 带 Image Updater 注解。

---

## Task 5: 安装 ArgoCD Image Updater

新建 `k8s/helm/values/argocd-image-updater.yaml` 和 `argocd/applications/argocd-image-updater.yaml`。

---

## Task 6: 更新 AppProject 允许 Helm 源

修改 `argocd/projects/homelab.yaml` 添加 `https://argoproj.github.io/argo-helm`。

---

## Task 7: 提交并部署

```bash
kubectl apply -f argocd/projects/homelab.yaml
git add ... && git commit && git push
kubectl apply -f argocd/applications/
cd k8s/helm && just argocd-sync
```

---

## Task 8: 验证

检查 Image Updater pod、ESO secrets、it-tools Application 状态。

---

## 注意事项

- **Vault 路径格式：** ESO 的 `remoteRef.key` 使用 `secret/homelab/github`（不含 `/data/`，ESO 自动处理 KV v2 前缀）
- **双重 Secret 用途：** 同一个 GitHub PAT 同时用于 GHCR 拉取（dockerconfigjson 格式）和 Git 写回（username/password 格式）
- **tag-match-expr：** `^sha-[0-9a-f]+$` 匹配小写十六进制 SHA
- **验证后：** 确认一切工作正常后，将 logLevel 从 `debug` 改为 `info`
