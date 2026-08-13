# 多上游 DNS 冗余修复引入 SERVFAIL → oracle 上所有 musl 容器的外网解析变成抽签

> 日期: 2026-08-13（回归始于 2026-08-12 落地 `DNS=1.1.1.1 1.0.0.1` 的那一刻）
> 影响: oracle-k3s 上**所有 Alpine/musl 镜像**的 pod 解析外部域名阵发性整体失败
>       （实测同一 pod 连续 30 次 curl 可以 0/30 全败，几十秒后又 30/30 全过）。
>       首个撞上的是夜间备份：`restic-backup-29776050` 三次尝试全挂 → `KubeJobFailed`
>       告警，**当晚 oracle 侧无备份**（08-12 03:30 那次成功，缺口 = 1 晚）
> 根因: 公网递归解析器对 OCI 私有后缀 `*.vcn<id>.oraclevcn.com` 答 **SERVFAIL**（不是
>       NXDOMAIN）；**musl 在 search 域遍历中遇到 SERVFAIL 会放弃整轮**，裸域名根本没被查过
> 结果: 给 `oraclevcn.com` 单开 CoreDNS server 块只转发 OCI 解析器
>       （`cloud/oracle/manifests/base/coredns-custom.yaml`）；补跑备份已成功

## 一句话根因

**2026-08-12 为了消除「CoreDNS 只有 OCI 一个上游」这个单点，给节点加了
`DNS=1.1.1.1 1.0.0.1`。但公网解析器对 VCN 私有后缀答的是 SERVFAIL 而不是 NXDOMAIN，
而 musl 只在 NXDOMAIN 时才继续走下一个 search 域 —— 于是 pod 每次解析外部域名，
都有一定概率在第一跳就被判死。**

## 完整链条

```
OCI DHCP  →  节点 resolv.conf 带 `search vcn11052309.oraclevcn.com`
          →  kubelet 把它接到 Pod search 列表末尾，配 ndots:5
          →  pod 解析 dl-cdn.alpinelinux.org（2 个点 < 5）先探
             dl-cdn.alpinelinux.org.vcn11052309.oraclevcn.com
          →  CoreDNS `forward . /etc/resolv.conf`，上游池 random 挑一个：
                1.1.1.1 → SERVFAIL   1.0.0.1 → SERVFAIL   169.254.169.254 → NXDOMAIN
          →  musl 收到 SERVFAIL：放弃整轮 search，裸域名不查了 → "bad address"
          →  CoreDNS 的 cache 把 SERVFAIL 也缓存几秒 → 故障呈阵发，几秒黑几十秒好
```

实测证据（修复前，均在 oracle-k3s 上）：

| 探测 | 结果 |
|------|------|
| 节点上 `curl` CDN ×30 | **30/30 成功**（节点走 glibc + resolved，不受影响）|
| Alpine pod 里 `curl` 同一 URL ×30 | **0/30**，全部 `Could not resolve host` |
| Alpine pod 里 `apk update` ×20 | 18/20（换个时间窗口就变） |
| **Debian pod** 里 `getent hosts` ×40 | **40/40 成功** ← glibc 会继续走下一个 search 域 |
| `dig @10.53.0.10 <name>.vcn11052309.oraclevcn.com` ×20 | **20/20 SERVFAIL** |
| `dig @169.254.169.254` 同名 | NXDOMAIN（OCI 自己的解析器答得对）|

为什么同一个备份脚本里的 `pg_dump` 从来没出过事：`apps-pg-rw.databases.svc` 在
`cluster.local` 那几个后缀就命中了，**走不到 oraclevcn 这一跳**。只有需要走完整个
search 列表的外部域名才会中招。

## 最该记住的一条：这次回归，评审时**看见了**，但把后果判错了

`setup-k3s.yaml` 里那段 drop-in 的注释白纸黑字写过这个副作用：

> 「oraclevcn.com 内部名会有部分查询随机打到 1.1.1.1 → NXDOMAIN：集群无任何 VCN
> 内部名依赖（cluster.local 由 kubernetes 插件应答），**行为等价，可接受**。」

两处都错：

1. **rcode 判错**：不是 NXDOMAIN，是 **SERVFAIL**。这两个对解析器完全不等价——
   NXDOMAIN 是「确定不存在，继续找」，SERVFAIL 是「解析器坏了，别猜」。musl 据此
   放弃整轮 search；glibc 则宽容。**同一个上游改动，换个 libc 就是两种结局。**
2. **受害者判错**：以为受影响的是「VCN 内部名」（集群确实不依赖），实际受影响的是
   **所有外部域名**——因为那个后缀是 *search* 域，它出现在每一次外部解析的路径上，
   而不只是在解析 VCN 名字时。

而 2026-08-12 的验收演练（iptables 掐死 `169.254.169.254:53` 30 秒，pod 内 4 个域名
全部解析成功）**恰好看不见它**：演练把 OCI 上游掐了，查询必然落到 1.1.1.1，
此时 search 探针拿到 SERVFAIL……但那 4 个域名是用什么工具查的、在哪个镜像里查的，
决定了结果。**演练验证的是「备胎能不能顶上」，而回归恰恰是「备胎顶上之后的语义差异」。**

同一形状的教训见 [2026-08-11 Gateway API CRD 停摆](2026-08-11-gateway-api-crd-stall.md)：
升级注释里明确考虑过那条 breaking change，验证方式恰好绕开了它。
**「评审时想到了」不等于「验证覆盖了」。**

## 为什么拖到备份失败才被发现

- 阵发（几秒级）+ 只打 musl，人手动点服务基本撞不上；
- 撞上的负载多数会自愈重试，不产生告警；
- `cloudflared`/`uptime-kuma` 等长驻进程解析结果有缓存，回归后仍在跑；
- **备份 Job 是唯一「一启动就必须连外网装包、失败即整体退出」的负载** —— 它成了这次
  的金丝雀。`backoffLimit: 2` 的三次重试全落在同一个坏窗口里（三个 pod 相隔约 60 秒）。

⚠️ 注意 2026-07-16 曾把 `backoffLimit` 1→2，注释写的是「transient SSH/Tailscale
failures」。现在看，**那多半也是这类 DNS 抽签**（apk 装包早于任何 SSH 动作），
当时按「偶发抖动」处理，症状被压住了一年半的一半——**重试次数是止痛药，不是诊断。**

## 修复

给 `oraclevcn.com` 单开一个 CoreDNS server 块，只转发给 OCI 自己的解析器，让 search
探针稳定拿到 NXDOMAIN，musl 就会继续走到裸域名：

```
oraclevcn.com:53 {
    errors
    cache 30
    forward . 169.254.169.254
}
```

落点 `cloud/oracle/manifests/base/coredns-custom.yaml`（ConfigMap `coredns-custom`，
k3s 内置 Corefile 末尾的 `import /etc/coredns/custom/*.server` 是唯一扩展点；
`reload` 插件约 1–2 分钟自动生效，**不要改 Corefile 本体**，k3s 启动会覆盖它）。
经 `cloud/oracle/manifests/kustomization.yaml` 随 `oracle-k3s` App 走 GitOps。

**刻意保留多上游冗余**（`DNS=1.1.1.1 1.0.0.1` 不回滚）：2026-08-01 那个单点是真的，
这次要修的是「私有后缀不该问公网」，两件事不冲突。

### 验收（修复后实测）

| 检查 | 修复前 | 修复后 |
|------|--------|--------|
| `dig @10.53.0.10 <name>.vcn11052309.oraclevcn.com` ×30 | 20/20 SERVFAIL | **30/30 NXDOMAIN** |
| Alpine pod 里跑备份脚本原句 `apk add restic openssh-client postgresql17-client findutils` ×25 | 阵发失败（最差 0/30） | **25/25 成功** |
| 补跑 `restic-backup-manual-20260813` | — | **Complete**（见下） |

## 处置

1. `cloud/oracle/manifests/base/coredns-custom.yaml` 新增并入 kustomization（GitOps）。
2. `setup-k3s.yaml` 里那段判断错误的注释已就地更正——**留着原文并标明错在哪**，
   否则下一个读到「行为等价，可接受」的人会再信一次。
3. 补跑当晚缺失的备份（`kubectl create job --from=cronjob/restic-backup`），成功后
   删掉 `restic-backup-29776050` 失败 Job，`KubeJobFailed` 告警随之消除。

## 仍然开放的（未在本次修）

- **备份 Job 每晚要连公网装包**：`apk add restic openssh-client postgresql17-client
  findutils` 是它的第一步，也是它**唯一的公网依赖**（pg_dump 走 cluster.local，
  restic 推 106 走 Tailscale 裸 IP）。本次根因修掉后这条链稳了，但「最后一道防线
  每晚依赖一个外部 CDN」本身仍是脆的。彻底的做法是照 `images/squoosh` 的既有模式
  自建一个多架构镜像把工具烤进去（oracle 是 **arm64**，homelab 是 amd64，两边共用）。
  未做——属于独立变更，且需要先建 ghcr 包并把可见性设为 Public。
- **无告警覆盖「pod 外网解析失败」**：这次是备份 Job 当金丝雀才暴露的。若要加固，
  可给 CoreDNS 的 `coredns_dns_responses_total{rcode="SERVFAIL"}` 加一条告警规则。
