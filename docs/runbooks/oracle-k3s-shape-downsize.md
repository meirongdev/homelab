# oracle-k3s 缩容到 2 OCPU / 12GB

> Last updated: 2026-08-05
> Status: 生效事实 + 切换 SOP
> 触发条件：需要改 `VM.Standard.A1.Flex` 的 shape（vendor 回收额度、腾额度开第二台、
> 或事后要涨回去）。任何改 `ocpus` / `memory_gb` 的动作都走本文。
> 成功判定：`kubectl --context oracle-k3s get pods -A | grep -v Running` 只剩
> Completed 的 Job；`describe node` 的 CPU requests < 80%；节点 `hugepages-2Mi: 0`。

## 为什么不能直接改 tfvars 就 apply

2026-08-05 缩容前实测，直接减半会撞两堵墙：

| 墙 | 数字 | 后果 |
|---|---|---|
| CPU requests 装不下 | 2712m requests vs 新 allocatable 2000m | 约 700m 的 pod **永久 Pending**，且是随机哪几个 |
| 内存 allocatable 低于实际峰值 | allocatable 9.7GiB vs 30d 峰值 used 10.2GiB | 一开机就进 kubelet 驱逐 / 内核 OOM |

两堵墙都不是"用量太大"，是**账记错了**：

- CPU 真实用量 p95 **0.52 核** / p99 0.79 / 30d 峰值 1.92 核。2712m 是 ~40 个 pod
  每个 50–100m 样板值堆出来的，跟实际消耗无关。
- 那 10.2GiB 里有 **2GiB 是从没被用过的 hugepages**（OCI Ubuntu 镜像带的 microk8s
  装机残留 `/etc/sysctl.d/20-microk8s-hugepages.conf`，本机跑 k3s）。扣掉后真实
  需求峰值 8.2GiB。
- 另有 **2.3GiB 调度器看不见**：k3s-server 进程 RSS 2021Mi + containerd 240Mi，
  而节点此前**一条 `system-reserved` 都没配**（capacity−allocatable 的差额恰好等于
  hugepages，说明 kubelet 认为整机内存全可分给 pod）。

## 缩容后的账（2 OCPU / 12GB）

| 项 | 值 |
|---|---|
| capacity | 2000m / ~11985Mi |
| system-reserved | 200m / 2560Mi |
| eviction-hard | memory.available<500Mi |
| **allocatable** | **1800m / ~8925Mi** |
| CPU requests 合计 | **1372m（76%）**，CronJob 峰值另计 ~200m ← 缩容当时的快照，会随新负载上涨（2026-08-06 已 1477m/82%） |
| 内存 requests 合计 | ~5800Mi（65%） |
| 内存实际峰值（pod 部分） | ~6.0GiB |

## 前置改动（必须先全部生效，再动 shape）

| # | 改什么 | 在哪 | 怎么生效 |
|---|--------|------|---------|
| 1 | CPU requests 2712m → **1372m**（43 处） | `cloud/oracle/manifests/**`、`k8s/helm/values/{loki,tempo,falco,cnpg-operator,opencost-oracle,trivy-operator-oracle}.yaml` | `git push` → ArgoCD |
| 2 | argocd-server 50→25m、argocd-redis 25→15m | `k8s/helm/values/argocd.yaml` | **`cd k8s/helm && just deploy-argocd`**（manual-helm，push 不生效） |
| 3 | `bulk`(-10) PriorityClass + 9 个可牺牲应用挂上 | `cloud/oracle/manifests/base/priorityclasses.yaml` 等 | `git push` → ArgoCD |
| 4 | LimitRange `defaultRequest.cpu` 50m→15m | `cloud/oracle/manifests/personal-services/personal-services-limits.yaml` | `git push`（**要重建 timeslot pod 才吃到新默认值**） |
| 5 | 清 hugepages + 配 `system-reserved`/`eviction-hard` | `cloud/oracle/ansible/playbooks/setup-k3s.yaml` | 见下面步骤 2 |

### 关于优先级分档

`critical`(1000) ArgoCD 全家 + zitadel-pg ·
`high`(900) cloudflared / external-dns / otel-collector ·
`(0)` 其余含 **ZITADEL 应用本身** · `bulk`(-10) calibre-web / bentopdf /
squoosh / it-tools / excalidraw×2 / trends / karakeep / rsshub-browserless。

⚠️ **ZITADEL 应用设不了 priorityClassName**：chart 9.34.1 没有这个 values 键（逐键
确认过），写进 `valuesContent` 会被静默忽略——比不配更糟，因为看起来像配了。
它留在 0，靠 `bulk` 把可牺牲的应用压到它下面来保证相对次序。
它的库（CNPG Cluster）能设，已设成 `critical`。

## 切换步骤

### 1. 推前置改动，在 4 OCPU 上先验证账目

```bash
cd /Users/matthew/projects/homelab
git push                                   # 前置改动 1/3/4
cd k8s/helm && just deploy-argocd           # 前置改动 2（manual-helm）
```

等 ArgoCD 收敛（3 分钟轮询），然后确认 requests 真的降下来了：

```bash
kubectl --context oracle-k3s describe node oracle-k3s | sed -n '/Allocated resources/,/Events/p'
# 期望：cpu requests ≈ 1372m。此时仍是 4 OCPU，所以显示的百分比是 /4000m（34%）。
```

**这一步不过就不要往下走**——shape 改完再发现 requests 没降，节点已经在 Pending 了。

⚠️ 这一步本身会滚一批 pod（改了 pod template 就会重建）。两个有用户可见影响的：

- **ZITADEL 会重启**：requests 写在 `HelmChart` 的 `valuesContent` 里，helm-controller
  重跑 chart → `auth.meirong.dev` 短暂不可用 → **SSO 短暂中断**。挑个没人用的时间。
- **zitadel-pg 会滚**：CNPG 单实例（`instances: 1`），滚动重启期间 ZITADEL 断库。
  它和上一条会先后发生，不是同时。

已核对**不会**踩的坑（2026-08-05 用 `kubectl diff -k` 服务端 dry-run 实测，无
`field is immutable`）：`calibre-metadata-updater` 是 CronJob，`jobTemplate` 可变；
`loki-0`/`tempo-0`/`trivy-server-0` 是 StatefulSet，`spec.template` 可变。
唯一不可改的是裸 `kind: Job` 的 `calibre-metadata-enrich`——**它的 200m 是刻意留的**，
原因写在 `cloud/oracle/manifests/calibre-metadata/enrich-job.yaml` 里。

### 2. 上节点改 kubelet 参数并清 hugepages

```bash
cd /Users/matthew/projects/homelab/cloud/oracle/ansible
just setup-k3s      # 幂等；k3s 已装则只重写 config.yaml 和 sysctl
```

不想跑整个 playbook 就手工等价操作：

```bash
ssh -i ~/.ssh/vgio ubuntu@100.107.166.37
sudo rm -f /etc/sysctl.d/20-microk8s-hugepages.conf
printf 'vm.nr_hugepages = 0\n' | sudo tee /etc/sysctl.d/99-no-hugepages.conf
sudo sysctl -p /etc/sysctl.d/99-no-hugepages.conf
# 把 kubelet-arg 两行加进 /etc/rancher/k3s/config.yaml（内容见 setup-k3s.yaml）
```

两件事的生效时机**不一样**，别混：

- **内核层立刻生效**：`vm.nr_hugepages=0` 一执行，那 2GiB 马上回到可用内存。
  2026-08-05 实测 `free -m` 的 `available` 从 3303Mi 跳到 **5388Mi**，
  `HugePages_Total` 从 1024 变 0。**这一步无需重启、无中断，越早做越好。**
- **k8s 侧要重启 kubelet 才认**：`node.status.capacity` / `allocatable` 来自 kubelet
  启动时缓存的 cAdvisor machine info。不重启的话 `hugepages-2Mi` 仍显示 `2Gi`、
  allocatable 仍在扣那 2GiB。`kubelet-arg`（system-reserved / eviction-hard）同理。

所以：**按本文顺序走（步骤 4 会停机重启）时这里不要单独重启 k3s**；但如果 shape 已经
改完了才补做本步（见步骤 5 的「手工改 shape」分支），就必须单独重启一次：

```bash
ssh -i ~/.ssh/vgio ubuntu@100.107.166.37 'sudo systemctl restart k3s'
```

⚠️ 这会重建全集群 pod（~2-3 分钟），**SSO 会再断一次**。在此之前的中间状态是
**安全但不理想**的：allocatable 偏保守（白扣 2GiB），而 `eviction-hard` 还是默认
100Mi —— 12GB 机器上这个阈值太晚，内核 OOM killer 往往先于 kubelet 的有序驱逐动手。

### 3. 静音告警 + 通告停机面

oracle 挂掉会连带的（Prometheus/Grafana/Alertmanager 在 homelab，告警链路本身活着）：

| 服务 | 停机影响 |
|---|---|
| ZITADEL | **SSO 全挂**——homelab 侧 Grafana / ArgoCD UI 也登不进 |
| ArgoCD | GitOps 停摆（控制面在 oracle） |
| cloudflared ×2 | oracle 侧所有子域 502 |
| Loki / Tempo | 日志、追踪断档；homelab otel-collector 先排队后丢 |
| Uptime Kuma | 自己挂了不会报自己 |
| external-dns(oracle) / opencost / trivy | 停摆，无数据面影响 |

```bash
# Alertmanager 在 homelab
kubectl --context k3s-homelab -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
# 另开一个终端，静音 cluster=oracle-k3s 90 分钟
amtool silence add cluster=oracle-k3s --duration=90m \
  --comment="A1 shape downsize 4/24 -> 2/12" --alertmanager.url=http://127.0.0.1:9093
```

### 4. 干净停机

```bash
ssh -i ~/.ssh/vgio ubuntu@100.107.166.37 'sudo systemctl stop k3s && sync'
# 再从 OCI Console / CLI 停实例（flex shape 变更要求实例 STOPPED）
oci compute instance action --action SOFTSTOP \
  --instance-id ocid1.instance.oc1.ap-osaka-1.anvwsljr7xo3pvycpglssemim2rrmsv66l4hn7joc54ioyp7jtcafeobgeja
```

### 5. apply

```bash
cd /Users/matthew/projects/homelab/cloud/oracle/terraform
make plan     # 必须是 0 to add, 1 to change, 0 to destroy —— 见下方"如果 plan 想重建"
make apply
```

开机（`--action START`），等 SSH 起来。

#### 分支：如果 shape 是在 OCI Console 手工改的

2026-08-05 实际就是这么做的。完全可以，但**必须回来把 terraform state 补账**，
否则 state 里长期记着旧 shape：

```bash
cd /Users/matthew/projects/homelab/cloud/oracle/terraform
make plan     # plan 每次都 refresh，所以会显示"零基础设施变更"，看着像没事
terraform state show oci_core_instance.k3s | grep -E "ocpus|memory_in_gbs"
#   ← 这里才照出真相：refresh 是**内存里**的，不落盘。手工改完这里仍是旧值 4/24
make apply    # 0 added, 0 changed, 0 destroyed —— 只把 refresh 结果和 outputs 落盘
```

为什么要管：`plan` 自带 refresh 所以不会误判，但 `terraform state show` 和任何直读
state 的东西会给出错误数字；而 `apply -refresh=false` 会拿 state 里的旧值去和 config
比，可能对一台已经是目标形状的实例再发一次 shape 变更（=白重启一次）。

另外手工改 shape 时**别忘了步骤 2**（hugepages + kubelet-arg）—— 它不在 OCI Console
的流程里，最容易漏。漏了的症状：节点 `hugepages-2Mi` 仍是 `2Gi`，且
`capacity − allocatable` 的差额恰好等于 2048Mi（说明 system-reserved 一条没生效）。

### 6. 验证

**一条命令核完全部不变量**（2026-08-05 新增，取代下面那串手工检查）：

```bash
cd /Users/matthew/projects/homelab/cloud/oracle && just verify-node
```

24 项：主机层（hugepages / kubelet-arg / UDP GRO 持久化 / firewalld 递归防护 /
FORWARD policy / DNS fallback / Tailscale 只广播本节点 /32）· 节点账目（capacity、
**预留差额** —— 差额恰好 2048Mi 会被专门指出来，那正是「sysctl 清了但 kubelet 没重启」
的典型症状）· pod/App · ClusterMesh 双向 `retrieved=true` · 数据面 HTTP 码。
任一条不成立即非零退出。

**配套还有一条查「配置漂移」的**（上面那条查的是「结果对不对」，两者互补）：

```bash
cd /Users/matthew/projects/homelab/cloud/oracle && just check-node-drift
```

它是 `ansible-playbook --check --diff`，只读，**`changed=0` 即无漂移**。这个信号是
2026-08-05 才变可信的——之前有 4 条结构性假阳性（2 条 firewalld reload 是「动作」不是
「状态」，已改成 handler；2 条 FORWARD ACCEPT 规则永远无法收敛，已删除，理由见
`setup-k3s.yaml` 里的注释）。留着假阳性的漂移检测等于没有。

下面是它逐条对应的手工命令，排障时按需单独跑：

```bash
CTX="--context oracle-k3s"

# ① hugepages 归零、capacity/allocatable 是新值
kubectl $CTX get node oracle-k3s -o jsonpath='{.status.capacity}{"\n"}{.status.allocatable}{"\n"}'
#    期望 capacity cpu=2, hugepages-2Mi=0；allocatable memory ≈ 8925Mi

# ② 没有 Pending
kubectl $CTX get pods -A --field-selector=status.phase=Pending

# ③ requests 占比
kubectl $CTX describe node oracle-k3s | sed -n '/Allocated resources/,/Events/p'
#    ⚠️ 别拿 1372m(76%)/5800Mi(65%) 当验收线——那是 2026-08-05 缩容**当时**的基线，
#    不是不变量：之后每加一个负载它就往上走（2026-08-06 晚已到 1477m/82%）。
#    这里要看的是「没有 Pending、requests 没超 allocatable」，不是对上某个数字。
#    当前值以实测为准，解读见 reference/k8s-qos-resource-management.md。

# ④ 优先级真的挂上了
kubectl $CTX get pods -A -o custom-columns=P:.spec.priority,NS:.metadata.namespace,N:.metadata.name \
  --sort-by=.spec.priority | head -15
#    期望能看到 -10 那一档

# ⑤ 数据面
curl -sI https://auth.meirong.dev | head -1     # ZITADEL / SSO
curl -sI https://home.meirong.dev | head -1     # 隧道 + 网关
kubectl $CTX -n argocd get app -A | grep -cv "Synced.*Healthy"   # 期望 0
```

⑥ 24 小时后回看内存水位（Prometheus 在 homelab）：

```promql
max_over_time((node_memory_MemTotal_bytes{cluster="oracle-k3s"}
  - node_memory_MemAvailable_bytes{cluster="oracle-k3s"})[24h:5m]) / 1024/1024/1024
```
超过 **10 GiB** 就说明余量不够，回头砍 `bulk` 那一档里的东西。

## 踩坑与回滚

**如果 `make plan` 想重建实例**：立刻停。2026-08-05 实测正确的输出是
`0 to add, 1 to change, 0 to destroy` + `~ shape_config` 就地更新。出现
`must be replaced` 一定是别的字段漂移了（镜像 OCID、`create_vnic_details`），
先查漂移，**绝不要**带着 replace 跑 apply —— `preserve_boot_volume = true` 保得住盘，
但保不住 ap-osaka-1 的容量。

**涨回 4/24 不保证做得到**：ap-osaka-1 的 A1 Free Tier 长期没容量，回滚可能连续数天
`Out of host capacity`。**缩容按单向操作对待**。真要回滚就是反着跑本文：
先 shape apply，再 `git revert` 前置改动。前置改动本身在 4 OCPU 上无害
（requests 变小只是少占坑），**不急着 revert**。

**开机后头 10 分钟最难受**：ArgoCD repo-server + application-controller 同时全量
reconcile，撞上只剩 2 核。表现是 app 短暂 `Unknown`/`Progressing`、UI 卡。
不要在这个窗口手工点 Sync，等它自己收敛。

**别指望把负载挪去 homelab**：那台是 13.5GiB 可见内存的笔记本 VM，7d 最低可用
只有 3.31G。缩容的余量只能从 oracle 自己身上找。

### 步骤 1 实际踩到的：loki-gateway 滚动更新死锁（已修，但机制要懂）

改 gateway 的 requests 触发滚动更新后，新副本**永久 Pending 25 分钟**，无自愈迹象。
三层原因，逐个都会单独咬人：

1. **单节点 + 硬性 anti-affinity + replicas=1 = 结构性死锁。**
   chart 默认给 gateway 配 `requiredDuringSchedulingIgnoredDuringExecution`
   （`topologyKey: kubernetes.io/hostname`），为多节点 HA 设计。replicas=1 时
   `maxUnavailable` 25% 向下取整为 **0** → 旧 pod 不许先走；`maxSurge` 起的新 pod
   又撞旧 pod 的 anti-affinity → 不可调度。两边互等。
   修复：`k8s/helm/values/loki.yaml` 的 `gateway.affinity: null`。

2. **`affinity: {}` 不生效，必须写 `null`。** 模板是 `{{- with .Values.gateway.affinity }}`，
   直觉上 `{}` 是假值该跳过；但 Helm 合并 values 时**空 map 不覆盖非空的 chart 默认值**
   （`coalesceTables` 既定行为）。第一次修就写成 `{}`，结果 ArgoCD 报 **Synced**、
   revision 也对、渲染结果一字未变、pod 继续 Pending。
   > ⚠️ **"Synced" 只保证 live == 渲染结果，不保证渲染结果 == 你的意图。**
   > 这类 nested map 覆盖推之前先本地核对：
   > `helm template loki grafana/loki --version <v> -f k8s/helm/values/loki.yaml`

3. **改掉 affinity 是必要不充分——pod anti-affinity 是对称的。** 新 pod 自己没规则了，
   但**还在跑的旧 pod 带着规则**，禁止同节点再来一个 gateway。报错措辞会从
   `didn't match pod anti-affinity rules` 变成 `didn't satisfy **existing pods**
   anti-affinity rules`（这个词的变化就是判据）。而 Deployment 控制器又不肯把旧 RS
   缩到 0（`maxUnavailable`=0）。只能人工打破一次：

   ```bash
   # 删 pod 没用 —— 旧 RS 仍是 replicas=1，会按旧模板再建一个
   kubectl --context oracle-k3s -n monitoring delete rs <旧 RS 名> <中间那个 RS 名>
   ```

   删掉过期 ReplicaSet 后新 pod 立刻调度成功。**配置修好之后**这一步只需做一次，
   后续滚动更新不会再死锁。

**同类风险已扫过**：两集群里另一个带硬性 anti-affinity 的 Deployment 是
`cilium-operator`，但它 `maxUnavailable: 100%`（Cilium chart 刻意设的，旧 pod 先走），
无此问题。扫法：

```bash
kubectl get deploy -A -o json | jq -r '.items[]
  | select(.spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution)
  | "\(.metadata.namespace)/\(.metadata.name) replicas=\(.spec.replicas) \(.spec.strategy.rollingUpdate)"'
```

### 为什么实测 1372m 比预估的 1287m 多 100m

`cilium` 的 **initContainer 要 100m**，而 `cilium-agent` 本身没写 requests。调度器算
pod 有效 request 用 `max(sum(常规容器), max(initContainer))` → 这个 pod 记 100m，
而按容器求和的口径会算成 0。**核对 requests 账目要用 `describe node`，别自己 sum 容器。**

## 相关

- 逐层资源模型 / QoS → [reference/k8s-qos-resource-management.md](../reference/k8s-qos-resource-management.md)
- 成本归因与 KRR 右尺寸报告 → [reference/cost-and-rightsizing.md](../reference/cost-and-rightsizing.md)
- ArgoCD 控制面在 oracle 的后果 → [runbooks/argocd-control-plane-on-oracle.md](argocd-control-plane-on-oracle.md)
- 整机重建（不是缩容）→ [runbooks/oracle-k3s-rebuild.md](oracle-k3s-rebuild.md)
