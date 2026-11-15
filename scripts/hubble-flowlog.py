#!/usr/bin/env python3
"""查 Loki 里的 Cilium 流量日志（2026-11-15 起）。

数据链：两集群 Cilium agent 的 hubble 动态导出器（k8s/cilium/values.yaml、
cloud/oracle/values/cilium.yaml 的 hubble.export）把选中的流量写成节点上的 JSON 行
→ otel-collector 的 filelog/hubble-* → Loki（oracle），保留 30 天：
    {service_name="hubble-flows"}     新建连接（TCP 首个 SYN、UDP 首包），画调用图用
    {service_name="hubble-verdicts"}  DROPPED / AUDIT，网络策略翻 enforce 前后取证用

用法（入口是 k8s/helm 的 just 配方）：
    scripts/hubble-flowlog.py edges [--window 7d] [--cluster homelab|oracle-k3s] [--json]
    scripts/hubble-flowlog.py verdicts [--window 24h] [--cluster ...] [--limit 200]

edges 的「次数」是观测次数：跨节点的连接会被源、目的两个节点各记一次，只当量级看。
目的是 pod 时不列 IP（pod IP 会变）；是集群外地址或节点时列 IP。

只用标准库；Loki 经 kubectl 的 service proxy 访问（不需要 port-forward）。
"""
import argparse
import json
import subprocess
import sys
import urllib.parse

CTX = "oracle-k3s"
LOKI = "/api/v1/namespaces/monitoring/services/loki:3100/proxy/loki/api/v1"

# Cilium 保留身份号 → 名字；≥ 2^24 是 CIDR 身份（策略里写过的地址），按 IP 显示。
RESERVED = {1: "host", 2: "world", 3: "unmanaged", 4: "health", 5: "init",
            6: "remote-node", 7: "kube-apiserver", 8: "ingress", 9: "world", 10: "world"}
SHOW_IP = {"host", "world", "remote-node", "kube-apiserver", "unmanaged"}

FIELDS = (
    'cl_src="flow.source.cluster_name", ns_src="flow.source.namespace", '
    'wl_src="flow.source.workloads[0].name", id_src="flow.source.identity", ip_src="flow.IP.source", '
    'cl_dst="flow.destination.cluster_name", ns_dst="flow.destination.namespace", '
    'wl_dst="flow.destination.workloads[0].name", id_dst="flow.destination.identity", ip_dst="flow.IP.destination", '
    'tport="flow.l4.TCP.destination_port", uport="flow.l4.UDP.destination_port"'
)


def side(s):
    # pod 端只留 集群:ns/workload；非 pod 端留身份号和 IP，交给 Python 解释。
    return (f'{{{{ if .ns_{s} }}}}{{{{ .cl_{s} }}}}:{{{{ .ns_{s} }}}}/{{{{ .wl_{s} }}}}'
            f'{{{{ else }}}}~{{{{ .id_{s} }}}}~{{{{ .ip_{s} }}}}{{{{ end }}}}')


def selector(service, cluster):
    sel = f'service_name="{service}"'
    if cluster:
        sel += f',cluster="{cluster}"'
    return "{" + sel + "}"


def loki(path, params):
    url = f"{LOKI}/{path}?{urllib.parse.urlencode(params)}"
    out = subprocess.run(["kubectl", "--context", CTX, "--request-timeout=180s", "get", "--raw", url],
                         capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"Loki 查询失败：{out.stderr.strip()}")
    return json.loads(out.stdout)["data"]["result"]


def name(raw, home):
    """'~6~100.107.166.37' → 'remote-node(100.107.166.37)'；'homelab:ns/wl' → 'ns/wl'（同集群时）。"""
    if raw.startswith("~"):
        _, ident, ip = raw.split("~", 2)
        i = int(ident or 0)
        if i >= 1 << 24:
            return ip
        n = RESERVED.get(i, f"identity:{i}")
        return f"{n}({ip})" if n in SHOW_IP and ip else n
    cl, rest = raw.split(":", 1)
    return rest if (not cl or cl == home) else f"{cl}:{rest}"


def edges(a):
    q = (f'sum by (cluster, src, dst, port, proto) (count_over_time({selector("hubble-flows", a.cluster)} '
         f'| json {FIELDS} '
         f'| label_format src=`{side("src")}`, dst=`{side("dst")}`, port=`{{{{ .tport }}}}{{{{ .uport }}}}`, '
         f'proto=`{{{{ if .tport }}}}tcp{{{{ else }}}}udp{{{{ end }}}}` [{a.window}]))')
    rows = {}
    for r in loki("query", {"query": q}):
        m = r["metric"]
        home = m.get("cluster", "")
        key = (home, name(m.get("src", ""), home), name(m.get("dst", ""), home), m.get("port", ""), m.get("proto", ""))
        rows[key] = rows.get(key, 0) + int(float(r["value"][1]))
    out = [dict(cluster=k[0], src=k[1], dst=k[2], port=k[3], proto=k[4], count=v) for k, v in sorted(rows.items())]
    if a.json:
        json.dump(out, sys.stdout, ensure_ascii=False, indent=1)
        print()
        return
    if not out:
        print(f"（最近 {a.window} 没有流量记录：导出器开了吗？见脚本文件头）")
        return
    w = [max(len(str(r[k])) for r in out) for k in ("cluster", "src", "dst")]
    for r in out:
        print(f'{r["cluster"]:<{w[0]}}  {r["src"]:<{w[1]}}  →  {r["dst"]:<{w[2]}}  {r["port"]:>5}/{r["proto"]}  {r["count"]:>7}')
    print(f"（{len(out)} 条边，最近 {a.window}；次数是观测次数，只当量级看）")


def verdicts(a):
    res = loki("query_range", {"query": selector("hubble-verdicts", a.cluster), "since": a.window,
                               "limit": a.limit, "direction": "backward"})
    lines = []
    for stream in res:
        home = stream["stream"].get("cluster", "")
        for ts, line in stream["values"]:
            f = json.loads(line).get("flow", {})
            src, dst, ip = f.get("source", {}), f.get("destination", {}), f.get("IP", {})
            l4 = f.get("l4", {})
            port = (l4.get("TCP") or l4.get("UDP") or {}).get("destination_port", "")

            def ep(e, addr):
                if e.get("namespace"):
                    wl = (e.get("workloads") or [{}])[0].get("name", "?")
                    return name(f'{e.get("cluster_name", "")}:{e["namespace"]}/{wl}', home)
                return name(f'~{e.get("identity", 0)}~{addr}', home)

            pol = [p.get("name", "?") for p in (f.get("egress_denied_by") or []) + (f.get("ingress_denied_by") or [])]
            lines.append((int(ts), home, f.get("verdict", ""), f.get("traffic_direction", ""),
                          ep(src, ip.get("source", "")), ep(dst, ip.get("destination", "")), str(port),
                          f.get("drop_reason_desc", ""), ",".join(pol)))
    if not lines:
        print(f"（最近 {a.window} 没有 DROPPED / AUDIT 记录）")
        return
    import datetime as dt
    for ts, *rest in sorted(lines):
        t = dt.datetime.fromtimestamp(ts / 1e9).strftime("%m-%d %H:%M:%S")
        print("\t".join([t] + rest))
    print(f"（{len(lines)} 条，最近 {a.window}，最多 {a.limit} 条）")


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("edges", help="汇总调用边")
    e.add_argument("--window", default="7d")
    e.add_argument("--cluster", default="")
    e.add_argument("--json", action="store_true")
    v = sub.add_parser("verdicts", help="列出 DROPPED / AUDIT 明细")
    v.add_argument("--window", default="24h")
    v.add_argument("--cluster", default="")
    v.add_argument("--limit", type=int, default=200)
    a = p.parse_args()
    edges(a) if a.cmd == "edges" else verdicts(a)


if __name__ == "__main__":
    main()
