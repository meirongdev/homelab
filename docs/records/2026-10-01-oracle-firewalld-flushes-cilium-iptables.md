# oracle pod 出站全断 30 分钟：needrestart 重启 firewalld，direct 规则让它 flush 掉 Cilium 的 iptables

> 日期: 2026-10-01（06:34:36 → 07:04:36 +08 = 09-30 22:34:36 → 23:04:36 UTC，自愈）
> 影响: oracle-k3s **全部 pod 新建出站连接失效 30 分钟**。cloudflared 崩溃循环 →
>       `CloudflaredAllReplicasDown`(critical) 06:42–07:06 即 `*.meirong.dev` 经 oracle 入口
>       不可达约 24 分钟；ESO 连不上 homelab Vault → `ClusterSecretStoreNotReady` + 约 20 个
>       `ExternalSecretNotReady`；`DeadMansSwitchReceiverDown`、`AlertmanagerFailedToSendAlerts`、
>       external-dns / argocd-repo-server 重启。已建立的连接（conntrack 里已有 NAT 条目）不受影响，
>       所以 oracle→homelab 的指标推送全程没断
> 根因: oracle 的 Tailscale 递归护栏用的是两条 **firewalld direct 规则**。firewalld 2.1.1
>       只要运行时有任意 direct 配置，start/stop/reload 时就会对 iptables **全部表**执行
>       `-F -X -Z`，Cilium 的 `CILIUM_POST_nat` masquerade 链也在其中。06:34 unattended-upgrades
>       升级 libssl3，needrestart 随后重启了链接它的服务，firewalld 也在内。pod 出站包因此不再做 SNAT，
>       到 1.1.1.1 / 1.0.0.1 / 169.254.169.254 的 DNS 全部超时，直到 Cilium 自己重装规则
> 结论: ☠️ **08-01 那次「OCI DNS 上游故障」是同一个病，当时定性错了**（06:30 正好在升 libssl3）。
>       08-12 加的 1.1.1.1 上游对它无效：三个上游是一起超时的。修法是 oracle 上**不留任何
>       firewalld direct 规则**，护栏改用和 k8s-node 相同的 systemd unit

## 一、证据链

**1. 三个上游同时超时，问题在本机。** CoreDNS 在这 30 分钟里的错误按上游计数：

```text
1310 ->169.254.169.254:53: i/o timeout
 640 ->1.0.0.1:53: i/o timeout
 605 ->1.1.1.1:53: i/o timeout
```

链路本地的 169.254.169.254 和公网 anycast 同时不通，问题在出站路径本身，不在某个上游。
同一时段 tailscaled 在报 pod 到 homelab Vault 的新连接超时
（`open-conn-track: timeout opening (TCP 10.52.0.163:51552 => 100.94.186.7:31952)`）。
不止 DNS，**pod 出站整个断了**。

**2. 起点是 needrestart。** 节点 journal（+08）：

```text
06:34:21  dpkg: upgrade libssl3t64 3.0.13-0ubuntu3.15 → .16
06:34:31  systemd[1]: systemd 255.4-1ubuntu8.17 running in system mode   ← daemon-reexec
06:34:32  Stopping systemd-networkd / systemd-resolved / ssh / udevd ...
06:34:35  Stopping firewalld.service
06:34:36  Started firewalld.service
06:34:53  CoreDNS 第一条 i/o timeout
07:04:36  CoreDNS 最后一条 i/o timeout                              ← 恰好 30 分钟
```

**3. firewalld 的 flush 条件**（节点上 `/usr/lib/python3/dist-packages/firewall/core/fw.py`，2.1.1-1）：

```python
def may_skip_flush_direct_backends(self):
    if self.nftables_enabled and not self.direct.has_runtime_configuration():
        return True        # 只有「没有 direct 配置」才跳过
    return False
```

跳不过时走 `ipXtables.build_flush_rules()`，对每个内建表发 `-t <table> -F / -X / -Z`。
FirewallBackend=nftables 只管 firewalld 自己的规则；direct 规则仍走 iptables 后端，
所以只要有一条 direct 规则，nftables 后端照样会清空 iptables。oracle 的 Cilium 用的是
iptables masquerade（`cilium-dbg status`: `Masquerading: IPTables`），被清的正是它。

**4. 恢复靠 Cilium 自己重装规则。** 07:04 前后没有任何人工操作，也没有任何服务重启。
事后观察到 `CILIUM_POST_nat` 的 MASQUERADE 计数器只累计了约 0.4 小时的量
（速率约 0.43 包/秒，绝对值约 540），说明 Cilium 会周期性重写这组规则。
**具体周期没有在源码层面核实**，这里只依据「flush 后恰好 30 分钟恢复」。

## 二、为什么之前没抓到

**08-01 被误判。** 那次的现象完全一样：CoreDNS 到 169.254.169.254 超时，cloudflared 崩溃，
全站约 20 分钟不可达。窗口是 07-31 22:31–22:52 UTC，而 dpkg 记录 22:30 UTC（08-01 06:30 +08）
在升 `libssl3t64 openssl`。复盘时只看了 CoreDNS 日志，结论是「OCI DNS 抖动」，08-12 的修法是给
resolved 加 1.1.1.1 / 1.0.0.1 上游，还用 iptables 只掐 169.254.169.254 做了演练并通过。
演练只模拟了单个上游不通，模拟不出「所有出站都没有 SNAT」，所以那次通过不能证明这个病已修。
那份记录里「cloudflared 24 天重启 24–28 次」的旁证，指向的其实也是这个。

**09 月起的对照**（journal 从 09-08 起才有；TSDB 从 09-17 起才有）：

| firewalld 重启（+08） | needrestart 的来由 | 可见影响 |
|------|------|------|
| 09-12 06:49（两次） | libc6 + python3.12 | journal 有重启记录，TSDB 已过期，查不到告警 |
| 09-22 07:00（两次） | libexpat / glib / rsyslog | cloudflared 当小时重启 2 次，`DeadMansSwitchReceiverDown` 07:08–07:26 |
| 09-26 06:54 | libexpat | 无告警（原因未查，可能是 Cilium 碰巧很快重装了规则） |
| 10-01 06:34 | libssl3 | 本次 |

firewalld 是 Python 写的，并且链接 libssl。凡是升 python3.x / libssl / libc 的安全更新，
它都会被 needrestart 重启，每个月好几次。另外，任何 `firewall-cmd --reload`（例如 setup-k3s.yaml
里 `notify: Reload firewalld` 的 handler）效果相同。

## 三、处置

1. **护栏改用 systemd unit**：`/etc/systemd/system/tailscale-no-cni-endpoint.service`
   与 k8s-node 用同一个 unit，CIDR 对调（INPUT 丢 `10.52.0.0/16`，OUTPUT 丢 `10.42.0.0/16`）。
2. **删掉 firewalld direct 规则，且不 reload**：运行时和永久配置各删一遍。删之前 direct 规则
   还在运行时里，这时 reload 会正好再 flush 一次。运行时删除只对那一条规则做 `iptables -D`
   （`fw_direct.py` `remove_rule` → `_register_rule` 在规则清空时删掉 chain 键，
   `has_runtime_configuration()` 随即返回 False）。在节点上执行：

   ```bash
   # ssh -i ~/.ssh/vgio ubuntu@100.107.166.37
   for r in "INPUT 0 -p udp --dport 41641 -d 10.52.0.0/16 -j DROP" \
            "OUTPUT 0 -p udp --dport 41641 -d 10.42.0.0/16 -j DROP"; do
     sudo firewall-cmd --direct --remove-rule ipv4 filter $r
     sudo firewall-cmd --permanent --direct --remove-rule ipv4 filter $r
   done
   ```

   ☠️ **删完必须 `sudo systemctl restart tailscale-no-cni-endpoint`**。nftables 后端下，
   direct 规则**直接插在内建 INPUT/OUTPUT 链里**，没有 `*_direct` 链，内容和 unit 的规则逐字相同。
   10-01 在线迁移时是先启动 unit、再删 direct 规则：unit 的 `iptables -C` 把 firewalld 那条认成了
   自己的，于是跳过插入；10-02 删掉 direct 规则，删的正是唯一一份，`verify-node` 报
   「递归防护缺失（0 条）」。restart unit 后规则补回，`tailscale status` 里没有 peer 用过 CNI 地址，
   这段空窗没有造成影响。之前巡检看到的「2 条」也是 firewalld 那两条，不是 unit 插的。
3. **playbook**：`cloud/oracle/ansible/playbooks/setup-tailscale.yaml` 改为装同一个 unit，
   并带一个迁移任务（同上，运行时 + 永久配置删除，不 reload）。迁移任务**排在装 unit 之前**；
   删过规则就把 unit 的状态设为 `restarted`（oneshot + RemainAfterExit 时，对已 active 的 unit
   用 `started` 不会重跑 ExecStart）。
4. **巡检**：`scripts/verify-oracle-node.sh` 的护栏检查改为看 iptables，并新增一条断言：
   firewalld 运行时 + 永久配置里的 direct rules/chains/passthroughs 总数必须为 0。

成功判定：

```bash
# 本机仓库根目录
just oracle verify-node        # 「firewalld 无 direct 配置」那条变绿
# 节点上：重启 firewalld 后 Cilium 链仍在（修复前这一步会让 CILIUM 计数归零）
sudo iptables-save | grep -c CILIUM            # 记下数值
sudo systemctl restart firewalld
sudo iptables-save | grep -c CILIUM            # 数值不变
```

回滚：`sudo systemctl disable --now tailscale-no-cni-endpoint`，再用
`firewall-cmd --permanent --direct --add-rule ...` 把旧规则加回（**会恢复 flush 风险**）。

## 四、刻意没做的事

- **没有关 unattended-upgrades，也没有让 needrestart 跳过 firewalld。** 安全更新照常打，
  firewalld 也照常该重启就重启。问题出在 direct 规则让「重启 firewalld」变成了
  「清空别人的 iptables」，去掉 direct 规则后重启是无害的。
- **没有把 Cilium 改成 BPF masquerade 来躲开 iptables。** 那是对 CNI 数据面的改动，要单独评估，
  不该夹带在一次故障修复里。只要 flush 不再发生，iptables masquerade 就是安全的。
- **没有撤掉 08-12 加的 1.1.1.1 / 1.0.0.1 上游。** 它解决的单上游问题是真实存在的，
  只是解决不了这一次。
