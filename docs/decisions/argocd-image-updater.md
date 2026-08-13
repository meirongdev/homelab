# ArgoCD Image Updater

> 日期: 2026-02-19（2026-07-31 复核；2026-08-03 退役）
> 状态: ❌ **已退役（2026-08-03）** —— 空转数月（0 个 `ImageUpdater` CR，从不更新任何镜像）
> 后被卸载：删 `argocd/applications/argocd-image-updater.yaml` App + `k8s/helm/values/argocd-image-updater.yaml`，
> `oracle-k3s` App 上的旧式注解一并移除。**本页保留作为机制说明/日后重新接入的参考**
> （或改走 Renovate，见 [ROADMAP](../ROADMAP.md) 开放项 #12）。
> 退役前的运行态：chart 1.2.4 / image v1.2.2，日志常驻 `No ImageUpdater CRs to process`。
>
> ⚠️ **下面「工作原理 / 关键配置文件 / 验证 / 问题排查」几节写的是 it-tools 那套 homelab 配置，
> 已经不存在了**——it-tools 于 2026-07 迁往 oracle-k3s（`cloud/oracle/manifests/personal-services/it-tools.yaml`），
> `argocd/applications/it-tools.yaml` 与 `k8s/helm/manifests/it-tools/` 整个目录都已删除。
> 保留这几节是因为**机制说明和排查思路仍然适用**（将来给某个 App 配 `ImageUpdater` CR 时可直接套用），
> 但**里面的文件路径、`it-tools` Application、示例命令都不要照抄执行**。

## 工作原理（历史示例：it-tools，文件均已删除）

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

> ⚠️ **本节原有的说法已作废**：原文称"ArgoCD 不管理 Application 对象本身，改注解后需手动 `kubectl apply`"。
> 这在引入 App-of-Apps 之前成立，**现在不成立**——`root` App watch `argocd/applications/`
> （非递归，`recurse: false`）并开了 automated+selfHeal，所以改 `argocd/applications/*.yaml`
> **`git push` 就够了**，3 分钟内 reconcile。手动 `kubectl apply` 只在 bootstrap `root.yaml`
> 或 `root` 本身丢失时才需要。
> （同 `docs/reference/argocd-app-patterns.md` 的「控制面部署形态」条。）

所以这个症状现在的排查方向是：确认 push 是否已被 `root` App 同步下来。

```bash
kubectl get application <app> -n argocd \
  -o jsonpath='{.metadata.annotations}' | tr ',' '\n' | grep image-updater
```

### 症状：Pod 重启后日志 level 变回 info（v1.1.0 已知问题，chart ≥1.2 已修复）

v1.1.0 从 ConfigMap 中的 `log.level` 字段读取日志级别，但 Helm values 的顶层 `logLevel` 键**未能正确映射**到该字段（已知问题）。**chart ≥1.2 把该键移到 `config.log.level`，正确渲染进 ConfigMap，此工作区已不再需要下面的 patch workaround**（2026-07-18 升级到 chart 1.2.4 后验证）。以下步骤仅供仍在 v1.1.x 的环境参考：临时调试方式：

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

## 2026-07-18 更新：升级到 chart 1.2.4（image v1.2.2）

原因：CVE 修复——v1.1.0 镜像的 alpine 基础包（openssl/gnutls/py3-cryptography）+ argo-cd Go 模块共 7 个可修复 Critical CVE；升级前用集群内 trivy-server 实扫候选镜像 v1.2.2，确认 0 Critical 才升级。

- **CRD group 不变**，无既有 `ImageUpdater` CR 会被破坏，升级零功能风险。
- **日志级别 Helm 键变更**：chart ≥1.2 把 `logLevel`（顶层，v1.1.0 时映射就有 bug）移到 `config.log.level`，渲染正确。当前值设为稳态 `info`。
- **⚠️ 运行状态：当前空闲**。`kubectl get imageupdater -A` 返回 0 个 CR，日志常驻 `No ImageUpdater CRs to process`——`oracle-k3s` App 上仍带着旧式 annotation（见文件头「工作原理」一节），但没有对应的 `ImageUpdater` CR 去读取它，因此**实际没有在更新任何镜像**。这套组件目前只是部署着、不做事；如果需要它真正工作，需要补一个 `ImageUpdater` CR（`useAnnotations: true`）。
