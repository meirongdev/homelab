# k3s 集群版本升级（两集群）

> Last updated: 2026-08-30
> Status: SOP —— **尚未整体执行过**。本文的兼容性判据、停机面、回滚点均在 2026-08-30
> 对着两个现网集群实测核对；升级动作本身待首次执行后回来补 §10 的实测记录。
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
> ☠️ **k3s 不支持"降级"**——回滚永远是回到快照/DB 副本，不是装个旧版本了事。

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

> 2026-08-30 的快照仅供理解形态：三节点全 `v1.34.5+k3s1`，stable 已 `v1.36.4+k3s1`。

## 2. 三条硬约束

**① ☠️ 不能跳 minor。** k3s 官方原话："Ensure that your plan does not skip intermediate
minor versions when upgrading"。1.34 → 1.36 是**两次**升级，中间必须在 1.35 上落地并验证。

**② 控制面必须先于 worker。** kubelet 不允许**新于** apiserver。homelab 是
`k8s-node`（server）+ `k8s-worker-106`（agent）：顺序永远是 server → agent。
worker 剧本里 `k3s_version` 的注释写的就是这条。

**③ ☠️ 不能降级。** 两集群的数据库都是 **SQLite/kine**（`/var/lib/rancher/k3s/server/db/state.db`，
2026-08-30 实测 homelab 142MB / oracle 179MB，同目录的 `etcd/` 里只有一个空的 `name` 文件）。
两个后果：

- **`k3s etcd-snapshot` 系列命令在这里全部不可用** —— 那是 etcd 后端专属的。
  别照抄网上以 etcd 为前提的 k3s 升级教程。
- 回滚只能靠**文件级/VM 级**的时间点副本（§5）。

## 3. 升级前的兼容性闸门

☠️ **这一节是流程，不是结论**。下表最右列是 2026-08-30 的核查结果，**每次升级前重跑一遍**——
组件在动，上游支持矩阵也在动。

| # | 查什么 | 怎么查 | 2026-08-30 |
|---|--------|--------|-----------|
| G1 | 目标版本的 **Urgent Upgrade Notes** | 读 `CHANGELOG-<minor>.md` 的该节（见下方命令）| 1.35 起 cgroup v1 由 warning 变**硬错**；1.35 移除 kubelet `--pod-infra-container-image` |
| G2 | **cgroup v2** | `stat -fc %T /sys/fs/cgroup/` → 必须 `cgroup2fs` | 三节点全通过 |
| G3 | **被移除的 kubelet flag** | `grep -A20 kubelet-arg /etc/rancher/k3s/config.yaml` | 三处均无被移除项 |
| G4 | **还在被请求的弃用 API** | 见下方 `apiserver_requested_deprecated_apis` | 仅 `endpoints v1`（`removed_release=""`，无移除计划），不阻塞 |
| G5 | **组件支持矩阵** | 见 §3.2 | ⚠️ **Kyverno 是天花板** |

### 3.1 G1/G4 的命令

```bash
# G1 —— 目标 minor 的 Urgent Upgrade Notes（把 1.35 换成目标 minor）
curl -sSL https://raw.githubusercontent.com/kubernetes/kubernetes/master/CHANGELOG/CHANGELOG-1.35.md \
  | awk '/^## Urgent Upgrade Notes/,/^## Changes by Kind/'
# k3s 自己的那层（打包的 containerd/runc/coredns/local-path 版本也在这里）
curl -sS https://api.github.com/repos/k3s-io/k3s/releases/tags/v1.35.8+k3s1 \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["body"])'

# G4 —— 谁还在请求弃用 API。空输出 = 干净；
# 有输出时看 removed_release：为空 = 尚无移除计划，填了版本号 = 那个版本会真删
for c in k3s-homelab oracle-k3s; do
  echo "--- $c"
  kubectl --context "$c" get --raw /metrics | grep '^apiserver_requested_deprecated_apis' || echo "(clean)"
done
```

⚠️ **G4 是抽样不是普查**：该指标只反映 apiserver **最近观测到的**请求。一个季度才跑一次的
CronJob 用了将被删的 API，扫的时候它不在场，指标就是干净的。清单侧再扫一遍别的形态：

```bash
# 1.36 的两个：gitRepo volume 被永久禁用（apiserver 仍收，kubelet 拒跑）、Service externalIPs 弃用
grep -rn "gitRepo:\|externalIPs:" --include="*.yaml" k8s/ cloud/ argocd/ backup/ zitadel/
```

### 3.2 G5 —— 组件支持矩阵（唯一真正会挡路的一格）

只列**会因 k8s 版本而拒绝工作或失去支持**的组件。查的是各上游自己的兼容表，不是猜的。

| 组件 | 在哪 | 怎么查 | 2026-08-30 结论 |
|---|---|---|---|
| **Cilium** | 两集群 1.20.0 | `docs.cilium.io/en/v<ver>/network/kubernetes/requirements/` | e2e 覆盖 k8s **1.33–1.36**，到 1.36 不挡路 |
| **Kyverno** | 仅 homelab 1.18.2 | `kyverno.io/docs/installation/releases/` | ⚠️ 唯一 supported release v1.19 只到 **k8s 1.35**；**1.36 无任何版本支持**（v1.20 预计 2026-11）|
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
版本不兼容时，**不会有任何东西报错或告警** —— 4 条 ClusterPolicy
（`disallow-latest-tag` / `require-probes` / `require-requests-limits` /
`restrict-image-registries`）只是悄悄不再生效。

这和 [2026-08-11 的 Gateway API CRD stall](../records/2026-08-11-gateway-api-crd-stall.md)
是同一类死法，验收方式也一样：**别看 pod 是不是 Running，要主动打一发该被拦的请求**（§9）。

**因此当前的结论是：可以升到 1.35，先别上 1.36。** 若确要上 1.36，得接受 Kyverno
处于未测试状态，并在 §9 里把策略生效验证当作每次必查项。

## 4. 停机面

| 动作 | 谁受影响 | 实测/预期 |
|---|---|---|
| 升 **oracle-k3s** | **ArgoCD 控制面**（GitOps 暂停）· ZITADEL（全站 SSO 登录）· Loki/Tempo（日志与追踪断档）· Calibre | 单节点，全集群短暂不可用 |
| 升 **homelab 控制面** | Vault（→ oracle 侧 ExternalSecret 报错）· Prometheus/Grafana/Alertmanager · 该节点上的全部应用 | 同上 |
| 升 **homelab worker** | jellyfin / navidrome / podcast（媒体）· external-dns · sloth · opencost | 可先 drain 迁走，控制面还在 |

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
可能是几十分钟）。**正确姿势是「谁要升，才停谁、才给谁做回滚点」** —— §6/§7/§8
每一节的开头都已经就地写好了。

### 5.1 两台 homelab VM —— `qm snapshot`

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

### 5.2 oracle-k3s —— 没有 VM 快照层，拷 DB

OCI 侧没有做 boot volume 备份策略，所以 oracle 的回滚点只能自己造：

```bash
ssh -i ~/.ssh/vgio ubuntu@100.107.166.37 '
  sudo systemctl stop k3s
  sudo mkdir -p /root/k3s-preupgrade
  sudo cp -a /var/lib/rancher/k3s/server/db/state.db* /root/k3s-preupgrade/
  sudo cp -a /usr/local/bin/k3s /root/k3s-preupgrade/k3s.old      # 装新版会覆盖，先留一份
  sudo ls -la /root/k3s-preupgrade/
'
```

☠️ **必须先 `stop k3s` 再拷**。SQLite 是 WAL 模式（目录里那个 `state.db-wal` 就是），
热拷贝三件套会拿到撕裂的状态。

> 真出不来的话还有第二层：oracle 全部 PVC 由 restic 夜备（03:30），重建路径见
> [oracle-k3s-rebuild.md](oracle-k3s-rebuild.md)。那是**重建**不是回滚，代价大得多。

## 6. 执行 A —— oracle-k3s（先升，当金丝雀）

先升 oracle 的理由：单节点、爆炸半径自包含、没有 Kyverno（少一个变量）、且有成型的重建 runbook。

```bash
ssh -i ~/.ssh/vgio ubuntu@100.107.166.37

# 单节点集群 drain 没有意义（无处可迁），而且 databases/apps-pg-primary 与
# zitadel/zitadel-pg-primary 两个 PDB 都是 minAvailable=1 / ALLOWED DISRUPTIONS=0，
# drain 一定卡死。直接停服务升级。
sudo systemctl stop k3s

# ★ 回滚点就在这里做（§5.2），停机窗口从这一刻才开始计
sudo mkdir -p /root/k3s-preupgrade
sudo cp -a /var/lib/rancher/k3s/server/db/state.db* /root/k3s-preupgrade/
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

## 7. 执行 B —— homelab 控制面 `k8s-node`

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

## 8. 执行 C —— homelab worker `k8s-worker-106`

**必须在 §7 通过之后**（约束 ②）。这台可以正经 drain，因为有控制面接着。

```bash
# 在笔记本上
kubectl --context k3s-homelab cordon k8s-worker-106
kubectl --context k3s-homelab drain k8s-worker-106 --ignore-daemonsets --delete-emptydir-data

# ★ 回滚点（§5.1）
ssh -i ~/.ssh/vgio ubuntu@192.168.50.107 'sudo systemctl stop k3s-agent && sudo sync'
ssh -i ~/.ssh/vgio root@100.110.27.111 \
  'qm snapshot 200 pre-k3s-upgrade --description "before k3s <目标版本>"'

# 在 worker 上
ssh -i ~/.ssh/vgio ubuntu@192.168.50.107
# K3S_URL / K3S_TOKEN 已持久化在 /etc/systemd/system/k3s-agent.service.env，无需重传
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=<目标版本> sh -s - agent
sudo systemctl status k3s-agent --no-pager

# 回笔记本
kubectl --context k3s-homelab uncordon k8s-worker-106
```

⚠️ drain 会把 `media` ns 的三个服务（jellyfin/navidrome/podcast）赶到控制面上，
它们挂着 106 的只读 NFS PV，控制面同样挂得上。`uncordon` 之后它们**不会自己回来**——
无所谓，下次重建自然回去；要立刻回去就 `kubectl -n media rollout restart deploy/<name>`。

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
cd cloud/oracle && just check-node-drift     # 配置有没有漂移 —— 重装二进制后正该查这个

# ④ 密钥链路（Vault 自动解封 + 两集群 ESO）
kubectl --context k3s-homelab -n vault exec vault-0 -- vault status | grep Sealed   # false
for c in k3s-homelab oracle-k3s; do kubectl --context "$c" get externalsecrets -A | grep -v SecretSynced; done
```

**⑤ Gateway API 控制器真的初始化了** —— 判据只有一个：**新建**一条 HTTPRoute 能不能拿到
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
>   "Gateway waiting for address"）—— oracle 禁了 servicelb、没有 LoadBalancer 给它派地址，
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
Kyverno 与 apiserver 不兼容时**不报错、不告警、pod 全 Running**，只是不再拦 ——
这条命令是唯一能看见它的地方。

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
  sudo rm -f /var/lib/rancher/k3s/server/db/state.db*
  sudo cp -a /root/k3s-preupgrade/state.db* /var/lib/rancher/k3s/server/db/
  sudo systemctl start k3s
'
```

☠️ **只装回旧二进制、不还原 DB 是错的**：新版 apiserver 可能已经改写过存储格式，
旧版本读它属于未定义行为。二进制与 DB 必须**成对**回到升级前。

回滚后**先把两集群 Cilium 的连通性看一遍**再宣布恢复：ClusterMesh 要求两端 Cilium 同版本，
而回滚不改 Cilium（它是 manual-helm，不随 k3s 走），所以这里通常没问题——
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

   跨了周末的分阶段升级（一侧已升、另一侧还没）在**先行那侧**行尾写豁免，别让 CI 长期挂红：

   ```yaml
   k3s_version: v1.35.8+k3s1  # version-pair-ok: 分阶段升级，oracle 先行，homelab <日期> 跟上
   ```

2. **删快照**：`qm delsnapshot 100 pre-k3s-upgrade`（pve）、`qm delsnapshot 200 pre-k3s-upgrade`（106）；
   oracle 上 `sudo rm -rf /root/k3s-preupgrade`。thin 快照留着会持续吃增量。

3. **回来补本文的 §3 表格**（新的兼容性核查结果）与 Status 行，并把踩到的坑写进
   [records/](../records/README.md)。

4. 若升级过程中把某个组件也升了（比如为过 Kyverno 那道闸而升到 v1.19），
   记得它多半是 GitOps 或 manual-helm 管的，按 [AGENTS.md](../../AGENTS.md) 的分工走。
