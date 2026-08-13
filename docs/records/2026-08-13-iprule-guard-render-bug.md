# ip rule 收敛器渲染 bug：断言塌成一行，防线名存实亡而规则"看起来在位"

> 日期: 2026-08-13
> 影响: worker `k8s-worker-106` 的 ip rule 收敛器自入编起（07:14）完全失效约 3 小时——
>       规则本身在位（setup 时一次性加对），**无实际断连**；但期间任何清扫都将无法自愈，
>       等价于回到 8-11 那次 33h 静默失守的前夜。连带发现并修复 master 缺 5240
>       规则（后者让 `hosts: k8s_masters` 的全部剧本坏了一天）。
> 根因: `7abd676` 把断言行改成 Jinja `join('\n          ')`——在 YAML 块标量里
>       Jinja 拿到的是**字面反斜杠+n**，整段 assert 渲染成一行；shell 把 `52\n` 吃成
>       `52n`，`ip rule add` 每轮报 `invalid table ID`。
> 定性者: `TailscaleIpRulePersistentlyMissing` 告警（8-12 加的那批）——**真阳性**。

## 时间线

- 07:14 worker 入编（`7abd676` 首次把 assert 行模板化，worker 是第一个吃到新渲染的节点）。
- 07:14 起 `TailscaleIpRulePersistentlyMissing{instance="192.168.50.107:9100", priority="5200"}`
  开始 firing。
- ~10:00 例行体检看到告警，上节点取证；10:04 修复上线三节点，告警恢复。

## 故障机制：一个 bug，三层伤害

deployed 脚本里的实际内容（`cat -A` 取证）：

```
assert 5200 to 100.64.0.0/10 lookup 52\n          assert 5260 to 192.168.50.0/24 lookup main
```

`\n` 是字面两个字符。sh 分词时反斜杠转义掉 `n` → token 是 `52n`，于是**一次** `assert`
调用带着两条规则的全部参数跑：

1. **5200 每轮 add 失败**：`Error: argument "52n" is wrong: invalid table ID`——
   收敛器对它已无收敛能力，规则当时在位只因 setup 剧本当初直接加对过一次。
2. **第二条起的规则连 metric 序列都不产生**：只有 `present{priority="5200"} 0` 这一条
   序列。`PersistentlyMissing`（`present == 0`）对 5240/5260 **永远不可能 fire**——
   absent series 不参与 `== 0`（PromQL 的老陷阱，`promql-absent-and-per-target-split`
   同款）。这次是 5200 恰好排在第一、恰好有序列且恰好为 0，告警才响；若塌行方式稍有
   不同，一条告警都不会有。
3. **master 是延迟引信**：它还在跑模板化之前部署的旧版好脚本，所以无告警；但下一次
   对 master 重跑 playbook 就会拿到同样的坏渲染。"master 没告警"不等于"repo 没 bug"。

## 为什么 `join('\n')` 会输出字面 `\n`

playbook 的脚本体是 YAML 块标量（`content: |`）：YAML 对块标量**不处理转义**，Jinja
表达式源码里的 `\n` 两个字符原样进入模板；该表达式又位于块标量上下文中，Ansible 渲染
后落盘的就是字面 `\n          `。**结论**：在 YAML 块标量里生成多行内容，永远用
`{% for %}` 逐行展开（真实换行由模板文本自身携带），不要依赖字符串转义；上线前
`ansible-playbook --check --diff` 看渲染差异，30 秒就能抓住。

## 修复（全部当日上线，三节点验证）

1. **渲染**：`join('\n          ')` → `{% for rule in tailscale_assert_rules %}` 逐行展开
   （`k8s/ansible/playbooks/setup-tailscale.yaml`）。
2. **规则清单统一**：master/worker 共用一份三条（5200/5240/5260）。此前 5240 只给
   worker（inventory 覆盖），实际 master 同样需要——它自己网段的回包被劫进隧道，
   pve 的 ProxyCommand 路径因此非对称超时（[worker 入编复盘 §4](2026-08-13-k3s-worker-join-106.md)
   当时标"未修"）。手工 `ip rule add to 10.10.10.0/24 lookup main priority 5240` 后
   `ip route get 10.10.10.1` 由 `tailscale0 table 52` 翻回 `eth0` 直连，ProxyCommand
   实测恢复，随后由统一清单固化。inventory 的 `k8s_workers` 覆盖段删除。
3. **对账锁（防同类塌行复发）**：脚本新增 `tailscale_iprule_rules_expected` 指标——
   条数由 **Jinja 静态渲染**（`| length`），不经过 shell，塌行时它仍是真值。配两条新告警
   （`tailscale-iprule-alerts.yaml`）：
   - `TailscaleIpRuleSeriesIncomplete`：`count(present) < expected`（本次事故的形态）；
   - `TailscaleIpRuleExpectedMissing`：有 present 没 expected（节点跑旧版脚本，对账锁对它是盲的）。
   oracle 的同名脚本无此 bug（assert 行是硬编码），补了 expected（写死 1）保持对账覆盖。
4. **部署**：`ansible-playbook … --start-at-task "Ensure networkd drop-in directory exists"`
   跳过 tailscale up 段，只重铺收敛器（master 经修好的 ProxyCommand、worker 走 LAN、
   oracle 走 tailnet）。验证判据：journal 无 `invalid table ID`；`.prom` 里 present=1 的
   序列数 == expected；master `ip rule` 含 5240。

## 教训

- **收敛器要验"每轮执行成功"，不是验"规则在位"**。规则在位可能是历史遗产；
  `journalctl -u tailscale-ip-rules -n 20` + `.prom` 内容才是收敛器活着的证据。
- **告警响了 ≠ 失效面都被看见**。这次 5 条告警只有 1 条响，且响的是三条规则中的一条；
  监控自身的完整性需要一个**不走同一故障路径**的对账值（expected 由模板静态渲染，
  正是因为它不经过会塌行的 shell）。
- **模板改动的验收要看渲染产物**（`--check --diff`），别只看 playbook 跑绿——
  `copy` 模块把坏内容原样铺下去照样 `changed: ok`。
