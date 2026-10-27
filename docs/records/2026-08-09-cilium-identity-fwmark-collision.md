# Cilium 身份标记撞上 Tailscale fwmark：alertmanager 一个 pod 到整个 100.64/10 超时

> 日期: 2026-08-09
> 影响: homelab 的 `monitoring/alertmanager` 到整个 `100.64.0.0/10` 全部超时（oracle、NAS、
>       两台 DGX 的 tailnet 地址都不通），同节点、同 namespace 的其它 pod 全部正常。
>       全集群扫描时只有它一个真实负载中签。
> 根因: Cilium 把 endpoint 安全身份（identity）编进 `skb->mark` 高位；Tailscale 即使
>       `--netfilter-mode=off` 也装三条 `fwmark 0x80000/0xff0000` 的 ip rule（5210/5230/5250），
>       掩码只看 bit16-23，等价于 `identity & 0xFF == 0x08`。alertmanager 的 identity 108040
>       低字节恰为 8，出向在 5210 处被送进 main 表，绕过 `5270: from all lookup 52`，
>       CGNAT 地址按默认路由从 `eth0` 扔给了 LAN 网关。
> 处置: 两集群节点在优先级 5200 加 `to 100.64.0.0/10 lookup 52`（homelab 修复、oracle 预防），
>       当时由开机 oneshot `tailscale-cgnat-route.service` 维护；三天后该单元被证明守不住，
>       2026-08-12 起改由收敛器维护（[2026-08-12-tailscale-iprule-guard-drift](2026-08-12-tailscale-iprule-guard-drift.md)）。
>       现行机制与判据在 [reference/tailscale-network.md](../reference/tailscale-network.md)。

## 经过

### 两个把人带偏的特征

- 打一个**没人监听的端口**同样是超时，而不是 `connection refused`。看着像防火墙丢包，
  其实是路由把包送错了出口，压根没到对端。没有人回 RST，所以任何端口都表现为超时。
- 删掉 pod 重建**不管用**（新 IP、新 endpoint，照样坏）。看着像应用或镜像的问题。

### 抓包（同一秒、同一目标）

```
坏: lxcXXX In  10.42.0.142 > 100.107.166.37:31080  │  eth0       Out  10.10.10.10  > 100.107.166.37:31080
好: lxcYYY In  10.42.0.114 > 100.107.166.37:31080  │  tailscale0 Out  100.94.186.7 > 100.107.166.37:31080
```

### A/B/A 因果实验

改标签 → 换 identity → 立刻换行为，来回各一次：

| identity | `& 0xFF` | 结果 |
|---|---|---|
| 108040（`monitoring/alertmanager` 原身份） | 8 | 全 `100.64/10` 不可达 |
| 95821（临时加一个无关标签） | 77 | 立刻全通 |
| 108040（撤掉标签） | 8 | 立刻又断 |

当时全集群扫描，只有它一个真实负载的低字节是 `0x08`，也只有它坏。

### 验过的死路

重建 pod、`runAsUser`、容器镜像、netns（同 netns 的 ephemeral container 表现一致）、
NetworkPolicy/CNP/CCNP（两个集群都是空的）、ipcache 缺条目、ClusterMesh 健康度。

最容易走岔的一步是去 grep Tailscale 的 netfilter 规则找「谁打的 mark」：`--netfilter-mode=off`
下它一条 netfilter 规则都不装，但照样装 ip rule。实测 nft、iptables-nft、iptables-legacy
三处含 `0x80000` 的规则均为 0 条。

### 证据强度

mark 没有从包上直接读出来（节点没装 `conntrack` 命令，`/proc/net/nf_conntrack` 也不可读）。
结论由三件事共同钉死：规则的掩码语义、全集群 identity 与故障的一一对应、A/B/A 因果实验。

## 修复

- 5200（早于 5210）把 `100.64.0.0/10` 钉死到 table 52，对所有 pod 一次性免疫，形状与既有的
  5260 LAN 直通规则一致。绕过 Tailscale 的防环规则是安全的：没有任何东西会合法设置
  `0x80000`（就是上面那 0 条），5210–5250 在这里只会因位段碰撞误伤。
- 不采用「给 alertmanager 换标签」：那只躲开这一次抽签，下一个中签的 pod 照样断。
- oracle 预防性加同一条：当天扫它 52 个 endpoint，低字节 `0x08` 的只有保留身份 8，没有真实
  负载中签，但规则集与 homelab 一模一样，同样暴露。中签会打断 otel remote-write 与 krr 打回
  homelab（`100.94.186.7`）的路径。
- 验证：alertmanager 在原身份 108040 下到 oracle / NAS / 两台 DGX 全通，跨集群遥测无回归。

## 后续

三天后两台节点上的这条规则（连同 homelab 的 5260）被 systemd-networkd 静默清掉，oracle 的
homepage（identity 138760，同样低字节 `0x08`）中签断连 33 小时：
[2026-08-12-tailscale-iprule-guard-drift](2026-08-12-tailscale-iprule-guard-drift.md)。
