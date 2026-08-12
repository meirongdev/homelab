# systemd-networkd 清扫外来 ip rule——fwmark 撞车防护双节点静默失守，homepage 中签断连

> 日期: 2026-08-12（失守发生于 2026-08-11 清晨）
> 影响: 两台 k8s 节点的 ip rule 防护（5200 CGNAT 钉死 + homelab 另有 5260 LAN 直通）
>       **全部被清**，持续约 33 小时无人知晓。期间 oracle 的 homepage（identity 138760，
>       低字节 0x08 中签）到整个 100.64/10 黑洞；备份/遥测碰巧都没中签，实际业务损失 ≈ 0，
>       但 otel remote-write、restic 夜备全在抽签池里——纯属运气。
> 根因: systemd-networkd 的 `ManageForeignRoutingPolicyRules` **默认 yes**：(重)启动/重配
>       时清扫一切非它管理的 ip rule。8-11 清晨 unattended-upgrades 重启两台节点的
>       networkd（homelab 06:17 / oracle 06:40），防护规则同批被清。tailscaled 的四条
>       规则（5210-5270）有 netlink 监听、被清后秒级自愈；自定义规则没有守护者。
> 结果: 两道防线 + 指标看护（见下），旧 oneshot 单元退役；A/B 实测抓到现行并验证修复。
> 触发: 双集群例行 review 时人肉发现——单元 `active (exited)` 而 `ip rule` 里没有规则。

## 一句话根因

**"开机 oneshot 加一条 ip rule"守不住一个会被别人清场的表。** networkd 认为
不是它配置的 routing policy rule 都该删（`ManageForeignRoutingPolicyRules=yes`
是默认值），而 oneshot 单元跑完就退场，规则被清后没有任何东西负责补。

## 时间线（全部实测）

| 时间 | homelab (k8s-node) | oracle (node0) |
|---|---|---|
| 08-08 07:01 | 节点重启；`nfs-lan-route`(5260) 随 boot 加上 | — |
| 08-09 13:39 | ansible 加 `tailscale-cgnat-route`(5200)（fwmark 撞车修复当天） | 同批预防性加 5200 |
| 08-11 03:00 | — | 节点重启，oneshot 随 boot 重加 5200 |
| **08-11 06:17 / 06:40** | **unattended-upgrades 重启 systemd-networkd → 5200+5260 被清** | **同一批次重启 networkd → 5200 被清** |
| 08-12 下午 | review 发现：单元 active(exited)，规则不在；homepage 中签断连 | 同左 |

关键排除项：homelab 的 tailscaled 自 08-08 起**零重启**（journal 为证），但 08-09
加的规则照样没了——一度怀疑的"tailscaled 清场"不成立（后有受控实验直接证伪）。

## 破案三线索

1. **pve 是幸存者对照组**。pve 上同款手工 5260 单元一直健在——它是 Proxmox，
   用 ifupdown2，不跑 systemd-networkd。同规则、同 tailscaled、不同网络管理器，
   只有跑 networkd 的两台丢规则。
2. **journal 时间相关**。两台节点的 networkd 在 8-11 清晨同一批 unattended-upgrades
   窗口重启（06:17 / 06:40），恰在"规则最后确认在位"与"发现丢失"之间。
3. **tailscaled 洗脱嫌疑**。受控重启 homelab 的 tailscaled（systemd-run 分离执行，
   t+3s / t+30s 采样）：5200/5260 全程在位，`reasserts_total` 纹丝不动。

## A/B 实锤（oracle，systemd-run 分离执行）

```
23:11:01  规则在位（5200 ✓）
          systemctl restart systemd-networkd   # 默认配置
23:11:05  5200 消失；tailscaled 的 5210-5270 在位（它有 netlink 监听自愈）← 抓到现行
          写入 drop-in: ManageForeignRoutingPolicyRules=no + ManageForeignRoutes=no
          systemctl restart systemd-networkd   # 新配置
23:12:28  重新断言后规则在位
          systemctl restart systemd-networkd   # 幸存测试
23:12:32  5200 仍在位 ← 修复验证通过
```

homelab 同款幸存测试：装 drop-in 后重启 networkd，5200+5260（计数 2）前后不变。

受害面实锤（修复前，同节点同目标同一分钟）：homepage（identity 138760，低字节
0x08）wget `100.94.186.7:31090` **超时**；it-tools（identity 185415，低字节 0x47）
**秒通**。手工重申 5200 后 homepage 当场恢复。

## 修复：两道防线 + 指标看护

落在两个 `setup-tailscale.yaml` playbook（内容按节点差异化），节点侧已部署并
与 git 内容做过 sha256 对照：

1. **根因**：`/etc/systemd/networkd.conf.d/10-no-foreign-sweep.conf`
   （`ManageForeignRoutingPolicyRules=no` + `ManageForeignRoutes=no`——后者是同机制
   的相邻地雷：table 52 与 Cilium 的路由对 networkd 同样是"外来"的）。
2. **兜底**：`assert-tailscale-ip-rules` 幂等断言脚本 + `tailscale-ip-rules.timer`
   每 5 分钟重申，单次运行两遍断言夹 20s；对**任何**删除者收敛，失守窗口 ≤5 分钟。
   旧的 `nfs-lan-route.service` / `tailscale-cgnat-route.service` 退役
   （⚠️ 它们的 ExecStop 会顺手删规则，迁移序列里要立即重申补回）。
3. **可见性**：脚本写 node-exporter textfile（`tailscale_iprule_present` /
   `tailscale_iprule_reasserts_total`），两侧 node-exporter 开 textfile collector
   （路径复用已挂载的 `/host/root`，零新增挂载），5 条告警覆盖
   「规则补不回 / 拉锯战 / 指标停更(mtime) / 逐集群 absent」——
   `alerts/tailscale-iprule-alerts.yaml`。

## 两个反直觉实测（改这套机制前先读）

- **tailscaled 重启不清这些规则**。5200-5299 虽像"它的地盘"，受控重启证明它只管
  自己的四条。真正的清扫者是 networkd。
- **`PartOf=tailscaled` 对已死的 oneshot 不触发**。设计初稿指望它在 tailscaled
  重启后连带重跑断言，受控重启中单元毫无动静——restart 传播对 inactive 单元是
  空操作。timer 是唯一可靠的重申机制，别把 PartOf 加回去当保证。

## 教训

- **修复本身也会死，而且死得比故障更安静。** 一条规则、一个 oneshot 单元，
  `systemctl status` 永远绿——守护措施必须要么收敛（timer 重申）、要么可观测
  （指标+告警），最好两者都有。这与 SLO NaN（同日 records）是同一母题：
  看起来在工作 ≠ 在工作。
- **unattended-upgrades 是被低估的变更来源。** 没人"动过"节点，但 systemd 升级
  重启了 networkd，行为等价于一次配置回滚。排障时间线要把包管理器算进去
  （`journalctl -u systemd-networkd` + `/var/log/apt/history.log`）。
- **找一个幸存者当对照组。** pve 不跑 networkd 这条差异直接把嫌疑从 tailscaled
  转向 networkd，比蹲 `ip monitor rule` 便宜得多。
- **受控实验要做两个方向**：抓现行（旧配置复现删除）+ 幸存测试（新配置抵抗删除），
  只做后者会把"没复发"误当"修好了"。
