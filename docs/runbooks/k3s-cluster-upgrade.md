# k3s 集群版本升级（两集群）

> Last updated: 2026-11-20
> Status: SOP：已按本文完整执行过三次（2026-09 三节点 v1.34.5+k3s1 → v1.35.8+k3s1；2026-11-19 补丁升到
> v1.35.10+k3s1；2026-11-20 minor 升到 v1.36.6+k3s1，§9 全部通过），顺序均为 oracle → homelab 控制面 → worker。
> 除 §10 回滚外，每条命令都是实跑验证过的：回滚命令从未真正执行过，2026-11-20 只做了静态核对，
> 并修掉了其中的 glob 提权 bug（见 §5.2）。
> 触发条件：要把 `k3s-homelab`（`k8s-node` + `k8s-worker-106`）或 `oracle-k3s` 升到新的
> k3s/Kubernetes 版本；或发现三处 `k3s_version` pin 与现网跑的版本对不上。
> 成功判定：三个节点 `kubectl get nodes` 全 `Ready` 且 `VERSION` 是目标版本 ·
> 两集群无 `CrashLoopBackOff`/非 `Completed` 的未就绪 pod ·
> `just argocd-status`（`cd k8s/helm`）全 Synced/Healthy ·
> `just clustermesh-status`（`cd cloud/oracle`）双集群 connected ·
> `kubectl --context k3s-homelab -n vault exec vault-0 -- vault status` 显示 `Sealed false` ·
> 新建一条 HTTPRoute 能拿到 `.status`（见 §9，Gateway API 是本仓库的头号静默失效点）。
> 回滚：见 §10。两台 homelab VM 走 `qm rollback`（lvm-thin 快照，已核实支持）；
> oracle 无 VM 快照层，走「重装旧版本二进制 + 还原 `state.db`」。
> ☠️ **k3s 不支持"降级"**。回滚永远是回到快照/DB 副本，不是装个旧版本了事。

## 1. 别抄结论：现状与目标都要现取

版本号每周都在动，本文**不写死任何目标版本**。

```bash
# 现网跑什么（三个节点）
kubectl --context k3s-homelab get nodes -o wide
kubectl --context oracle-k3s   get nodes -o wide

# 上游有什么（stable = latest；同时看清各 minor 线的最新补丁）
curl -sS https://update.k3s.io/v1-release/channels \
  | python3 -c 'import json,sys; [print(c["id"].ljust(14), c.get("latest")) for c in json.load(sys.stdin)["data"]]'

# 仓库里钉的是什么（三处必须一致，CI 强制）
grep -rn "k3s_version:" k8s/ansible/playbooks/ cloud/oracle/ansible/playbooks/
```

> ⚠️ 上面三条命令的输出才是判据。**别把版本号写进任何常青文档**。它每周都在动，
> 唯一可信的现状是 `kubectl get nodes` 与 update.k3s.io。

## 2. 三条硬约束

**① ☠️ 不能跳 minor。** k3s 官方原话："Ensure that your plan does not skip intermediate
minor versions when upgrading"。1.34 → 1.36 是**两次**升级，中间必须在 1.35 上落地并验证。

**② 控制面必须先于 worker。** kubelet 不允许新于 apiserver。homelab 是
`k8s-node`（server）+ `k8s-worker-106`（agent）：顺序永远是 server → agent。
worker 剧本里 `k3s_version` 的注释写的就是这条。

**③ ☠️ 不能降级。** 两集群的数据库都是 SQLite/kine（`/var/lib/rancher/k3s/server/db/state.db`，
2026-08-30 实测 homelab 142MB / oracle 179MB，同目录的 `etcd/` 里只有一个空的 `name` 文件）。
两个后果：

- **`k3s etcd-snapshot` 系列命令在这里全部不可用**。那是 etcd 后端专属的。
  别照抄网上以 etcd 为前提的 k3s 升级教程。
- 回滚只能靠**文件级/VM 级**的时间点副本（§5）。

## 3. 升级前的兼容性闸门

☠️ **这一节是流程，不是结论**。下表最右列是 2026-11-20（目标 1.36）的核查结果，**每次升级前重跑一遍**：
组件在动，上游支持矩阵也在动。

| # | 查什么 | 怎么查 | 2026-11-20 |
|---|--------|--------|-----------|
| G1 | 目标版本的 **Urgent Upgrade Notes** | 读 `CHANGELOG-<minor>.md` 的该节（见下方命令）| 1.36 只有 KCM 指标改名 `volume_operation_total_errors`→`volume_operation_errors_total`（本仓库无引用）与调度器插件 API 变更（不适用）；k3s 一层无 breaking |
| G2 | **cgroup v2** | `stat -fc %T /sys/fs/cgroup/` → 必须 `cgroup2fs` | 三节点全通过 |
| G3 | **被移除的 kubelet flag** | `grep -A20 kubelet-arg /etc/rancher/k3s/config.yaml` | 三处均无被移除项 |
| G4 | **还在被请求的弃用 API** | 见下方 `apiserver_requested_deprecated_apis` | 仅 `endpoints v1`（`removed_release=""`，无移除计划），不阻塞 |
| G5 | 组件支持矩阵（谁支持新版本）| 见 §3.2 | Kyverno v1.20 起支持到 1.37，天花板已解除（2026-11-19）|
| G6 | **谁把 k8s 版本当\*\*输入\*\***（与 G5 是两回事）| 见 §3.3 | ☠️ ZITADEL chart 命中；`tools.kubectl.image.tag` 钉在与集群同 minor 的 1.36.6（arm64 多架构已核）|

### 3.1 G1/G4 的命令

```bash
# G1 —— 目标 minor 的 Urgent Upgrade Notes（把 1.35 换成目标 minor）
curl -sSL https://raw.githubusercontent.com/kubernetes/kubernetes/master/CHANGELOG/CHANGELOG-1.35.md \
  | awk '/^## Urgent Upgrade Notes/,/^## Changes by Kind/'
# k3s 自己的那层（打包的 containerd/runc/coredns/local-path 版本也在这里）
curl -sS https://api.github.com/repos/k3s-io/k3s/releases/tags/v1.36.6+k3s1 \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["body"])'

# G4 —— 谁还在请求弃用 API。空输出 = 干净；
# 有输出时看 removed_release：为空 = 尚无移除计划，填了版本号 = 那个版本会真删
for c in k3s-homelab oracle-k3s; do
  echo "--- $c"
  kubectl --context "$c" get --raw /metrics | grep '^apiserver_requested_deprecated_apis' || echo "(clean)"
done
```

⚠️ **G4 是抽样不是普查**：该指标只反映 apiserver 最近观测到的请求。一个季度才跑一次的
CronJob 用了将被删的 API，扫的时候它不在场，指标就是干净的。清单侧再扫一遍别的形态：

```bash
# 1.36 的两个：gitRepo volume 被永久禁用（apiserver 仍收，kubelet 拒跑）、Service externalIPs 弃用
grep -rn "gitRepo:\|externalIPs:" --include="*.yaml" k8s/ cloud/ argocd/ backup/ zitadel/
```

### 3.2 G5：组件支持矩阵（唯一真正会挡路的一格）

只列**会因 k8s 版本而拒绝工作或失去支持**的组件。查的是各上游自己的兼容表，不是猜的。

| 组件 | 在哪 | 怎么查 | 2026-08-30 结论 |
|---|---|---|---|
| Cilium | 两集群 1.20.0 | `docs.cilium.io/en/v<ver>/network/kubernetes/requirements/` | e2e 覆盖 k8s 1.33–1.36，到 1.36 不挡路 |
| Kyverno | 仅 homelab（现 v1.20.0）| `kyverno.io/docs/installation/releases/` | v1.20（2026-11-12）支持 k8s v1.34–v1.37。⚠️ 升到 v1.20 要先把策略迁到 `policies.kyverno.io`，见下 |
| **CNPG** | 仅 oracle 1.30.0 | 版本发布公告 | 1.30 已加 1.36 支持 |
| ArgoCD / ESO / prometheus-operator / trivy-operator / tetragon / falco | 两集群 | 上游 release notes | 均无声明冲突 |

```bash
# 现网各组件实际版本（别信文档里的快照）
for c in k3s-homelab oracle-k3s; do
  echo "###### $c"
  kubectl --context "$c" get deploy,ds,sts -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{range .spec.template.spec.containers[*]}{.image}{" "}{end}{"\n"}{end}' \
    | grep -iE "cilium|kyverno|cloudnative|argocd|external-secrets|prometheus-operator|trivy|tetragon|falco" \
    | sed 's/@sha256:[a-f0-9]*//g' | sort
done
```

#### ☠️ Kyverno 越界的失败形态是**静默的**

`kyverno-resource-validating-webhook-cfg` 的 `failurePolicy` 是 **`Ignore`**（2026-08-30 实测），
符合 [security.md](../reference/security.md) 的 fail-open 设计。所以 Kyverno 与 apiserver
版本不兼容时，**不会有任何东西报错或告警**。4 条 ValidatingPolicy
（`disallow-latest-tag` / `require-probes` / `require-requests-limits` /
`restrict-image-registries`）只是悄悄不再生效。

这和 [2026-08-11 的 Gateway API CRD stall](../records/2026-08-11-gateway-api-crd-stall.md)
是同一类死法，验收方式也一样：**别看 pod 是不是 Running，要主动打一发该被拦的请求**（§9）。

**结论（2026-11-19）：Kyverno 已升到 v1.20（支持 k8s 1.34–1.37），可以上 1.36。**
升 Kyverno 本身有三个坑，下次再升大版本照此排雷：

- ☠️ **v1.20 不再执行 legacy `kyverno.io` 策略**（`ClusterPolicy`/`Policy`/`CleanupPolicy`/
  `ClusterCleanupPolicy`/`PolicyException`），源码里的准入路径已删；chart 3.10 在集群里还有 legacy
  对象时直接拒绝升级（render-time `lookup` + pre-upgrade hook Job `kyverno-check-legacy-policies`）。
  升前先清零：`for k in clusterpolicies policies cleanuppolicies clustercleanuppolicies policyexceptions;
  do kubectl --context k3s-homelab get $k.kyverno.io -A --no-headers | wc -l; done` 全为 0。
  迁移做法见 [security.md](../reference/security.md) §5.2：并跑、逐资源对比两个 source 的
  PolicyReport、再切换；`objectSelector` 后台扫描不认，排除对象要再写 `matchConditions`。
- ⚠️ **升大版本后重新列一遍 webhook 的 failurePolicy**，别假设还是全 `Ignore`：v1.20 新增了
  fail-closed 的 `protect-generation-labels`，已用 `features.protectGenerationLabels.enabled=false` 关掉
  （见 `k8s/helm/values/kyverno.yaml`）。
- 每次升完照 §9 ⑥ 主动打被拦请求，另加一条「不该被拦」的对照（合规 Pod、kube-system 里的 `:latest`），
  只验「被拦」放过不了写得过宽的策略。

### 3.3 G6：谁把 k8s 版本当**输入**

☠️ **这一格最容易漏，且漏了会直接打掉线上服务。**

G5 问的是「组件**支不支持**新版本」，G6 问的是完全不同的另一件事：
**「有没有组件把集群的 k8s 版本读出来，拿去拼别的东西」**。后者不出现在任何
支持矩阵里，升级前也不会有任何告警。

典型形态（ZITADEL chart，本仓库实际命中过）：`tools.kubectl.image.tag` 默认留空，
语义是「自动取集群的 k8s 版本」，于是集群一升到 vX.Y.Z，它就去拉
`docker.io/alpine/k8s:X.Y.Z`，而这个镜像的 tag 是人工发布的，**跟不上 k8s
的补丁节奏**，集群的补丁版本往往还没有对应 tag。链条是：

```
拉不到镜像 → setup Job 失败 → 它是 pre-upgrade hook → helm 回滚整个 release
           → zitadel / zitadel-login 两个 Deployment 被拆掉 → auth 域名 500
```

⚠️ **发作时机在升级"成功"之后几分钟**：节点 Ready、`k3s --version` 正确、pod 数
也已复原，helm-controller 才慢一步重新 reconcile。**「升完看一眼节点就收工」会
完美错过它**：必须跑完 §9 的 ② 才算验收。

**怎么查**（没有一劳永逸的静态办法，三条一起用）：

```bash
# ① 哪些 chart 由 k3s helm-controller 管（k3s 重启就会重新 reconcile，风险最高）
for c in k3s-homelab oracle-k3s; do echo "--- $c"; kubectl --context "$c" get helmchart -A; done

# ② chart 模板里有没有读 KubeVersion（对每个 helm 型 App 渲一遍看可疑镜像 tag）
helm template <release> <chart> --version <ver> --repo <repo> -f <values> \
  | grep -E "image:" | sort -u
# ③ 上游 values 里搜「默认跟随集群版本」的说明
helm show values <chart> --version <ver> --repo <repo> | grep -iB3 "cluster version"
```

**发现了就显式钉死**，别留空。本仓库已钉的一处：
`cloud/oracle/manifests/zitadel/zitadel.yaml` 的 `tools.kubectl.image.tag`
（⚠️ oracle 是 arm64，换 tag 前确认该 tag 是多架构 manifest list；
kubectl 与集群同 minor 即可，所以只有升 minor 时才需要动它）。

> 普查现状：**homelab 一个 HelmChart CR 都没有**（`No resources found`），
> 这条路径只在 oracle 上存在，且只剩 zitadel 一个。⚠️ 但 ArgoCD 渲染 Helm chart
> 时同样会把集群版本传给模板，所以不能只查 helm-controller：§9 ② 那条
> 「升完立刻查未就绪 pod」才是兜底。

## 4. 停机面

| 动作 | 谁受影响 | 实测/预期 |
|---|---|---|
| 升 **oracle-k3s** | ArgoCD 控制面（GitOps 暂停）· ZITADEL（全站 SSO 登录）· Loki/Tempo（日志与追踪断档）· Calibre | 单节点，全集群短暂不可用 |
| 升 **homelab 控制面** | Vault（→ oracle 侧 ExternalSecret 报错）· Prometheus/Grafana/Alertmanager · 该节点上的全部应用 | 同上 |
| 升 **homelab worker** | jellyfin / navidrome / podcast（媒体）· external-dns · sloth · opencost · cf-analytics-exporter | ☠️ 这些**硬钉在 worker 上、迁不走**，drain 只会让它们 Pending，停机时长 = 整个 worker 升级窗口，见 §8 陷阱 ② |

三条已知的连带反应，**都是预期内、不要去修**：

- **oracle 侧 ExternalSecret 会 Degraded**：Vault 在 homelab，homelab 一停，跨集群读它的
  ExternalSecret 就失败，ArgoCD 把对应 App 标 Degraded。Vault 回来后自愈
  （[proxmox-host-upgrade.md](proxmox-host-upgrade.md) 2026-08-29 实测约 10s 内全部回 Healthy）。
- **Vault 会自己解封**：`vault/Secret/vault-auto-unseal` 的 lifecycle hook 负责，不需要人工
  `just vault-unseal`。判据是 `vault status` 的 `Sealed false`，不是"pod Running"。
- **GitOps 停摆期间 git push 不会丢**：ArgoCD 3 分钟轮询，控制面回来后自己追上。

## 5. 回滚点怎么做（本节是**参考**，动作在 §6–§8 里就地执行）

☠️ **不要在这里把三台的回滚点一次做完**。每台的回滚点都要求先 `stop k3s`，一次做完
= homelab 从这一刻起一直停到 oracle 升完并验收完（§6 要求在那里停下来跑全套验收，
可能是几十分钟）。**正确姿势是「谁要升，才停谁、才给谁做回滚点」**：§6/§7/§8
每一节的开头都已经就地写好了。

### 5.1 两台 homelab VM：`qm snapshot`

两台的磁盘都在 **lvm-thin**（`local-lvm`），支持快照，2026-08-30 核实容量充足
（pve 剩 242G / 106 剩 129G，thin 快照只占增量）。

```bash
# ① 先在**节点上**停 k3s 并把脏页刷到虚拟磁盘（qm snapshot 不带 --vmstate 是纯磁盘快照，
#    OS 页缓存里没落盘的东西不会进快照）
ssh -i ~/.ssh/vgio ubuntu@10.10.10.10 'sudo systemctl stop k3s && sudo sync'

# ② 再在**宿主上**打快照。k8s-node = pve(192.168.50.4) 的 VM 100
ssh -i ~/.ssh/vgio root@192.168.50.4 \
  'qm snapshot 100 pre-k3s-upgrade --description "before k3s <目标版本>"'

# worker 同理：k8s-worker-106 = 106 的 VM 200（VM 名仍叫 k3s-exp，是历史名，别改）
ssh -i ~/.ssh/vgio ubuntu@192.168.50.107 'sudo systemctl stop k3s-agent && sudo sync'
ssh -i ~/.ssh/vgio root@100.110.27.111 \
  'qm snapshot 200 pre-k3s-upgrade --description "before k3s <目标版本>"'
```

> ⚠️ 快照**不是**周备的替代，也别长期留着（thin 卷会持续吃增量）。升级验收通过后
> `qm delsnapshot <vmid> pre-k3s-upgrade` 删掉。
> 兜底还有周备：pve VM100 周日 03:30 / 106 VM200 周日 05:00（`keep-last=3`）。

### 5.2 oracle-k3s：没有 VM 快照层，拷 DB

OCI 侧没有做 boot volume 备份策略，所以 oracle 的回滚点只能自己造：

```bash
ssh -i ~/.ssh/vgio ubuntu@100.107.166.37 '
  sudo systemctl stop k3s
  sudo mkdir -p /root/k3s-preupgrade
  sudo bash -c "cp -a /var/lib/rancher/k3s/server/db/state.db* /root/k3s-preupgrade/"
  sudo cp -a /usr/local/bin/k3s /root/k3s-preupgrade/k3s.old      # 装新版会覆盖，先留一份
  sudo ls -la /root/k3s-preupgrade/
'
```

☠️ **glob 必须交给 root 的 shell 展开（`sudo bash -c "…"`）**：`server/db/` 与 `/root` 都是 root 专属，
普通用户的 shell 展开不了 `state.db*`，`sudo cp` 收到字面量报 `cannot stat`（而且此时 k3s 已停，
`set -e` 脚本会把集群留在停机状态），`sudo rm -f` 则是**静默什么都不删**（§10 的回滚同理）。

☠️ **必须先 `stop k3s` 再拷**。SQLite 是 WAL 模式（目录里那个 `state.db-wal` 就是），
热拷贝三件套会拿到撕裂的状态。

> 真出不来的话还有第二层：oracle 全部 PVC 由 restic 夜备（03:30），重建路径见
> [oracle-k3s-rebuild.md](oracle-k3s-rebuild.md)。那是**重建**不是回滚，代价大得多。

## 6. 执行 A：oracle-k3s（先升，当金丝雀）

先升 oracle 的理由：单节点、爆炸半径自包含、没有 Kyverno（少一个变量）、且有成型的重建 runbook。

```bash
ssh -i ~/.ssh/vgio ubuntu@100.107.166.37

# 单节点集群 drain 没有意义（无处可迁），而且 databases/apps-pg-primary 与
# zitadel/zitadel-pg-primary 两个 PDB 都是 minAvailable=1 / ALLOWED DISRUPTIONS=0，
# drain 一定卡死。直接停服务升级。
sudo systemctl stop k3s

# ★ 回滚点就在这里做（§5.2），停机窗口从这一刻才开始计
sudo mkdir -p /root/k3s-preupgrade
sudo bash -c "cp -a /var/lib/rancher/k3s/server/db/state.db* /root/k3s-preupgrade/"
sudo cp -a /usr/local/bin/k3s /root/k3s-preupgrade/k3s.old

# 全部启动参数都在 /etc/rancher/k3s/config.yaml 里，安装脚本会自己读，无需重传 flag
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=<目标版本> sh -s -

sudo systemctl status k3s --no-pager
```

回到笔记本验收后再往下：

```bash
kubectl --context oracle-k3s get nodes -o wide          # VERSION 已是目标版本、Ready
kubectl --context oracle-k3s get pods -A --no-headers \
  | awk '$4!="Completed"{split($3,a,"/"); if(a[1]!=a[2]) print}'   # 应为空
```

⚠️ **在这里停下来，跑完 §9 的全套验收再动 homelab。** 金丝雀的意义就是让问题只发生在一侧。

## 7. 执行 B：homelab 控制面 `k8s-node`

```bash
# 先把 worker 上的负载保住：控制面重启期间 worker 会 NotReady，但 pod 不会被驱逐
# （控制面不在就没人驱逐）。不需要 drain worker。

# ★ 回滚点（§5.1）—— 停机窗口从这一刻才开始计
ssh -i ~/.ssh/vgio ubuntu@10.10.10.10 'sudo systemctl stop k3s && sudo sync'
ssh -i ~/.ssh/vgio root@192.168.50.4 \
  'qm snapshot 100 pre-k3s-upgrade --description "before k3s <目标版本>"'

ssh -i ~/.ssh/vgio ubuntu@10.10.10.10
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=<目标版本> sh -s -
sudo systemctl status k3s --no-pager
```

☠️ **两个 homelab 专属陷阱**：

- **`protect-kernel-defaults: true`**：k3s 会**拒绝启动**在 sysctl 不达标的内核上。
  这些值来自 `/etc/sysctl.d/31-k8s-protect-kernel.conf`，升级不动它，但如果启动失败
  且日志是 sysctl 相关，去 [security-hardening.md](security-hardening.md) 复核，
  别怀疑版本。
- **`vault` PDB 是 `maxUnavailable: 0`（ALLOWED DISRUPTIONS = 0）**：真要 drain 本节点
  的话会**永久卡在 Vault 上**。单节点控制面本来也无处可迁，所以本流程不 drain；
  万一有别的原因必须 drain，用 `kubectl drain … --disable-eviction`（走 delete 而非
  eviction，绕开 PDB）。

## 8. 执行 C：homelab worker `k8s-worker-106`

**必须在 §7 通过之后**（约束 ②）。这台可以正经 drain，因为有控制面接着。

```bash
# 在笔记本上
kubectl --context k3s-homelab cordon k8s-worker-106
kubectl --context k3s-homelab drain k8s-worker-106 --ignore-daemonsets --delete-emptydir-data

# ★ 回滚点（§5.1）
ssh -i ~/.ssh/vgio ubuntu@192.168.50.107 'sudo systemctl stop k3s-agent && sudo sync'
ssh -i ~/.ssh/vgio root@100.110.27.111 \
  'qm snapshot 200 pre-k3s-upgrade --description "before k3s <目标版本>"'

# 在笔记本上（不要登进 worker 里跑）。token 走 stdin 管道，不进任何进程的 argv
# （Tetragon 会把 argv 写进 Loki）。☠️ **必须重传 K3S_URL / K3S_TOKEN**，见下方陷阱 ①
# ⚠️ 把这些步骤写成脚本时，除这一条（要用 stdin 传 token）外的 ssh 都加 `-n`：
#    ssh 默认读 stdin，会把脚本剩下的内容吞掉，表现为「执行到一半悄悄停了、k3s 已 stop 却没装」。
ssh -n -i ~/.ssh/vgio ubuntu@10.10.10.10 'sudo cat /var/lib/rancher/k3s/server/node-token' \
 | ssh -i ~/.ssh/vgio ubuntu@192.168.50.107 'read -r T
     curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=<目标版本> K3S_URL=https://10.10.10.10:6443 K3S_TOKEN="$T" sh -s - agent
     sudo systemctl status k3s-agent --no-pager'

# 回笔记本
kubectl --context k3s-homelab uncordon k8s-worker-106
```

### ☠️ 陷阱 ①：安装脚本会**清空** agent 的 env 文件

**不重传就是 agent 拒启，没有中间状态。** 装完日志里那行

```
[INFO]  env: Creating environment file /etc/systemd/system/k3s-agent.service.env
```

不是"沿用"，是重新生成：用当前 shell 环境覆盖。升级时若没把 `K3S_URL` /
`K3S_TOKEN` 重新传进去，这个文件会变成**空的**，然后：

```
level=fatal msg="Error: --server is required"
Job for k3s-agent.service failed because the control process exited with error code.
```

☠️ **别想当然地以为"已经 join 过就不用再给 token"**：server 端的
`config.yaml` 会被保留，但 agent 的 join 参数只活在这个 env 文件里，装一次冲一次。

**已经踩了怎么救**（不必回滚，token 直接管道过去、不落盘不进历史）：

```bash
ssh -i ~/.ssh/vgio ubuntu@10.10.10.10 'sudo cat /var/lib/rancher/k3s/server/node-token' \
 | ssh -i ~/.ssh/vgio ubuntu@192.168.50.107 'read -r T
     printf "K3S_TOKEN=%s\nK3S_URL='"'"'https://10.10.10.10:6443'"'"'\n" "$T" \
       | sudo tee /etc/systemd/system/k3s-agent.service.env >/dev/null
     sudo chmod 600 /etc/systemd/system/k3s-agent.service.env'
ssh -i ~/.ssh/vgio ubuntu@192.168.50.107 'sudo systemctl daemon-reload && sudo systemctl start k3s-agent'
```

### ☠️ 陷阱 ②：drain 不会把这些服务"迁到控制面"，只会让它们 Pending

worker 上这几个 Deployment 全部**硬钉**在本节点：

```yaml
nodeSelector: {kubernetes.io/hostname: k8s-worker-106}
```

`jellyfin` · `navidrome` · `podcast` · `external-dns` · `sloth` · `opencost`
（外加 `cf-analytics-exporter`）。drain 把它们赶下来之后**无处可去**，症状是

```
0/2 nodes are available: 1 node(s) didn't match Pod's node affinity/selector,
1 node(s) were unschedulable.
```

所以 **drain 不是"平滑迁移"，是"这些服务开始停机"**，停机时长 = 整个 worker
升级窗口，直到 `uncordon`。计划维护窗口时按这个算，别按"迁走了就没事"算。
（好消息是 `uncordon` 之后它们会自己回来，不需要 `rollout restart`。）

> 为什么钉死：媒体三件套要就近读 106 的 ZFS（worker VM 就跑在 106 上），
> 其余几个是刻意从热控制面挪开。→ [ADR](../decisions/storage106-as-homelab-worker.md)

## 9. 验收

前四条是常规的，第五、六条是**本仓库特有的静默失效点，必须主动打请求验证**。

```bash
# ① 三节点版本与就绪
kubectl --context k3s-homelab get nodes -o wide
kubectl --context oracle-k3s   get nodes -o wide

# ② 无未就绪 pod（两集群都应为空）
for c in k3s-homelab oracle-k3s; do
  echo "--- $c"
  kubectl --context "$c" get pods -A --no-headers \
    | awk '$4!="Completed"{split($3,a,"/"); if(a[1]!=a[2]) print}'
done

# ③ GitOps 与跨集群
cd k8s/helm     && just argocd-status        # 全 Synced/Healthy，条数对 ls argocd/applications/*.yaml | wc -l
cd cloud/oracle && just clustermesh-status   # 双集群 connected
cd cloud/oracle && just verify-node          # oracle 只读不变量（报几条是动态的，别写死）
cd cloud/oracle && just check-node-drift     # 配置有没有漂移 —— 重装二进制后正该查这个。基线 changed=1：config.yaml 的 tls-san（模板刻意不含 OCI 公网 IP，现网文件里还有）；若多出 panic_on_oops 那项，见 ⑦

# ④ 密钥链路（Vault 自动解封 + 两集群 ESO）
kubectl --context k3s-homelab -n vault exec vault-0 -- vault status | grep Sealed   # false
for c in k3s-homelab oracle-k3s; do kubectl --context "$c" get externalsecrets -A | grep -v SecretSynced; done
```

**⑤ Gateway API 控制器真的初始化了**，判据只有一个：新建一条 HTTPRoute 能不能拿到
`.status`。旧路由 curl 200 **不是证据**（08-11 瘫了 30 小时期间旧路由一直是 200），
`kubectl get gateway` 也**不是**（Gateway 对象的 status 是上次写的，会一直挂着）。

```bash
# 金丝雀路由：hostname 刻意不在 meirong.dev 下 —— external-dns 的 --domain-filter=meirong.dev
# 会忽略它，不会建出 DNS 记录（且它是 --policy=upsert-only，建了也删不掉）
canary() {
  local ctx=$1 gw=$2
  kubectl --context "$ctx" apply -f - <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: gwapi-canary, namespace: kube-system}
spec:
  parentRefs: [{name: $gw, namespace: kube-system}]
  hostnames: ["gwapi-canary.invalid"]
  rules: [{matches: [{path: {type: PathPrefix, value: /}}]}]
YAML
  sleep 4
  kubectl --context "$ctx" -n kube-system get httproute gwapi-canary \
    -o jsonpath='{range .status.parents[*]}{.controllerName}{"  "}{range .conditions[*]}{.type}={.status}{" "}{end}{"\n"}{end}'
  kubectl --context "$ctx" -n kube-system delete httproute gwapi-canary
}
canary k3s-homelab homelab-gateway
canary oracle-k3s   oracle-gateway
```

**期望**（2026-08-30 在两集群实测过，升级前的基线就是这个）：

```
io.cilium/gateway-controller  Accepted=True ResolvedRefs=True
```

☠️ **输出为空 = 控制器没在工作**，八成是 Gateway API CRD 与 Cilium 版本对不上
（[V3 检查](../reference/manifest-safety-checks.md)、`just deploy-gateway-api-crds`）。

> ⚠️ **两条会被误判成"升坏了"的既有基线，先记下来**（都在 2026-08-30、升级前就是这样）：
> - `oracle-gateway` 的 `PROGRAMMED` 一直是 **False**（`reason=AddressNotAssigned`,
>   "Gateway waiting for address"）。oracle 禁了 servicelb、没有 LoadBalancer 给它派地址，
>   而入口流量走 Cloudflare Tunnel 直接进 Service，不依赖这个地址。**86 天来一直如此，
>   不是升级造成的。** homelab 侧是 `True`（地址 `10.10.10.10`）。
> - `cilium-operator` 日志里**没有** `Required GatewayAPI resources` 这句
>   （Cilium 1.20 的日志格式已变，只有 `--enable-gateway-api='true'` 这类启动参数行）。
>   AGENTS.md 里那句"验收看 operator 日志"是旧版本的判据，**现在 grep 它两集群都是空的**，
>   照抄会自己吓自己。以本节的金丝雀为准。

**⑥ Kyverno 策略还在拦**（仅 homelab；G5 判定越界时更要查）。`--dry-run=server` 走完整准入
链但不落地，不会真建出 Pod：

```bash
kubectl --context k3s-homelab -n default run kyverno-canary \
  --image=nginx:latest --dry-run=server
```

**期望**（2026-08-30 实测的升级前基线）：

```
resource Pod/default/kyverno-canary was blocked due to the following policies
disallow-latest-tag:
  validate-image-tag-not-latest: 'validation error: 禁止使用 :latest tag…'
```

☠️ **"建得成"就是失效了**。webhook 是 `failurePolicy: Ignore`（fail-open），
Kyverno 与 apiserver 不兼容时**不报错、不告警、pod 全 Running**，只是不再拦：
这条命令是唯一能看见它的地方。

**⑦ oracle 的 `kernel.panic_on_oops` 还是 0。** kubelet 在 `protect-kernel-defaults` 关着时，**每次启动都会把
它写回 1**（同时写 `kernel.panic=10`），盖掉 `/etc/sysctl.d/99-panic-on-oops.conf`。oracle 没开
`protect-kernel-defaults`（homelab 两台开了，所以不受影响），于是每次 k3s 重启都会把 AppArmor `af_unix`
oops 的「硬重启」重新武装起来（[复盘](../records/2026-09-01-oracle-apparmor-af-unix-panic.md)）。
`check-node-drift` 会报出来，但不看就等于没防：

```bash
ssh -n -i ~/.ssh/vgio ubuntu@100.107.166.37 'sysctl kernel.panic_on_oops'   # 必须是 0
ssh -n -i ~/.ssh/vgio ubuntu@100.107.166.37 'sudo sysctl -w kernel.panic_on_oops=0'   # 不是 0 就立刻改回
```

**⑧ k3s 没顺手升 Gateway API CRD。** k3s 的发布说明里常有「Bump gateway-api」，那是随 Traefik 一起打包的；
本仓库两集群都 `disable: traefik`，所以不该有影响，但这类 CRD 版本漂移正是头号静默失效点，升完照样核一遍：

```bash
for c in k3s-homelab oracle-k3s; do kubectl --context $c get crd -o json | python3 -c '
import json,sys,collections
print(dict(collections.Counter(x["metadata"].get("annotations",{}).get("gateway.networking.k8s.io/bundle-version","?")
  for x in json.load(sys.stdin)["items"] if x["spec"]["group"]=="gateway.networking.k8s.io")))'; done   # 期望只有 v1.6.1
```

## 10. 回滚

判据：§9 任一条不过且十几分钟内定位不到原因，就回滚，别在生产上调试。

| 目标 | 怎么回 |
|---|---|
| `k8s-node` | 在 pve：`qm rollback 100 pre-k3s-upgrade`（会关机回滚再开机） |
| `k8s-worker-106` | 在 106：`qm rollback 200 pre-k3s-upgrade` |
| `oracle-k3s` | 见下 |

```bash
# oracle：重装旧版本二进制 + 还原 §5.2 拷下的 state.db
ssh -i ~/.ssh/vgio ubuntu@100.107.166.37 '
  sudo systemctl stop k3s
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=<升级前的版本> INSTALL_K3S_SKIP_START=true sh -s -
  sudo bash -c "rm -f /var/lib/rancher/k3s/server/db/state.db*"
  sudo bash -c "cp -a /root/k3s-preupgrade/state.db* /var/lib/rancher/k3s/server/db/"
  sudo systemctl start k3s
'
```

☠️ **只装回旧二进制、不还原 DB 是错的**：新版 apiserver 可能已经改写过存储格式，
旧版本读它属于未定义行为。二进制与 DB 必须**成对**回到升级前。

回滚后**先把两集群 Cilium 的连通性看一遍**再宣布恢复：ClusterMesh 要求两端 Cilium 同版本，
而回滚不改 Cilium（它是 manual-helm，不随 k3s 走），所以这里通常没问题：
但要用 `just clustermesh-status` 确认，不要假设。

## 11. 收尾（做完才算完）

1. **改三处 `k3s_version` pin**，一次改齐：

   ```
   k8s/ansible/playbooks/setup-k3s.yaml            # homelab 控制面
   k8s/ansible/playbooks/setup-k3s-worker.yaml     # homelab worker
   cloud/oracle/ansible/playbooks/setup-k3s.yaml   # oracle
   ```

   ⚠️ **升完节点再改，不是先改再升**：这三个值描述的是「现网正在跑什么」，
   它们唯一的消费者是**重建节点**时的 `INSTALL_K3S_VERSION`。指向一个还没升到的版本 =
   重建出来的节点和集群其余部分不是一个 minor。

   ```bash
   uv run --with pyyaml python scripts/check-version-pairs.py   # V2 组 k3s_version 强制三处一致
   ```

   ⚠️ **还有第四处不在 V2 里**：`scripts/render-manifests.py` 的 `KUBE_VERSION`（CI 的 render 任务用它做 schema
   校验与 `helm --kube-version`）。上次补丁升级就漏改了它。改之前确认 kubeconform 有该版本的 schema：
   `curl -sI https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/v<版本>-standalone-strict/pod-v1.json`。

   跨了周末的分阶段升级（一侧已升、另一侧还没）在**先行那侧**行尾写豁免，别让 CI 长期挂红：

   ```yaml
   k3s_version: v1.35.8+k3s1  # version-pair-ok: 分阶段升级，oracle 先行，homelab <日期> 跟上
   ```

2. **删快照**（等至少一轮夜间 restic（02:00/03:00/03:30 UTC）在新版本上跑成功再删：回滚点是唯一能回到升级前的东西，不必抢在验收当晚删）：`qm delsnapshot 100 pre-k3s-upgrade`（pve）、`qm delsnapshot 200 pre-k3s-upgrade`（106）；
   oracle 上 `sudo rm -rf /root/k3s-preupgrade`。thin 快照留着会持续吃增量。

3. **回来补本文的 §3 表格**（新的兼容性核查结果）与 Status 行，并把踩到的坑写进
   [records/](../records/README.md)。

4. 若升级过程中把某个组件也升了（比如为过 Kyverno 那道闸而升到 v1.19），
   记得它多半是 GitOps 或 manual-helm 管的，按 [AGENTS.md](../../AGENTS.md) 的分工走。
