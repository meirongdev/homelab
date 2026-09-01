# 自研应用不打 Helm chart：Helm 只用于消费上游 chart

> 日期: 2026-08-03
> 状态: ✅ 已实施（本决策是把既成事实成文，不改变任何现有部署）

## 上下文

评估自研服务 [jobs-sg](https://github.com/meirongdev/jobs-sg) 落地时提出的问题：
「做成 Helm chart 是不是更容易部署？」

这条界线此前只是既成事实、从未成文：[argocd-app-patterns.md](../reference/argocd-app-patterns.md)
的「3 种子模式」表只描述了哪个 App 用哪种源，没写选择规则，更没写理由。
于是每来一个自研应用就要重新讨论一次，且新人（含 AI 助手）看不出这是有意为之
还是历史偶然。

**现状事实**（2026-08-03 清点）：

| 目录 | 内容 | 举例 |
|------|------|------|
| `k8s/helm/values/` | **全部**是上游第三方 chart 的 values | loki、tempo、kyverno、falco、trivy、vault、cnpg、external-secrets、kube-prometheus-stack、opencost、sloth、argocd |
| `k8s/helm/manifests/` | **全部**是自研 / 自组装清单 | gateway、cloudflare、kube-bench、kyverno-policies、monitoring、namespace-guardrails、personal-services、vault-eso |
| `cloud/oracle/manifests/` | 同上（oracle 侧 kustomize 树） | calibre-metadata、homepage、uptime-kuma… |

集群里**零个自研 chart**。

## 决策

**自研应用**（清单由本仓库维护、镜像出自我们自己的 CI）一律用 kustomize 目录或
目录源，**不打 Helm chart**。Helm 仅用于消费上游第三方 chart。

理由按权重：

1. **`AppProject.sourceRepos` 是白名单，而 `AppProject` 不受 GitOps 管理。**
   chart 若放在应用自己的仓库，必须往 `argocd/projects/homelab.yaml` 的 `sourceRepos`
   加一条：而 root App 的 `path` 是 `argocd/applications`，**`argocd/projects/` 不在
   任何 Application 的托管路径下**（已核 `argocd/applications/root.yaml:19`）。
   也就是说 `git push` 对它不生效，得手工
   `kubectl --context oracle-k3s apply -f argocd/projects/homelab.yaml`（或 `just deploy-argocd`）。
   每多一个自研应用就多一次带外手工操作，漏了就是同步失败：
   `application repo https://... is not permitted in project 'homelab'`。

2. **Application 名 = Helm release 名。** ArgoCD 拿 App 名当 release 名，资源名会被
   chart 的 fullname 模板加前缀/后缀；同一 chart 上双集群时还得靠 `helm.releaseName`
   兜底（`fullnameOverride` 不够，2026-07-31 实测更正，见
   [argocd-app-patterns.md](../reference/argocd-app-patterns.md) 坑 2）。
   裸清单里资源叫什么就是什么，没有这层映射。

3. **Kyverno `disallow-latest-tag` 是 Enforce，镜像必须 pin digest。**
   kustomize 的 `images[].newDigest` 一行完事；chart 要自己设计
   `image.repository/tag/digest` 的 values 管道，还要保证模板真把 digest 拼对
   （`@sha256:` 与 `:tag` 的拼接分支是 chart 模板的经典 bug 面）。

4. **模板化的收益要靠「多份部署」兑现，而这里只有一份。**
   单集群单实例、没有 dev/staging/prod 分层。给唯一一份清单套模板只是多一层间接：
   读要先在脑子里渲染，`kubectl diff` 之前要先 `helm template`。

5. **「加文件即生效」已经由目录源解决**（见
   [manifests-directory-per-app](manifests-directory-per-app.md)），
   chart 想消除的样板问题在这里不存在。

### 评估过但否决的替代方案

- **chart 放 homelab 仓库本地目录**（绕开 sourceRepos 白名单）：只解决第 1 条，
  第 2–4 条原样保留，另外新增「不 `helm template` 就看不到实际清单」的调试成本。
- **只为 values 分层做 chart**（homelab / oracle 两套配置）：kustomize overlay 是这件事的
  直接答案，`backup/` 已是现成先例（`base` + `overlays/homelab` + `overlays/oracle`）。

### 什么时候该推翻这条

不写死，给触发条件：满足任一条就重新评估：

- 自研应用要被外部安装（公开发布给他人部署）：那时 chart 的价值是**分发格式**，
  不是本仓库的部署方式；两者可以并存。
- 同一自研应用要在 **3 个以上环境/集群**跑且 values 差异显著，kustomize overlay
  开始出现大段重复。
- 自研应用需要 chart 依赖管理（subchart 拉取 PG/Redis 之类）。

## 后果

- 新自研应用的落地路径固定：`k8s/helm/manifests/<app>/`（homelab）或
  `cloud/oracle/manifests/<app>/`（oracle），加 `argocd/applications/<app>.yaml`。
  `.claude/skills/add-service/SKILL.md` 已是这个流程，无需改动。
- 应用自己的仓库里**可以**放 `deploy/` 参照清单，但**真相源是 homelab 仓库**，
  ArgoCD 不指向应用仓库：否则就撞回第 1 条的 `sourceRepos` 陷阱。
- ⚠️ `k8s/helm/` 这个目录名是历史命名：它下面的 `manifests/` 与 Helm 无关。
  别因为路径里有 `helm` 就以为自研应用也该走 chart。
- 本决策**不影响**上游 chart 的用法：新增第三方组件照常
  remote chart + `$values/k8s/helm/values/<app>.yaml`，并记得把 chart 仓库加进
  `sourceRepos`（同样是手工 apply AppProject）。
