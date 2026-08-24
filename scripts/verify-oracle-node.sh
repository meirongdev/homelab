#!/usr/bin/env bash
# oracle-k3s 节点重启/变更后的巡检 —— 一条命令代替一堆手工 kubectl。
#
# 由来：2026-08-05 手工把 VM 改成 2 OCPU/12GB 并重启后，逐项验收花了二十来条命令，
# 而且**漏项就是静默的**：当天就漏了 runbook 步骤 2（hugepages + kubelet-arg），
# 症状只有一个不显眼的数字（capacity−allocatable 差额 == 2048Mi）。
# 本脚本把每条不变量固定下来，任何一条不成立就非零退出。
#
# 用法（在 cloud/oracle/ 下）:  just verify-node
# 直接跑:                        bash scripts/verify-oracle-node.sh
#
# ⚠️ 只读。不改集群、不改节点。
#
# 相关：docs/runbooks/oracle-k3s-shape-downsize.md（缩容 SOP，步骤 6 是本脚本的来源）
#      docs/reference/tailscale-network.md（跨集群网络的判据）
# 静态检查豁免（2026-08-10 补）。⚠️ 说明行不能以「# shellcheck」开头——那样会被当成
# 指令去解析（SC1072/1073），真正的 disable 指令在本段最后一行。
# 本文件加进来时 CI 的 shellcheck 步骤就红了，
# 一直没人注意到——22 条命中全在这一个文件，且全是最低的 note 级。逐条理由：
#   SC2015 (17处) `[ cond ] && ok "…" || bad "…"` 是本脚本的核心写法。该模式的陷阱是
#           「B 失败时 C 也会跑」，而 ok()/bad() 只做 printf+计数、恒返回 0，不成立。
#           改写成 17 个 if/else 只会让每条不变量从 1 行变 3 行，反而更难读。
#   SC2001  `sed 's/^/       /'` 是给多行输出整体加缩进，${var//} 干不了这个。
#   SC2016  第 32 行单引号包的是**要送到远端执行**的脚本，本地不展开正是本意。
#   SC2153  ALLOC_CPU 由 eval 从 python 输出里赋值，shellcheck 看不见，误报。
# ⚠️ 不要在这里加 SC2086——CI 特意跑默认全等级就是为了抓未加引号的变量。
# shellcheck disable=SC2015,SC2001,SC2016,SC2153
set -uo pipefail

CTX="${ORACLE_CTX:-oracle-k3s}"
HL_CTX="${HOMELAB_CTX:-k3s-homelab}"
NODE="${ORACLE_NODE:-oracle-k3s}"
TS_IP="${ORACLE_TS_IP:-100.107.166.37}"
SSH="ssh -i ${SSH_KEY:-$HOME/.ssh/vgio} -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@${TS_IP}"

pass=0; fail=0
ok()   { printf '  \033[32m✅\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m❌\033[0m %s\n' "$1"; fail=$((fail+1)); }
warn() { printf '  \033[33m⚠️\033[0m  %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── 主机层（这些都是重启会重新走一遍的路径）────────────────────────────────
head_ "主机层 (ssh ${TS_IP})"
HOST=$($SSH 'set -u
IF=$(ip -o route get 8.8.8.8 2>/dev/null | awk "{print \$5; exit}")
echo "hugepages=$(awk "/HugePages_Total/{print \$2}" /proc/meminfo)"
echo "microk8s_leftover=$(ls /etc/sysctl.d/ 2>/dev/null | grep -c microk8s-hugepages)"
echo "kubelet_arg=$(grep -c "system-reserved" /etc/rancher/k3s/config.yaml 2>/dev/null)"
echo "eviction_arg=$(grep -c "eviction-hard" /etc/rancher/k3s/config.yaml 2>/dev/null)"
echo "gro=$(sudo ethtool -k "$IF" 2>/dev/null | awk -F": " "/rx-udp-gro-forwarding/{print \$2}")"
echo "dispatcher=$(systemctl is-enabled networkd-dispatcher 2>/dev/null)"
echo "gro_script=$([ -x /etc/networkd-dispatcher/routable.d/50-tailscale-ethtool ] && echo yes || echo no)"
echo "ipfwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
echo "guard=$(sudo firewall-cmd --permanent --direct --get-all-rules 2>/dev/null | grep -c 41641)"
echo "fwdpolicy=$(sudo iptables -S FORWARD 2>/dev/null | awk "/^-P FORWARD/{print \$3}")"
echo "resolv_extra=$(awk "/^nameserver/{print \$2}" /run/systemd/resolve/resolv.conf 2>/dev/null | grep -vFx 169.254.169.254 | tr "\n" " ")"
echo "dropin_dns=$(sed -n "s/^DNS=//p" /etc/systemd/resolved.conf.d/*.conf 2>/dev/null | head -1)"
echo "dropin_fbonly=$(sed -n "s/^FallbackDNS=//p" /etc/systemd/resolved.conf.d/*.conf 2>/dev/null | head -1)"
echo "ts_routes=$(sudo tailscale debug prefs 2>/dev/null | tr -d " \n" | grep -o "\"AdvertiseRoutes\":\[[^]]*\]")"
echo "k3s=$(systemctl is-active k3s)"
echo "tailscaled=$(systemctl is-active tailscaled)"
' 2>/dev/null)
[ -z "$HOST" ] && { bad "SSH 到 ${TS_IP} 失败 —— 后续主机层检查全部跳过"; HOST=""; }
g() { echo "$HOST" | awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print}'; }

if [ -n "$HOST" ]; then
  [ "$(g hugepages)" = "0" ] && ok "hugepages 已归零（那 2GiB 没被白占）" \
    || bad "hugepages = $(g hugepages) —— 2GiB 被锁成 hugetlb 且从未被用；见 runbook 步骤 2"
  [ "$(g microk8s_leftover)" = "0" ] && ok "microk8s 装机残留 sysctl 已清除" \
    || bad "/etc/sysctl.d/20-microk8s-hugepages.conf 又回来了"
  [ "$(g kubelet_arg)" -ge 1 ] 2>/dev/null && ok "k3s config 含 system-reserved" \
    || bad "k3s config **缺** system-reserved —— 调度器会当整机内存都能分给 pod"
  [ "$(g eviction_arg)" -ge 1 ] 2>/dev/null && ok "k3s config 含 eviction-hard" \
    || bad "k3s config 缺 eviction-hard —— 默认 100Mi 在 12GB 机器上太晚，内核 OOM 会先动手"
  [ "$(g gro)" = "on" ] && ok "rx-udp-gro-forwarding = on（Tailscale 吞吐）" \
    || bad "rx-udp-gro-forwarding = $(g gro)（期望 on）"
  { [ "$(g dispatcher)" = "enabled" ] && [ "$(g gro_script)" = "yes" ]; } \
    && ok "GRO 修复已持久化（networkd-dispatcher + drop-in 脚本）" \
    || bad "GRO 修复未持久化 → 下次重启会丢（dispatcher=$(g dispatcher) script=$(g gro_script)）"
  [ "$(g ipfwd)" = "1" ] && ok "net.ipv4.ip_forward = 1" || bad "ip_forward = $(g ipfwd)"
  [ "$(g guard)" -ge 2 ] 2>/dev/null && ok "firewalld 递归防护规则在（$(g guard) 条 41641）" \
    || bad "firewalld 递归防护缺失（$(g guard) 条）—— 可能出现 WireGuard-over-VXLAN-over-WireGuard"
  # pod↔pod 转发靠的是 policy ACCEPT（+ Cilium 自己的 CILIUM_FORWARD 链），不是显式
  # 的 -A FORWARD ACCEPT 规则 —— 那两条 2026-08-05 已从 playbook 删除：Cilium 重建
  # FORWARD 链时必然把它们丢掉，永远无法收敛。所以这里只查 policy。
  [ "$(g fwdpolicy)" = "ACCEPT" ] && ok "iptables FORWARD policy = ACCEPT" \
    || bad "FORWARD policy = $(g fwdpolicy)（期望 ACCEPT）—— pod↔pod 转发会断"
  # ☠️ 断言的是 /run/systemd/resolve/resolv.conf 里的**实际上游**，不是 drop-in 的字面量。
  # 2026-08-12 定论（records/2026-08-01-oracle-k3s-dns-outage.md「后续」节）：
  # `FallbackDNS=` 只服务 resolved 自己的 stub(127.0.0.53) 路径、**不写进该文件**，
  # 而 kubelet 正是把该文件快照进 CoreDNS pod —— 2026-08-01 真正断掉的就是这条集群路径。
  # 本检查第一版 grep "FallbackDNS"，两头都错：对现行正确配置（DNS=1.1.1.1 1.0.0.1）误报，
  # 而若有人为了消红把 FallbackDNS= 加回来反倒变绿 —— 把已证伪的那版修复认成合格。
  # 2026-08-23 改为直接断言生效结果（当天复盘 Telegram 告警时它正误报着这一条）。
  if [ -n "$(g resolv_extra)" ]; then
    ok "DNS 上游冗余生效：resolv.conf 含非 OCI 上游 $(g resolv_extra)（kubelet 快照给 CoreDNS）"
  elif [ -n "$(g dropin_fbonly)" ]; then
    bad "只有 FallbackDNS=$(g dropin_fbonly) —— 2026-08-12 已证伪该版无效（不进 resolv.conf，CoreDNS 上游仍是单点 OCI）；改用 DNS="
  else
    bad "resolv.conf 上游只有 169.254.169.254 —— 单点曾致全网 ~20min 不可达；见 setup-k3s.yaml 的 10-oci-fallback.conf"
  fi
  # ⚠️ 期望**只有**本节点 /32：Pod CIDR 子网路由 2026-07-07 已移除，跨集群走 ClusterMesh VXLAN
  case "$(g ts_routes)" in
    *10.52.0.0/16*) bad "Tailscale 又在广播 Pod CIDR 10.52.0.0/16 —— 2026-07-07 已废弃该设计" ;;
    *10.0.0.26/32*) ok "Tailscale 广播仅本节点 /32（符合 underlay-only 设计）" ;;
    *)              warn "AdvertiseRoutes 取不到或异常：$(g ts_routes)" ;;
  esac
  { [ "$(g k3s)" = "active" ] && [ "$(g tailscaled)" = "active" ]; } \
    && ok "k3s / tailscaled 均 active" || bad "k3s=$(g k3s) tailscaled=$(g tailscaled)"
fi

# ── 节点账目 ───────────────────────────────────────────────────────────
head_ "节点账目 (context ${CTX})"
NJ=$(kubectl --context "$CTX" get node "$NODE" -o json 2>/dev/null)
# apiserver 可达性作为下游检查的前置条件。2026-08-10 踩到：关掉云侧 6443 后本机
# kubeconfig（当年按公网 IP 生成）连不上，而「工作负载」那几项是
# `kubectl ... 2>/dev/null` 后判断输出**是否为空**——连不上时输出也是空，于是
# 报了 3 个假绿灯。静默失败和「一切正常」长得一模一样，必须显式区分。
if [ -z "$NJ" ]; then
  bad "取不到 node ${NODE} —— apiserver 不可达？（context ${CTX} 的 server: $(kubectl config view -o jsonpath="{.clusters[?(@.name=='${CTX}')].cluster.server}" 2>/dev/null)）"
else
  eval "$(echo "$NJ" | python3 -c "
import json,sys
n=json.load(sys.stdin); c=n['status']['capacity']; a=n['status']['allocatable']
def mi(v): return int(v[:-2])//1024
print('CAP_CPU=%s' % c['cpu'])
print('HP=%s' % c['hugepages-2Mi'])
print('CAP_MEM=%d' % mi(c['memory']))
print('ALLOC_MEM=%d' % mi(a['memory']))
print('ALLOC_CPU=%s' % a['cpu'])
print('READY=%s' % next((x['status'] for x in n['status']['conditions'] if x['type']=='Ready'),'?'))
")"
  [ "$READY" = "True" ] && ok "节点 Ready" || bad "节点 Ready=$READY"
  [ "$HP" = "0" ] && ok "node capacity hugepages-2Mi = 0" \
    || bad "capacity hugepages-2Mi = $HP —— sysctl 清了但 kubelet 没重启，capacity 仍是旧值"
  # 预留生效的判据：差额应远大于 0；只等于 hugepages 说明 kubelet-arg 没生效
  DIFF=$((CAP_MEM-ALLOC_MEM))
  if [ "$DIFF" -ge 2500 ]; then ok "内存预留生效：capacity ${CAP_MEM}Mi − allocatable ${ALLOC_MEM}Mi = ${DIFF}Mi"
  elif [ "$DIFF" = "2048" ]; then bad "差额恰好 2048Mi = 纯 hugepages → **system-reserved 未生效**（典型漏项）"
  else bad "内存预留异常：差额仅 ${DIFF}Mi（期望 ≈3060Mi）"; fi
  case "$ALLOC_CPU" in
    "$CAP_CPU"|"${CAP_CPU}000m") bad "allocatable cpu == capacity（${ALLOC_CPU}）→ system-reserved 的 cpu 未生效" ;;
    *) ok "allocatable cpu = ${ALLOC_CPU}（capacity ${CAP_CPU}，已扣预留）" ;;
  esac

  REQ=$(kubectl --context "$CTX" describe node "$NODE" 2>/dev/null | awk '/^  cpu /{gsub(/m/,"",$2); print $2; exit}')
  ALLOC_CPU_M=${ALLOC_CPU%m}; case "$ALLOC_CPU" in *m) ;; *) ALLOC_CPU_M=$((ALLOC_CPU*1000));; esac
  if [ -n "$REQ" ] && [ "$ALLOC_CPU_M" -gt 0 ]; then
    PCT=$((REQ*100/ALLOC_CPU_M))
    [ "$PCT" -lt 85 ] && ok "CPU requests ${REQ}m / ${ALLOC_CPU_M}m = ${PCT}%（<85%）" \
      || bad "CPU requests ${REQ}m / ${ALLOC_CPU_M}m = ${PCT}% —— 余量不足，CronJob 可能排不进"
  fi
fi

# ── 工作负载 ───────────────────────────────────────────────────────────
# ⚠️ 这三项以前写成 `kubectl ... 2>/dev/null` 再判断输出是否为空 —— apiserver
# 连不上时输出同样是空，于是**报绿**。2026-08-10 关掉云侧 6443 后本机 kubeconfig
# 失联，就是这么骗过巡检的（3 个假绿灯）。现在一律先看命令退出码，拿不到列表就
# 明确记失败，而不是当成「一切正常」。
head_ "工作负载"
if PODS=$(kubectl --context "$CTX" get pods -A --no-headers 2>/dev/null) && [ -n "$PODS" ]; then
  BADPODS=$(echo "$PODS" | awk '$4!="Running" && $4!="Completed"')
  [ -z "$BADPODS" ] && ok "所有 pod Running/Completed" || { bad "异常 pod:"; echo "$BADPODS" | sed 's/^/       /'; }
  PENDING=$(echo "$PODS" | awk '$4=="Pending"' | wc -l | tr -d ' ')
  [ "$PENDING" = "0" ] && ok "无 Pending pod" || bad "${PENDING} 个 Pending —— 通常是 requests 装不下或 anti-affinity 死锁"
else
  bad "取不到 pod 列表 —— apiserver 不可达，pod/Pending 两项无法判定（不等于正常）"
fi
if APPS=$(kubectl --context "$CTX" -n argocd get app -A --no-headers 2>/dev/null) && [ -n "$APPS" ]; then
  APPBAD=$(echo "$APPS" | awk '$3!="Synced" || $4!="Healthy"')
  [ -z "$APPBAD" ] && ok "全部 ArgoCD App Synced/Healthy" || { bad "App 异常:"; echo "$APPBAD" | sed 's/^/       /'; }
else
  bad "取不到 ArgoCD App 列表 —— apiserver 不可达或 argocd ns 为空（不等于正常）"
fi

# ── ClusterMesh ────────────────────────────────────────────────────────
# 判据是 `retrieved=true`，不是摘要行的 "N/1 ready" —— 见 tailscale-network.md
head_ "ClusterMesh（双向）"
for c in "$CTX" "$HL_CTX"; do
  S=$(kubectl --context "$c" exec -n kube-system ds/cilium -c cilium-agent -- \
        cilium-dbg status --all-clusters 2>/dev/null | sed -n '/ClusterMesh/,/^[A-Z]/p')
  if [ -z "$S" ]; then bad "$c: 取不到 cilium-dbg 状态"; continue; fi
  if echo "$S" | grep -q "retrieved=true"; then
    ok "$c: retrieved=true（$(echo "$S" | grep -oE '[0-9]+ endpoints' | head -1)）"
  else
    bad "$c: **retrieved 不为 true** —— kvstoremesh 那一跳断了。修：cd k8s/helm && just connect-clustermesh 100.94.186.7:32379 100.107.166.37:32379"
    echo "$S" | sed 's/^/       /'
  fi
done

# ── 数据面 ─────────────────────────────────────────────────────────────
head_ "数据面（经 Cloudflare Tunnel → Cilium Gateway）"
for u in https://auth.meirong.dev https://home.meirong.dev; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "$u" 2>/dev/null)
  case "$code" in
    2*|3*) ok "$u → $code" ;;
    *)     bad "$u → ${code:-无响应}" ;;
  esac
done

# ── 结论 ───────────────────────────────────────────────────────────────
printf '\n\033[1m结论: %d 项通过, %d 项失败\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || { echo "→ 逐条对照 docs/runbooks/oracle-k3s-shape-downsize.md"; exit 1; }
echo "→ 全部不变量成立"
