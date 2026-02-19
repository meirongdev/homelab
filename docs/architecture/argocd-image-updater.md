# ArgoCD Image Updater

## 工作原理

Image Updater 每 **2 分钟**扫描一次，完整流程如下：

```
GHCR 推送新镜像
       ↓
Image Updater 扫描 GHCR，找到匹配 tag-match-expr 的最新 tag
       ↓
比较 "最新 tag" vs "当前部署 tag"（读自 ArgoCD Application status）
       ↓ (有新版本)
向 GitHub 提交 .argocd-source-it-tools.yaml（kustomize.images 覆盖）
commit 作者: argocd-image-updater <noreply@argoproj.io>
commit 信息: "build: automatic update of it-tools"
       ↓
ArgoCD 检测到 git 变更，自动 sync 部署新镜像
```

### 关键配置文件

| 文件 | 作用 |
|------|------|
| `argocd/applications/it-tools.yaml` | ArgoCD Application，含 Image Updater 注解 |
| `k8s/helm/manifests/it-tools/imageupdater.yaml` | ImageUpdater CR，指向 it-tools Application |
| `k8s/helm/manifests/it-tools/deployment.yaml` | 基准镜像 tag（新部署时的起点） |
| `k8s/helm/manifests/it-tools/.argocd-source-it-tools.yaml` | Image Updater 自动写入，覆盖 deployment.yaml 中的 tag |

`.argocd-source-it-tools.yaml` 由 Image Updater 自动维护，**不要手动编辑**。

### 注解说明（`argocd/applications/it-tools.yaml`）

```yaml
argocd-image-updater.argoproj.io/image-list: it-tools=ghcr.io/meirongdev/it-tools
argocd-image-updater.argoproj.io/it-tools.update-strategy: newest-build   # 按镜像 build 时间选最新
argocd-image-updater.argoproj.io/it-tools.tag-match-expr: ^sha-[0-9a-f]+$ # 只跟踪 sha-* tag
argocd-image-updater.argoproj.io/it-tools.pull-secret: pullsecret:argocd/argocd-image-updater-secret
argocd-image-updater.argoproj.io/write-back-method: git:secret:argocd/git-creds
argocd-image-updater.argoproj.io/git-repository: https://github.com/meirongdev/homelab
```

---

## 验证是否正常工作

**最可靠的方式：查看 GitHub commit 历史**

```bash
git pull
git log --oneline | grep "automatic update"
# 预期: build: automatic update of it-tools
```

**查看当前 write-back 文件**

```bash
cat k8s/helm/manifests/it-tools/.argocd-source-it-tools.yaml
# 预期: kustomize.images 包含最新 tag
```

**查看 Image Updater 扫描日志**

```bash
kubectl logs -n argocd deployment/argocd-image-updater-controller --tail=20
# 正常: "Processing results: ... images_updated=1 errors=0"
# 无更新: "Processing results: ... images_updated=0 errors=0"（当前已是最新）
```

---

## 问题排查

### 症状：`images_updated=0, errors=0`，但认为有新版本未部署

这是**最常见的误判**，实际上往往是正常的。排查步骤：

**Step 1：确认 git 上是否已有自动提交**

```bash
git pull
git log --oneline | head -5
```

如果看到 `build: automatic update of it-tools`，说明 Image Updater **已经完成更新**，只是本地 git 落后了。

**Step 2：确认 ArgoCD 认为的当前镜像**

```bash
kubectl get application it-tools -n argocd \
  -o jsonpath='{.status.summary.images}'
```

Image Updater 读取此字段作为"当前版本"。如果显示已是最新 tag，则 `images_updated=0` 是正确行为。

**Step 3：确认 GHCR 上的 tag 是否匹配正则**

```bash
PAT=$(kubectl get secret git-creds -n argocd -o jsonpath='{.data.password}' | base64 -d)
TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:meirongdev/it-tools:pull&service=ghcr.io" \
  -u "meirongdev:${PAT}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])')
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://ghcr.io/v2/meirongdev/it-tools/tags/list" | python3 -m json.tool
```

确认新 tag 符合 `^sha-[0-9a-f]+$`（全小写十六进制）。

**Step 4：如果确实有漏更新，检查 ESO secret 是否同步**

```bash
# GHCR pull secret
kubectl get secret argocd-image-updater-secret -n argocd \
  -o jsonpath='{.type}'
# 预期: kubernetes.io/dockerconfigjson

# Git write-back secret
kubectl get secret git-creds -n argocd \
  -o jsonpath='{.data.username}' | base64 -d
# 预期: meirongdev
```

### 症状：修改了 Application 注解后未生效

注解存在于 `argocd/applications/it-tools.yaml`（git 中），但 ArgoCD **不管理 Application 对象本身**，只管理 Application 指向的内容。修改注解后需要手动应用：

```bash
kubectl apply -f argocd/applications/it-tools.yaml
# 验证
kubectl get application it-tools -n argocd \
  -o jsonpath='{.metadata.annotations.argocd-image-updater\.argoproj\.io/it-tools\.update-strategy}'
```

### 症状：Pod 重启后日志 level 变回 info

v1.1.0 从 ConfigMap 中的 `log.level` 字段读取日志级别，但 Helm values 的 `logLevel` 键**未能正确映射**到该字段（已知问题）。临时调试方式：

```bash
kubectl patch configmap argocd-image-updater-config -n argocd \
  --type merge -p '{"data":{"log.level":"debug"}}'
kubectl rollout restart deployment/argocd-image-updater-controller -n argocd
# 调试完毕后恢复
kubectl patch configmap argocd-image-updater-config -n argocd \
  --type merge -p '{"data":{"log.level":"info"}}'
kubectl rollout restart deployment/argocd-image-updater-controller -n argocd
```

---

## v1.1.0 与旧版本的差异

| 项目 | 旧版本 (≤ v0.x) | v1.1.0 |
|------|----------------|--------|
| 配置方式 | Application 注解 | `ImageUpdater` CRD |
| 兼容旧注解 | — | `useAnnotations: true` |
| update-strategy 命名 | `latest` | `newest-build`（`latest` 已废弃） |
| 日志配置 | Helm `logLevel` | ConfigMap `log.level` |
