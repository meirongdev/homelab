# 孤儿资源监控：kor vs ArgoCD 原生 orphanedResources

> 日期: 2026-07-31
> 状态: 已实施

## 上下文

已有的例行体检覆盖了两类问题：trivy-operator 查**镜像/配置有漏洞**，OpenCost + KRR 查
**资源给多了**。缺的是第三类：**配置漂移** —— 集群里存在、但 Git 里没有的对象。

这类东西的具体危害在本仓库有先例：手动 `kubectl apply` 过、之后没补进 kustomization 的
ConfigMap，平时一切正常，只在**从 Git 重建集群**时暴露成缺依赖的启动失败。

评估了两个方向。注意它们找的是**相反**的东西，这是选型的关键：

| 工具 | 找什么 | 一句话 |
|---|---|---|
| [kor](https://github.com/yonahd/kor) | 在 Git 里、但没人引用 | "这个 ConfigMap 还有用吗" |
| ArgoCD `orphanedResources` | 在集群里、但不在 Git 里 | "这个东西谁部署的" |

## 决策一：否决 kor

在 `k3s-homelab` 实跑 kor v0.6.8（只读，未加 `--delete`）：**169 条 "unused"，逐条核实后
真正可动作的只有 1 条**（`argocd/argocd-initial-admin-secret`，bootstrap 残留），信噪比 0.6%。

噪音构成：

| 类别 | 条数 | 为何是误报 |
|---|---|---|
| CRD "no instances" | 60 | cilium/kyverno/ESO/trivy 的 chart 自带 CRD |
| Grafana dashboard ConfigMap | 40 | sidecar 靠 `LABEL=grafana_dashboard` 发现，不出现在任何 podspec 里 |
| ReplicaSet "not in use" | 20 | `revisionHistoryLimit` 的正常产物 |
| 控制器经 API 读的 Secret/ConfigMap | ~23 | 见下 |
| Job "has completed" | 12 | CronJob 的 `successfulJobsHistoryLimit` 保留窗口 |
| ClusterRoleBinding | 7 | **kor 自身 bug**：日志 `Failed to get clusterRoles: strconv.ParseBool: parsing "kyverno"`，它没能列出 ClusterRole 就断言"引用不存在"（`view` 明明存在） |

否决的决定性理由不是噪音量，而是**它判错的恰恰是最不能删的东西**：

- `argocd/argocd-secret`（server signature key）、`argocd/oracle-k3s-cluster`（oracle 外部集群凭据）
- `external-secrets/vault-token`（删了全部 ESO 停摆）
- `monitoring/alertmanager-kube-prometheus-stack-alertmanager`（Alertmanager 配置源）
- `monitoring/alertmanager-telegram` —— 它正被 `k8s/helm/manifests/krr.yaml` 的 CronJob 以
  `secretKeyRef` 引用；kor 不遍历 CronJob 的 podTemplate
- `opencost/custom-pricing-model` —— deploy 里有 `PRICING_CONFIGMAP_NAME` 环境变量指名读取；
  kor 只认 volume 挂载和 `envFrom`/`valueFrom`

共同根因：**kor 只做静态引用分析**，看不见控制器经 K8s API 按名字/按 label 读取的配置。而在
GitOps 集群里 `--delete` 本身就是反模式 —— selfHeal 会把删掉的弹回来，只留一次无意义抖动。

ArgoCD 的判定则天然跳过带 `ownerReferences` 的对象，ReplicaSet/Job/Pod 那一整类噪音根本不产生。

## 决策二：启用 ArgoCD `orphanedResources`，但 `warn: false`

配置在 `argocd/projects/homelab.yaml`（文件内有逐条注释）。

### 为什么关掉 warn

`orphanedResources.ignore` 的 schema 只有 `group`/`kind`/`name`，**没有 namespace 字段**
（已核 CRD）。而 `kube-system` / `monitoring` / `argocd` / `external-secrets` 四个 namespace 里的
组件（cilium+k3s / kube-prometheus-stack / ArgoCD 自身 / ESO operator）全是 manual-helm 装的，
按定义永远"无人认领"——实测贡献 **255 条不可屏蔽的结构性噪音**。

`warn: true` 会给 `loki`/`tempo`/`gateway`/`vault-eso` 等 App 常挂黄色告警条，复刻 trivy 那种
告警疲劳。`warn: false` 下孤儿仍在各 App 的资源树里可见，只是不产生 warning condition。

想要真告警，正确做法是把上述四个 ns 的 App 拆到独立 project（8 个 App 改 `spec.project`），
**而不是往 ignore 里堆东西**。目前未做。

### ignore 四条

| 条目 | 消掉 | 理由 |
|---|---|---|
| `Endpoints/*` | 50 | endpoints controller 为每个 Service 自动建，无 ownerRef、永不进 Git（EndpointSlice 有 ownerRef，已被自动排除） |
| `Secret/sh.helm.release.v1.*` | 34 | Helm 自己的 release 状态存档 |
| `Secret/kyverno-*.kyverno.svc.kyverno-tls-*` | 4 | cleanup-controller 运行时生成并轮转的自签 TLS |
| `PersistentVolumeClaim/data-trivy-server-0` | 1 | trivy-server StatefulSet 的 volumeClaimTemplate 产物 |

PVC **只豁免这一个具名对象、不豁免整类** —— 意外多出来的 PVC 正是最该被看见的孤儿
（参见 calibre PVC 的 `Prune=false` 保护）。

## 效果

按 ArgoCD 判定逻辑（App destination namespace 内 + 无 `argocd.argoproj.io/tracking-id` 注解
+ 无 ownerReferences）对活集群模拟，2026-07-31 实测：

```
380 条  裸判定
349 条  扣掉 ArgoCD 3 条内置豁免（default SA / kube-root-ca.crt / default ns 的 kubernetes svc）
260 条  应用上表 ignore 列表
  ├─ 255 条来自 4 个 manual-helm 的 infra ns —— warn:false，不告警
  └─   5 条来自 13 个 GitOps 自有 ns  ← 实际信号面
```

那 5 条：4 条是 `external-dns` 的 SA/Service/Deployment/ServiceMonitor（chart 本体是
manual-helm，设计如此，见 [`external-dns-adoption.md`](external-dns-adoption.md)），
1 条是 trivy 滞留的 Complete Job（已知问题，会占满 `concurrentLimit=1` 的槽）。

### 首批捞到的真问题

`k8s/helm/manifests/calibre-metadata/kustomization.yaml` 的 `resources:` 漏列了
`metadata-enrich.yaml`，而 `enrich-job.yaml` 要挂载它定义的 ConfigMap `metadata-enrich-script`。
线上那份是当年手动 `kubectl apply` 的残留（同 App 的 `ebook-metadata-script` 有 tracking-id
注解，它没有）—— 从 Git 重建集群时 `calibre-metadata-enrich` Job 会因缺 ConfigMap 起不来，
正落在 `runbooks/homelab-rebuild-ubuntu-24-04.md` 那条路径上。已在同批提交修复。

## 后果

- ⚠️ **AppProject 不归 `root` App 同步**（root 只 watch `argocd/applications/`），改完
  `argocd/projects/homelab.yaml` 必须手动 `kubectl apply -f`，同
  `k8s/helm/justfile` 的 `deploy-argocd` 配方
- 纯只读特性，不影响任何 App 的 sync 行为；回滚 = 删掉 `spec.orphanedResources` 块再 apply
- 新增 manual-helm 组件时，其 namespace 会带来一批新孤儿。若该 ns 的 App 在
  `homelab` project 内，属预期，无需处理
