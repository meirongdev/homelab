#!/usr/bin/env python3
"""Trivy Critical CVE 汇总 + 强制重扫（两集群）。

    summary  只读：每个集群现存的 Critical CVE（按 CVE ID 去重）、报告数、覆盖缺口
    rescan   删含 Critical 的 VulnerabilityReport → 重启 operator → 可选等待回填

为什么要 rescan：改 values 的豁免（ignoreFile）不触发重扫，旧报告会按旧结论再挂最多 24h。
为什么等待回填要单独算：☠️ 缺报告按 0 计，「删了没重建」和「已清零」长得一样。
0 副本 ReplicaSet 上的报告删了就不会回来（operator 只扫当前 revision），这里把它们从
「应回填」里剔掉，否则会一直等。机制见 docs/reference/trivy-cve-ops.md。

入口：`just helm trivy-critical` / `just helm trivy-rescan`（k8s/helm/justfile）。
只用标准库 + kubectl。
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time

DEFAULT_CONTEXTS = ["k3s-homelab", "oracle-k3s"]
NS = "trivy-system"
SYSTEM_NS = {"kube-system", "kube-public", "kube-node-lease", "trivy-system"}
L_KIND = "trivy-operator.resource.kind"
L_NAME = "trivy-operator.resource.name"
L_CONTAINER = "trivy-operator.container.name"


def kubectl_json(ctx: str, *args: str) -> dict:
    out = subprocess.run(["kubectl", "--context", ctx, *args, "-o", "json"],
                         check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def kubectl(ctx: str, *args: str) -> None:
    subprocess.run(["kubectl", "--context", ctx, *args], check=True)


def reports(ctx: str) -> list[dict]:
    return kubectl_json(ctx, "get", "vulnerabilityreports", "-A")["items"]


def critical_count(r: dict) -> int:
    return (r.get("report", {}).get("summary", {}) or {}).get("criticalCount", 0) or 0


def key(r: dict) -> tuple[str, str, str]:
    lab = r["metadata"].get("labels", {})
    return (r["metadata"]["namespace"], lab.get(L_NAME, ""), lab.get(L_CONTAINER, ""))


def excluded_namespaces(ctx: str) -> set[str]:
    dep = kubectl_json(ctx, "-n", NS, "get", "deploy", "trivy-operator")
    for c in dep["spec"]["template"]["spec"]["containers"]:
        for e in c.get("env", []):
            if e.get("name") == "OPERATOR_EXCLUDE_NAMESPACES" and e.get("value"):
                return set(e["value"].split(","))
    return SYSTEM_NS


def zero_replica_replicasets(ctx: str) -> set[tuple[str, str]]:
    items = kubectl_json(ctx, "get", "replicasets", "-A")["items"]
    return {(i["metadata"]["namespace"], i["metadata"]["name"])
            for i in items if (i["spec"].get("replicas") or 0) == 0}


def coverage_gaps(ctx: str, have: set[tuple[str, str, str]]) -> list[str]:
    """运行中 pod 的容器里，哪些没有任何报告。

    跳过 Job 产生的 pod（CronJob 的报告挂在 CronJob 上，名字对不上）；CNPG 的 pod 属主是
    Cluster，报告记的是实例名（= pod 名），按 pod 名对。
    """
    skip = excluded_namespaces(ctx)
    gaps = []
    for p in kubectl_json(ctx, "get", "pods", "-A")["items"]:
        ns = p["metadata"]["namespace"]
        if ns in skip or p.get("status", {}).get("phase") != "Running":
            continue
        owners = p["metadata"].get("ownerReferences") or []
        kind = owners[0]["kind"] if owners else "Pod"
        if kind == "Job":
            continue
        name = p["metadata"]["name"] if kind in ("Pod", "Cluster") else owners[0]["name"]
        for c in p["spec"]["containers"]:
            if (ns, name, c["name"]) not in have:
                gaps.append(f"{ns}/{name}/{c['name']}")
    return sorted(set(gaps))


def summarize(ctx: str) -> int:
    items = reports(ctx)
    crit = [r for r in items if critical_count(r) > 0]
    cves: dict[str, dict] = {}
    for r in crit:
        art = r["report"]["artifact"]
        image = art.get("repository", "") + (f":{art['tag']}" if art.get("tag") else "")
        for v in r["report"].get("vulnerabilities") or []:
            if v.get("severity") != "CRITICAL":
                continue
            e = cves.setdefault(v["vulnerabilityID"], {
                "pkgs": set(), "published": (v.get("publishedDate") or "")[:10], "images": set()})
            e["pkgs"].add(f"{v.get('resource', '')} {v.get('installedVersion', '')} → {v.get('fixedVersion', '')}")
            e["images"].add(image)

    jobs = kubectl_json(ctx, "-n", NS, "get", "jobs")["items"]
    done = sum(1 for j in jobs if (j.get("status", {}).get("succeeded") or 0) > 0)
    print(f"═══ {ctx}：报告 {len(items)} 份，含 Critical {len(crit)} 份，"
          f"去重后 {len(cves)} 个 CVE ID；trivy-system 里 Job {len(jobs)} 个（已完成 {done}）")
    for vid, e in sorted(cves.items(), key=lambda kv: (-len(kv[1]["images"]), kv[0])):
        print(f"  {vid}  披露 {e['published'] or '?'}  {len(e['images'])} 个镜像")
        for pkg in sorted(e["pkgs"]):
            print(f"      包  {pkg}")
        for img in sorted(e["images"]):
            print(f"      镜像 {img}")

    gaps = coverage_gaps(ctx, {key(r) for r in items})
    if gaps:
        print(f"  ⚠️ {len(gaps)} 个运行中容器没有报告（缺报告按 0 计，这些镜像的 CVE 不在上面）：")
        for g in gaps:
            print(f"      {g}")
        print(f"      定因看扫描报错：kubectl --context {ctx} -n {NS} logs deploy/trivy-operator --since=30m"
              " | grep -i 'scan job container'")
    else:
        print("  覆盖率：运行中容器都有报告")
    return len(cves)


def start_rescan(ctx: str) -> set[tuple[str, str, str]]:
    """删含 Critical 的报告并重启 operator，返回「应回填」的报告键。"""
    crit = [r for r in reports(ctx) if critical_count(r) > 0]
    if not crit:
        print(f"═══ {ctx}：没有含 Critical 的报告，不需要重扫")
        return set()
    zero = zero_replica_replicasets(ctx)
    expect, stale = set(), 0
    for r in crit:
        lab = r["metadata"].get("labels", {})
        if lab.get(L_KIND) == "ReplicaSet" and (r["metadata"]["namespace"], lab.get(L_NAME)) in zero:
            stale += 1
        else:
            expect.add(key(r))

    print(f"═══ {ctx}：删除 {len(crit)} 份含 Critical 的报告"
          f"（其中 {stale} 份属 0 副本 ReplicaSet，删后不会重建，本来也会被 TTL 收走）")
    for r in crit:
        kubectl(ctx, "-n", r["metadata"]["namespace"], "delete", "vulnerabilityreport",
                r["metadata"]["name"], "--wait=false")
    # 删报告不能可靠触发 reconcile，必须跟一次 operator 重启（报告是 CR，不随 pod 走）
    kubectl(ctx, "-n", NS, "rollout", "restart", "deploy/trivy-operator")
    kubectl(ctx, "-n", NS, "rollout", "status", "deploy/trivy-operator", "--timeout=300s")
    print(f"  已排队，{len(expect)} 份应回填")
    return expect


def wait_refill(expect: dict[str, set[tuple[str, str, str]]], minutes: int) -> bool:
    deadline = time.time() + minutes * 60
    while True:
        missing = {ctx: e - {key(r) for r in reports(ctx)} for ctx, e in expect.items()}
        print(time.strftime("%H:%M:%S") + " 待回填 " + " · ".join(
            f"{ctx} {len(missing[ctx])}/{len(expect[ctx])}" for ctx in expect), flush=True)
        if not any(missing.values()):
            print("✅ 全部回填。现状：just helm trivy-critical")
            return True
        if time.time() >= deadline:
            print(f"❌ {minutes} 分钟内没有回填完，缺：")
            for ctx, m in missing.items():
                for k in sorted(m):
                    print(f"    {ctx}  {'/'.join(k)}")
            print("失败的扫描不会自动重试（Docker Hub 匿名限流最常见），看日志定因：")
            for ctx, m in missing.items():
                if m:
                    print(f"    kubectl --context {ctx} -n {NS} logs deploy/trivy-operator --since=2h"
                          " | grep -iE 'scan job container|TOOMANYREQUESTS'")
            return False
        time.sleep(60)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["summary", "rescan"])
    ap.add_argument("contexts", nargs="*", default=DEFAULT_CONTEXTS,
                    help="kubectl context，默认两集群都跑")
    ap.add_argument("--wait", type=int, default=0, metavar="MIN",
                    help="rescan 后等待回填的分钟数（0 = 不等）。homelab 串行扫描，约 12 份/小时")
    a = ap.parse_args()

    if a.command == "summary":
        for ctx in a.contexts:
            summarize(ctx)
        return 0
    expect = {ctx: start_rescan(ctx) for ctx in a.contexts}
    if a.wait <= 0:
        print("回查（看覆盖率那行，别看告警）：just helm trivy-critical，或带 --wait 让本脚本等")
        return 0
    return 0 if wait_refill(expect, a.wait) else 1


if __name__ == "__main__":
    sys.exit(main())
