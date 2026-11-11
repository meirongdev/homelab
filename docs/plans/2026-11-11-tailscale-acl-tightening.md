# Tailscale ACL 收紧：服务器节点从 `*:*` 收到按需端口

> 日期: 2026-11-11
> 状态: 📐 设计（未实施）
> 结论: 现行 ACL 只有一条 `autogroup:member + tag:homelab + tag:oracle → *:*`。改成「运维终端全通、服务器之间只开实测用到的端口」，
>       共 7 条 grant，附带一组 policy `tests`：断言不过，Tailscale 就拒收整份策略，terraform apply 随之失败，现网不变。
>       ☠️ 不能只收紧 `tag:homelab`：homelab 的主力节点 `k8s-node` 没有 tag，是用户设备，而且**不能**打 tag
>       （打了 tag 就看不见共享进来的 DGX，LiteLLM 会断），所以服务器一律按 Tailscale IP 写进 `hosts`。
>       与 [Cilium 网络策略](2026-11-10-cilium-network-policy.md) 互补：Cilium 管被选中的 pod；ACL 管节点本身、hostNetwork 进程，
>       以及没进护栏的 ns（monitoring、backup、argocd、kube-system 等）。
> 关联: [tailscale-network.md](../reference/tailscale-network.md) · [security.md](../reference/security.md) ·
>       `tailscale/terraform/main.tf`

---

## 1. 现状（2026-11-11 实测）

**策略**：`acls = [{ src = ["autogroup:member", "tag:homelab", "tag:oracle"], dst = ["*:*"] }]`，外加 `autoApprovers`。
任何一台服务器、任何一个 pod（出口经节点 SNAT 成节点的 Tailscale IP）都能访问整个 tailnet 的所有端口，
还能经 pve 通告的两段 LAN 访问 pve `:8006`、106 的 restic 仓库和路由器。

**设备**（`tailscale status --json`；所有基础设施设备的 key 都是 never expire）：

| 设备 | Tailscale IP | 身份 | 角色 |
|---|---|---|---|
| `k8s-node` | 100.94.186.7 | 用户设备（**无 tag**） | homelab 控制面，LiteLLM、Prometheus 等大部分负载在这台 |
| `k3s-exp`（即 k8s-worker-106） | 100.74.162.97 | `tag:homelab` | homelab worker，LAN IP 192.168.50.107 |
| `node0` | 100.107.166.37 | `tag:oracle` | oracle 单节点，通告自己的 VCN IP `10.0.0.26/32` |
| `storage`（106 宿主） | 100.110.27.111 | `tag:homelab` | restic 仓库，**不是** k8s 节点，却和 worker 共用 tag |
| `pve` | 100.118.193.51 | 用户设备 | 通告 `10.10.10.0/24`、`192.168.50.0/24` |
| MacBook Pro M2（M2） | 100.89.15.120 | 用户设备 | OMLX、agent 主机 |
| Mac Studio | 100.98.220.75 | 用户设备 | OMLX、agent 主机 |
| `mbpm5` | 100.114.53.49 | 用户设备 | 日常开发机 |
| `P8a` | 100.123.107.4 | 用户设备 | 手机 |
| `spark-ccf3` / `spark-2435`（DGX） | 100.97.87.120 / 100.67.164.92 | **别人 tailnet 共享进来** | 推理 |

**两个决定方案形状的事实**：

1. **DGX 不归这份 ACL 管**。共享进来的设备默认被隔离：它只能应答，不能主动连我们的任何设备；而我们连它，
   受的是**它主人的 tailnet 策略**约束（[Tailscale 文档：sharing](https://tailscale.com/kb/1084/sharing)）。
   所以这份 ACL 既不需要、也无法给 DGX 写规则。
2. **`autogroup:member` 不能再当「全通」的源**：它包含 `k8s-node` 和 `pve`。Tailscale 的 ACL 只有 allow，没有 deny，
   只要某条全通规则的 src 覆盖了 `k8s-node`，后面写什么都收不紧它。所以运维终端按 IP 点名。

## 2. 东西向流量清单（谁 → 谁:端口）

来源三处，互相印证：仓库里所有写死的「tailnet IP:端口」、两个集群的 NodePort、两个集群 Cilium 的 conntrack 表
加上五台服务器 `ss` 的已建立连接快照（宿主机上的 k3s API、sshd 不经 Cilium，只能靠 `ss` 看）。

| # | 源 | 目的 | 端口 | 用途 | 依据 |
|---|---|---|---|---|---|
| A | k8s-node、worker | node0 | tcp 32379 | ClusterMesh（kvstoremesh 在哪台节点都可能，worker 实测在连）| conntrack |
| B | k8s-node、worker | node0 | tcp 31080 / 31317 / 31320 | otel → Loki、Tempo；Grafana → Tempo 查询 | 清单、conntrack |
| C | k8s-node、worker | `10.0.0.26`（经 node0 的 /32 路由） | tcp 4240、udp 8472、icmp | cilium-health 跨集群探测；VXLAN 外层 | `ss`（源地址是节点的 Tailscale IP）|
| D | k8s-node、worker | M2、Studio | tcp 8000 / 9090 / 9100 | LiteLLM、json-exporter → OMLX；Prometheus 抓指标 | 清单、conntrack |
| E | node0 | k8s-node | tcp 6443 / 31090 / 31093 / 31400 / 31952 / 32379 | ArgoCD → API；otel 远程写；Loki ruler → Alertmanager；calibre-llm → LiteLLM；ESO → Vault；ClusterMesh | 清单、`ss`、conntrack |
| F | node0 | `10.10.10.10`、`192.168.50.107`（经 pve 的路由） | tcp 4240、udp 8472、icmp | 同 C 的反方向 | `ss` |
| G | node0 | storage | tcp 22 | oracle 夜备 restic sftp（03:30）| `backup/overlays/oracle/backup-script.yaml` |
| H | 运维终端（mbpm5、P8a、M2、Studio） | 任意 | 任意 | ssh、kubectl、pve UI、terraform/ansible | — |

**确认不需要、收紧后会被拒的**：
- oracle `31082`（kube-state-metrics NodePort）：文档已写明不再用于跨集群抓取（[observability-multicluster.md](../reference/observability-multicluster.md)）。
- 两侧 Gateway 的 NodePort `31505` / `31515`：cloudflared 走 ClusterIP。
- homelab 的备份写 106 走 LAN `192.168.50.106`（ip rule 5260），不经 tailnet；worker ↔ k8s-node 也走 LAN。
- 快照里 storage、pve 没有任何经 tailnet 主动发起的连接。

⚠️ 清单的盲区：快照只抓到当时开着的连接。每小时一次的 ESO 轮询、每晚的备份、每周的任务靠清单补；
仍可能有漏网的低频流量，所以上线后要盯 24 小时（§5）。

## 3. 新策略

`tailscale/terraform/main.tf` 的 `tailscale_acl.main` 改成下面这样（`tagOwners`、`autoApprovers` 原样保留，省略未写）。
用 `grants` 而不是旧的 `acls`：`ip` 字段能按协议写端口，VXLAN 的 udp 8472 不会顺带放开 tcp 8472。

```hcl
hosts = {
  # 服务器：Tailscale IP（k8s-node 不能打 tag，只能按 IP 点名，见文首）
  "k8s-node" = "100.94.186.7"
  "worker"   = "100.74.162.97"
  "node0"    = "100.107.166.37"
  "storage"  = "100.110.27.111"
  "pve"      = "100.118.193.51"   # 没有任何 grant 以它为源，只在 tests 里当反向检查的目标
  "m2"       = "100.89.15.120"
  "studio"   = "100.98.220.75"
  # subnet route 后面的节点地址（cilium-health / VXLAN 用节点 IP，不用 Tailscale IP）
  "k8s-node-lan" = "10.10.10.10"
  "worker-lan"   = "192.168.50.107"
  "node0-vcn"    = "10.0.0.26"
  # 运维终端
  "mbpm5" = "100.114.53.49"
  "phone" = "100.123.107.4"
}
grants = [
  # H 运维终端：全通（含 pve 通告的两段 LAN）。新增个人设备要加进这里，否则它什么都连不上。
  { src = ["mbpm5", "phone", "m2", "studio"], dst = ["*"], ip = ["*"] },
  # A B homelab → oracle 的 NodePort
  { src = ["k8s-node", "worker"], dst = ["node0"], ip = ["tcp:32379", "tcp:31080", "tcp:31317", "tcp:31320"] },
  # C homelab → node0 的 VCN IP：健康探测与 VXLAN。外层源地址实测是 Tailscale IP；LAN IP 一并写上，
  #   因为 VXLAN 封装可能显式用节点 IP 当源，而当前没有跨集群 pod 流量，无法在线核实。
  { src = ["k8s-node", "worker", "k8s-node-lan", "worker-lan"], dst = ["node0-vcn"], ip = ["tcp:4240", "udp:8472", "icmp:*"] },
  # D homelab → Mac：OMLX 推理与指标
  { src = ["k8s-node", "worker"], dst = ["m2", "studio"], ip = ["tcp:8000", "tcp:9090", "tcp:9100"] },
  # E oracle → homelab 的 API 与 NodePort
  { src = ["tag:oracle"], dst = ["k8s-node"], ip = ["tcp:6443", "tcp:31090", "tcp:31093", "tcp:31400", "tcp:31952", "tcp:32379"] },
  # F oracle → homelab 节点的 LAN IP（经 pve 的路由，过滤在 pve 上执行）
  { src = ["tag:oracle", "node0-vcn"], dst = ["k8s-node-lan", "worker-lan"], ip = ["tcp:4240", "udp:8472", "icmp:*"] },
  # G oracle 夜备 → 106 的 restic sftp
  { src = ["tag:oracle"], dst = ["storage"], ip = ["tcp:22"] },
]
```

**tests**（每次改策略都会跑；任一条不过，整份策略被拒）。正向覆盖 §2 的每一行，反向钉住最想挡住的几条：

```hcl
tests = [
  { src = "k8s-node", accept = ["node0:32379", "node0:31080", "node0:31317", "node0:31320", "node0-vcn:4240", "m2:8000", "studio:9100"],
                      deny   = ["node0:22", "node0:6443", "storage:22", "m2:22", "pve:8006", "192.168.50.4:8006", "node0:31082"] },
  { src = "worker",   accept = ["node0:32379", "node0:31080", "node0-vcn:4240"],
                      deny   = ["k8s-node:22", "storage:22", "studio:22"] },
  { src = "tag:oracle", accept = ["k8s-node:6443", "k8s-node:31090", "k8s-node:31093", "k8s-node:31400", "k8s-node:31952",
                                  "k8s-node:32379", "storage:22", "k8s-node-lan:4240", "worker-lan:4240"],
                        deny   = ["k8s-node:22", "k8s-node:10250", "k8s-node:31505", "storage:9100", "m2:8000",
                                  "192.168.50.4:8006", "k8s-node-lan:22"] },
  { src = "tag:oracle", proto = "udp", accept = ["k8s-node-lan:8472"], deny = ["k8s-node-lan:53"] },
  { src = "mbpm5", accept = ["k8s-node:22", "node0:22", "storage:22", "192.168.50.4:8006", "10.10.10.10:22"] },
]
```

⚠️ 语法上没在线验过的两处：grants 里 `icmp:*` 的写法、tests 的 `src` 用 host 别名。两者都在 §4 第 2 步的校验里见分晓，
不合法的话 Tailscale 会直接拒收，现网不受影响。

## 4. 上线步骤

**时机**：在 2026-11-18 Cilium 翻 enforce **之前**做完，并留出 24 小时观察，免得两层的改动叠在一起、出了问题分不清是哪层。
白天做，避开 02:00–04:00（三个备份任务的窗口）。

1. **确认终端清单完整**：上表之外还有没有要连 tailnet 的个人设备（平板、另一台电脑）。漏了的设备上线后什么都连不上。
2. **只校验不生效**：把新策略 POST 到 Tailscale API 的策略校验接口，官方 GitOps action 的 test 步骤调的就是它。tests 全过再往下走。
3. **应用**：`cd tailscale/terraform && just plan`，确认只有 `tailscale_acl.main` 一处原地更新，然后 `just apply`。
4. **立刻跑正向检查**（全部应在 5 分钟内通过）：

   | 流量 | 检查 |
   |---|---|
   | A ClusterMesh | `just helm clustermesh-status`，两侧 `1/1 remote clusters ready` |
   | C / F 健康探测 | 两侧各一个 agent：`cilium-health status` 里对端集群的节点 reachable |
   | E ArgoCD → homelab | 对一个 homelab App 做 hard refresh，sync 状态正常 |
   | E ESO → Vault | 给 oracle 一个 ExternalSecret 打 `force-sync` 注解，回到 `SecretSynced` |
   | E 远程写 | homelab Prometheus 里 `up{cluster="oracle-k3s"}` 的最新样本在 2 分钟内 |
   | B Loki | Grafana 里查 homelab 最近 2 分钟的日志有新行 |
   | E LiteLLM、Alertmanager | 从 node0：`curl -s 100.94.186.7:31400/health/liveliness`、`curl -s 100.94.186.7:31093/-/healthy` |
   | D Mac | Prometheus 的 Mac 相关 target 全部 up；`just helm netpol-audit` 不受影响 |
   | G 备份 | 从 node0：`nc -zv -w3 100.110.27.111 22`；当晚 03:30 的 oracle restic Job `Complete` 为准 |

5. **反向检查**（应超时或被拒）：从 node0 `nc -zv -w3 100.94.186.7 22`；从 k8s-node `nc -zv -w3 100.118.193.51 8006`、
   `nc -zv -w3 100.110.27.111 22`。
6. **观察 24 小时**：`ClusterMeshRemoteClusterNotReady`、`ExternalSecretNotReady`、Mac 与 oracle 的 TargetDown、Loki 断流、
   oracle 夜备。都安静才算完成。

**回滚**（由快到慢）：管理控制台 Access controls 里贴回旧策略（半分钟，事后从 git 再 apply 一次消除漂移）；
或 `git revert` + `just apply`（约 1 分钟）。旧策略就是现在 `main.tf` 里那三行。

## 5. 它挡不住什么

- **DGX**：进 DGX 的流量归它主人的策略管；DGX 也不能主动连我们（共享的默认隔离）。
- **节点粒度**：ACL 只认节点。k8s-node 上任何一个 pod 都拥有 k8s-node 的全部授权（例如连 Mac 的 `:8000`，OMLX 不验 key）。
  pod 级的区分靠 Cilium 护栏，没进护栏的 ns 就只剩这一层。
- **运维终端全通**：手机丢了等于整个 tailnet 敞开。要收紧可以把 `phone` 拆出来单独给几个端口，本方案不做。

## 6. 顺带发现、不在本方案范围

- ☠️ **oracle 以 root 身份 sftp 写 106 的 restic 仓库**：oracle 节点一旦失守，攻击者能删掉全部备份。ACL 只能限定「能连 22」，
  限制不了连上以后能做什么。修法是在 106 的 `authorized_keys` 里给这把 key 加 `restrict,command="internal-sftp"` 并 chroot，
  或者改用 restic rest-server 的 `--append-only`。值得单独立项，和 [离站备份](2026-08-03-offsite-backup.md) 一起考虑。
- oracle 的 kube-state-metrics 还开着 NodePort `31082`，没人用，可以改回 ClusterIP。
- `storage` 和 worker 共用 `tag:homelab`。ACL 按 IP 写之后这不影响正确性，但 tag 已经失去「k8s 节点」的含义，
  可以单独改成 `tag:storage`（改 tag 不换 IP、不掉线）。
- 运维终端也可以不按 IP 点名，改用设备 posture（`node:os` 属于 macOS / Android 的成员设备），新设备就能自动纳入。
  代价是多依赖一个功能，而且 Linux 服务器以后若要当终端用会被排除。先用 IP 列表，规模大了再换。

## 7. 做完之后回写（然后删除本文件）

- `reference/tailscale-network.md`「Tailscale Tags and ACL」：换成新的规则表与 §2 的流量清单，写明加新的跨节点端口要同时加 grant 和 test。
- `reference/security.md` 第 9 层：节点层从 `*:*` 改为按需端口。
- `runbooks/add-service.md`：新服务需要跨节点或跨集群访问时，改 `tailscale/terraform/main.tf`。
- ROADMAP：如果有对应条目，标为完成。
