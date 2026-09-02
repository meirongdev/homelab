#!/usr/bin/env python3
"""渲染检查 —— 把 ArgoCD 真正会 apply 的对象渲染出来，逐个过 schema。

为什么（三类已发生的静默失效，结构检查 H1-H5 全都看不见）:
  · Helm values 写错层级 → chart 静默忽略，ArgoCD 照样 Synced，配置从未生效（2026-08-10 KRR 分诊
    一次照出 3 处）
  · 多源 $values 渲染成空操作：map 键保留 chart 默认（`{}` 不覆盖）、list 整体替换
  · kustomize 树引用不存在的文件 / 目录源里混进非清单 yaml → 整个 App 同步失败或对象静默缺席

做法：以 argocd/applications/*.yaml 为唯一输入 —— 那就是现网会部署的清单，别自己再列一份：
  · 目录源       → 照 ArgoCD 规则拼接 *.yaml / *.yml / *.json（recurse / exclude 照 App 声明）
  · kustomize 源 → kubectl kustomize <path>（目录里有 kustomization.yaml 就走这条，与 ArgoCD 自动识别一致）
  · chart 源     → helm template <release> <chart> --version <pin> -f <$values 文件> [--skip-crds]
                   并传 --kube-version / --api-versions：ArgoCD 渲染时也传这两项，漏了会让按
                   .Capabilities.APIVersions 判断的模板少渲染一截（ServiceMonitor 就是典型）
然后 kubeconform -strict 逐对象校验：核心资源用 k8s 官方 schema，CRD 用 datreeio 目录；
没有 schema 的类型跳过并**按 kind 报出来**，这样覆盖缺口是可见的，不是静默的。

⚠️ 它证明的是「渲染得出来 + 每个对象结构合法」，证明不了值是对的（resources 填 1Mi 也合法）。
   与 H1-H5 互补：那些查文件与归属，这个查渲染结果。

用法:
    uv run --with pyyaml python scripts/render-manifests.py                 # 全部 App
    uv run --with pyyaml python scripts/render-manifests.py --app loki --app media
    uv run --with pyyaml python scripts/render-manifests.py --out /tmp/rendered   # 渲染结果落盘，便于人工 diff
    uv run --with pyyaml python scripts/render-manifests.py --no-schema         # 只渲染不校验
需要 PATH 里有 kubectl（自带 kustomize）、helm、kubeconform；chart 源要联网。
"""
import argparse
import fnmatch
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

try:
    import yaml
except ImportError:
    sys.exit("需要 pyyaml —— 用 `uv run --with pyyaml python scripts/render-manifests.py`")

ROOT = pathlib.Path(__file__).resolve().parent.parent
APPS_DIR = ROOT / "argocd" / "applications"
REPO_URL = "https://github.com/meirongdev/homelab"

# 两集群现网都是 v1.35.8+k3s1（2026-09-02 `kubectl version`）。升 k3s（runbooks/k3s-cluster-upgrade.md）
# 时同步改这里：它同时喂给 helm --kube-version 与 kubeconform -kubernetes-version。
KUBE_VERSION = "1.35.8"

# ArgoCD 渲染 chart 时把目标集群的 api-versions 传给 helm；不传则 .Capabilities.APIVersions.Has
# 全为 false，ServiceMonitor / PrometheusRule / HTTPRoute 一类模板直接不渲染，等于校验了一份
# 与现网不同的清单。下面是两集群 `kubectl api-versions` 并集里非核心的那部分（2026-09-02 现取）。
# 新装一个 operator 就补它的 group，否则那类对象在这里是隐形的。
API_VERSIONS = [
    "aquasecurity.github.io/v1alpha1",
    "argoproj.io/v1alpha1",
    "cilium.io/v2", "cilium.io/v2alpha1",
    "external-secrets.io/v1", "external-secrets.io/v1alpha1", "generators.external-secrets.io/v1alpha1",
    "externaldns.k8s.io/v1alpha1",
    "gateway.networking.k8s.io/v1", "gateway.networking.k8s.io/v1beta1",
    "gateway.networking.k8s.io/v1alpha2", "gateway.networking.k8s.io/v1alpha3",
    "helm.cattle.io/v1", "k3s.cattle.io/v1",
    "kyverno.io/v1", "kyverno.io/v2", "kyverno.io/v2alpha1", "kyverno.io/v2beta1",
    "policies.kyverno.io/v1", "policies.kyverno.io/v1alpha1", "policies.kyverno.io/v1beta1",
    "reports.kyverno.io/v1", "wgpolicyk8s.io/v1alpha2",
    "metrics.k8s.io/v1beta1",
    "monitoring.coreos.com/v1", "monitoring.coreos.com/v1alpha1",
    "postgresql.cnpg.io/v1",
    "sloth.slok.dev/v1",
]

# CRD schema 目录（社区维护，覆盖本仓库用到的 argoproj / cilium / cnpg / external-secrets /
# gateway-api / kyverno / monitoring.coreos / aquasecurity / sloth）。缺的类型走 -ignore-missing-schemas。
CRD_CATALOG = ("https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/"
               "{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json")

MANIFEST_EXTS = (".yaml", ".yml", ".json")


# 拉 chart 要出网，而网络会抖。2026-09-02 首次在 CI 上跑就有一个 chart 仓库
# DNS 超时（`lookup cloudnative-pg.io … i/o timeout`）——一次抖动就让整个检查红，
# 而「偶尔红」的检查很快就会被无视，那比没有检查更糟。
# 所以只对**网络形状**的错误重试，且每次重试都打印出来：真正坏掉的仓库仍然会响亮地失败，
# 抖动则留下痕迹而不是被悄悄吞掉。
NETWORK_ERRORS = (
    "dial tcp", "i/o timeout", "connection refused", "connection reset",
    "no such host", "TLS handshake timeout", "temporary failure",
    "EOF", "timeout awaiting response", "502 Bad Gateway", "503 Service Unavailable",
)
RETRIES = 3
BACKOFF = 5  # 秒，线性递增


def sh(cmd, retry_on_network=False, what="", **kw):
    last = ""
    for attempt in range(1, RETRIES + 1 if retry_on_network else 2):
        r = subprocess.run(cmd, capture_output=True, text=True, **kw)
        if r.returncode == 0:
            return r.stdout
        last = r.stderr.strip()
        if not retry_on_network or attempt == RETRIES:
            break
        if not any(e.lower() in last.lower() for e in NETWORK_ERRORS):
            break
        wait = BACKOFF * attempt
        print(f"    ⚠️ {what or cmd[0]} 第 {attempt} 次失败（网络类），{wait}s 后重试："
              f"{last.splitlines()[-1][:120] if last else ''}", flush=True)
        time.sleep(wait)
    raise RuntimeError(f"$ {' '.join(cmd)}\n{last[-2000:]}")


def load_apps():
    apps = []
    for p in sorted(APPS_DIR.glob("*.yaml")):
        for d in yaml.safe_load_all(p.read_text()):
            if isinstance(d, dict) and d.get("kind") == "Application":
                apps.append((d["metadata"]["name"], d["spec"], p))
    return apps


def render_dir(src):
    """目录源：kustomize 目录走 kubectl kustomize；否则照 ArgoCD 规则拼接清单文件。"""
    path = ROOT / src["path"]
    if not path.is_dir():
        raise RuntimeError(f"path 不存在: {src['path']}")
    if (path / "kustomization.yaml").exists() or (path / "kustomization.yml").exists():
        return sh(["kubectl", "kustomize", str(path)])
    d = src.get("directory") or {}
    files = sorted(path.rglob("*") if d.get("recurse") else path.glob("*"))
    exclude = d.get("exclude")
    chunks = []
    for f in files:
        if not f.is_file() or f.suffix not in MANIFEST_EXTS:
            continue
        rel = str(f.relative_to(path))
        if exclude and (fnmatch.fnmatch(rel, exclude) or fnmatch.fnmatch(f.name, exclude)):
            continue
        chunks.append(f"# Source: {f.relative_to(ROOT)}\n" + f.read_text())
    return "\n---\n".join(chunks)


def render_chart(app_name, src, namespace, tmpdir):
    h = src.get("helm") or {}
    release = h.get("releaseName") or app_name
    cmd = ["helm", "template", release]
    repo = src["repoURL"]
    if repo.startswith(("http://", "https://")):
        cmd += [src["chart"], "--repo", repo]
    else:  # OCI：ArgoCD 的 repoURL 不带 oci:// 前缀，helm 要带
        cmd += [f"oci://{repo}/{src['chart']}"]
    cmd += ["--version", str(src["targetRevision"]), "--namespace", namespace,
            "--kube-version", KUBE_VERSION]
    for v in API_VERSIONS:
        cmd += ["--api-versions", v]
    cmd += ["--skip-crds"] if h.get("skipCrds") else ["--include-crds"]
    for vf in h.get("valueFiles") or []:
        if vf.startswith("$values/"):
            vf = vf[len("$values/"):]
        cmd += ["-f", str(ROOT / vf)]
    if h.get("valuesObject"):
        f = pathlib.Path(tmpdir) / f"{app_name}-valuesObject.yaml"
        f.write_text(yaml.safe_dump(h["valuesObject"]))
        cmd += ["-f", str(f)]
    if h.get("values"):
        f = pathlib.Path(tmpdir) / f"{app_name}-values.yaml"
        f.write_text(h["values"])
        cmd += ["-f", str(f)]
    for prm in h.get("parameters") or []:
        cmd += ["--set-string" if prm.get("forceString") else "--set", f"{prm['name']}={prm['value']}"]
    # 唯一出网的一步 —— 只有它需要重试
    out = sh(cmd, retry_on_network=True, what=f"helm template {app_name}")
    # OCI 拉取时 helm 会把 "Pulled: …" / "Digest: …" 两行写到 stdout（不是 stderr），
    # 混进清单会让 kubeconform 报 "missing 'kind' key"。只剥掉开头这两行。
    lines = out.split("\n")
    while lines and lines[0].startswith(("Pulled: ", "Digest: ")):
        lines.pop(0)
    return "\n".join(lines)


def render_app(name, spec, tmpdir):
    sources = spec.get("sources") or [spec["source"]]
    namespace = (spec.get("destination") or {}).get("namespace", "default")
    out = []
    for s in sources:
        if s.get("chart"):
            out.append(render_chart(name, s, namespace, tmpdir))
        elif s.get("path"):
            out.append(render_dir(s))
        # 只有 ref 的源（$values）不渲染任何东西
    return "\n---\n".join(out)


def count_objects(text):
    n = 0
    for d in yaml.safe_load_all(text):
        if isinstance(d, dict) and d.get("kind"):
            n += 1
    return n


def kubeconform(path):
    # -verbose 才会把 valid/skipped 的对象也列进 resources[]，否则算不出「哪些 kind 没 schema」
    cmd = ["kubeconform", "-strict", "-summary", "-output", "json", "-verbose",
           "-kubernetes-version", KUBE_VERSION,
           "-schema-location", "default", "-schema-location", CRD_CATALOG,
           "-ignore-missing-schemas", str(path)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    try:
        rep = json.loads(r.stdout)
    except json.JSONDecodeError:
        raise RuntimeError(f"kubeconform 输出不可解析: {r.stdout[-500:]} {r.stderr[-500:]}")
    summ = rep.get("summary", {})
    bad = [x for x in rep.get("resources", []) if x.get("status") in ("statusInvalid", "statusError")]
    skipped_kinds = sorted({x.get("kind", "?") for x in rep.get("resources", []) if x.get("status") == "statusSkipped"})
    return summ, bad, skipped_kinds


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", action="append", help="只跑这些 App（可重复）")
    ap.add_argument("--out", help="渲染结果落盘目录（每个 App 一个 yaml）")
    ap.add_argument("--no-schema", action="store_true", help="只渲染，不跑 kubeconform")
    args = ap.parse_args()

    for tool in ("kubectl", "helm") + (() if args.no_schema else ("kubeconform",)):
        if not shutil.which(tool):
            sys.exit(f"PATH 里没有 {tool}")

    apps = load_apps()
    if args.app:
        apps = [a for a in apps if a[0] in args.app]
        if not apps:
            sys.exit(f"没有匹配的 App: {args.app}")

    out_dir = pathlib.Path(args.out) if args.out else None
    if out_dir:
        out_dir.mkdir(parents=True, exist_ok=True)

    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        for name, spec, p in apps:
            try:
                text = render_app(name, spec, tmp)
                n = count_objects(text)
                if n == 0:
                    raise RuntimeError("渲染结果为空 —— ArgoCD 的 allowEmpty=false 会拒绝同步（或者这是漏登记）")
                target = (out_dir or pathlib.Path(tmp)) / f"{name}.yaml"
                target.write_text(text)
                line = f"  {name:<24} objects={n:<4}"
                if not args.no_schema:
                    summ, bad, skipped = kubeconform(target)
                    line += (f" valid={summ.get('valid', 0):<4} invalid={summ.get('invalid', 0)} "
                             f"errors={summ.get('errors', 0)} skipped={summ.get('skipped', 0)}")
                    if skipped:
                        line += f"  (无 schema 跳过: {', '.join(skipped)})"
                    if bad:
                        failures.append(name)
                        line += "\n" + "\n".join(f"      ❌ {b.get('kind')}/{b.get('name')}: {b.get('msg')}" for b in bad)
                print(line)
            except Exception as e:  # noqa: BLE001 —— 每个 App 独立报错，一个坏了不遮住其它
                failures.append(name)
                print(f"  {name:<24} ❌ {e}")

    print()
    if failures:
        print(f"❌ {len(failures)} 个 App 渲染或校验失败: {', '.join(sorted(set(failures)))}")
        print("   规则背景见 docs/reference/manifest-safety-checks.md「渲染检查」一节")
        return 1
    print(f"✅ {len(apps)} 个 App 全部渲染成功并通过 schema 校验（kube {KUBE_VERSION}）")
    print("   注意：合法 ≠ 正确。它拦的是写错层级 / 空渲染 / 漏登记，拦不住值填错。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
