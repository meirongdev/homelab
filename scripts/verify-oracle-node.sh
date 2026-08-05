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
echo "fallbackdns=$(grep -h FallbackDNS /etc/systemd/resolved.conf.d/*.conf 2>/dev/null | head -1 | cut -d= -f2)"
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
  [ -n "$(g fallbackdns)" ] && ok "DNS 备用上游已配：$(g fallbackdns)" \
    || bad "无 FallbackDNS —— 单点 169.254.169.254 曾致全网 ~20min 不可达"
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
if [ -z "$NJ" ]; then
  bad "取不到 node ${NODE} —— apiserver 不可达？"
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
head_ "工作负载"
BADPODS=$(kubectl --context "$CTX" get pods -A --no-headers 2>/dev/null | awk '$4!="Running" && $4!="Completed"')
[ -z "$BADPODS" ] && ok "所有 pod Running/Completed" || { bad "异常 pod:"; echo "$BADPODS" | sed 's/^/       /'; }
PENDING=$(kubectl --context "$CTX" get pods -A --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')
[ "$PENDING" = "0" ] && ok "无 Pending pod" || bad "${PENDING} 个 Pending —— 通常是 requests 装不下或 anti-affinity 死锁"
APPBAD=$(kubectl --context "$CTX" -n argocd get app -A --no-headers 2>/dev/null | awk '$3!="Synced" || $4!="Healthy"')
[ -z "$APPBAD" ] && ok "全部 ArgoCD App Synced/Healthy" || { bad "App 异常:"; echo "$APPBAD" | sed 's/^/       /'; }

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
