#!/usr/bin/env python3
"""清单结构安全检查 —— 把**已经发生过的事故**变成 CI 能拦的规则。

    H1  Namespace / CRD 必须独占文件      ← 2026-08-03 级联删除事故
    H2  Application 的 path 与 destination 必须同集群  ← AGENTS.md 的 ☠️ 警告
    H3  ReferenceGrant 必须声明 v1beta1   ← 声明 v1 会炸掉整个 App
    H4  清单里的 PVC 必须有备份归属        ← 备份脚本是显式白名单，漏了静默无声

设计原则（与 check-docs.py 同）: **本脚本能查的，和
docs/reference/manifest-safety-checks.md 写的规则必须一一对应。**
文档比检查器严，规则就是摆设；检查器比文档严，就会误伤。改任何一边都要同步另一边。

每条规则都对应一次真实故障或一次真实的静默失效——不要为「看起来更规范」加规则，
误报会让整个检查被无视，那比没有检查更糟。

用法:
    uv run --with pyyaml python scripts/check-manifests.py
    uv run --with pyyaml python scripts/check-manifests.py --list
"""
import pathlib
import re
import sys
from collections import defaultdict

try:
    import yaml
except ImportError:
    sys.exit("需要 pyyaml —— 用 `uv run --with pyyaml python scripts/check-manifests.py`")

ROOT = pathlib.Path(__file__).resolve().parent.parent

# GitOps 同步树：这些目录下的文件被 ArgoCD 按目录整体同步，
# 删文件 = prune 掉文件里的**全部**对象（H1 的前提）。
GITOPS_TREES = [
    "k8s/helm/manifests",
    "cloud/oracle/manifests",
    "backup",
    "argocd",
]

# ── H1 ────────────────────────────────────────────────────────────────────
# 作用域大于「本文件」的资源。删掉承载它们的文件，被 prune 的不止这个应用自己。
# Namespace  → 连带删光该 ns 下**其它应用**的对象，PVC 的 Prune=false 拦不住
#              （被 prune 的是 ns，不是 PVC）。2026-08-03 就是这样删光 open-notebook 的。
# CRD        → 连带删光集群内该类型的**全部** CR。
# ClusterRole/Binding 刻意**不列入**：它们通常就是本应用自己的 RBAC，
# 与应用同生共死是正确的，列进来只会制造 5 处误报。
FILE_HOGGING_KINDS = {"Namespace", "CustomResourceDefinition"}

# ── H2 ────────────────────────────────────────────────────────────────────
# 2026-08-02 起 ArgoCD 控制面在 oracle-k3s，`kubernetes.default.svc` 指的是 **oracle**。
# 所以 homelab 的负载必须显式写 Tailscale IP，写错就会把 homelab 全套装到 oracle。
HOMELAB_SERVER = "https://100.94.186.7:6443"
ORACLE_SERVER = "https://kubernetes.default.svc"

PATH_CLUSTER = [
    ("k8s/helm/manifests", HOMELAB_SERVER),
    ("backup/overlays/homelab", HOMELAB_SERVER),
    ("cloud/oracle/manifests", ORACLE_SERVER),
    ("backup/overlays/oracle", ORACLE_SERVER),
    ("argocd/applications", ORACLE_SERVER),
]

# ── H3 ────────────────────────────────────────────────────────────────────
# ReferenceGrant 至今未晋升到 v1。声明 v1 → 整个 App ComparisonError
# "unable to resolve parseableType"，不是单个对象失败，是整个 App 不可用。
REFERENCEGRANT_APIVERSION = "gateway.networking.k8s.io/v1beta1"

# ── H4 ────────────────────────────────────────────────────────────────────
# 清单树 → 负责备份它的 overlay。
TREE_BACKUP_OVERLAY = {
    "k8s/helm/manifests": "backup/overlays/homelab/backup-script.yaml",
    "cloud/oracle/manifests": "backup/overlays/oracle/backup-script.yaml",
}

# 刻意不进白名单的 PVC —— 每条都必须写清楚「那它靠什么保住」。
# 加豁免比加白名单更需要理由：这是唯一能让数据合法地不进 restic 的出口。
BACKUP_EXEMPT = {
    "meilisearch-data": "搜索索引，可由 karakeep 全量重建（backup-script.yaml 开头已声明不备份）",
    "miniflux-db-pvc": "PostgreSQL 数据目录，由 pg_dumpall 逻辑导出覆盖，不做文件级拷贝",
    "open-notebook-surreal-local": "SurrealDB 数据目录，由 HTTP /export 逻辑导出覆盖（见 runbooks/backup-recovery.md）",
    "calibre-books-local": "23G 书库，由 backup-script.yaml 的 BOOKS_DIR 整目录纳入 restic，不走 sqlite 白名单",
}

violations = defaultdict(list)


def fail(rule, path, msg):
    try:
        loc = str(pathlib.Path(path).relative_to(ROOT))
    except ValueError:
        loc = str(path)
    violations[rule].append(f"{loc}  {msg}")


def iter_manifests():
    """产出 (path, [docs])，跳过解析不了的（静态检查里另有 YAML 语法关）。"""
    for tree in GITOPS_TREES:
        base = ROOT / tree
        if not base.is_dir():
            continue
        for p in sorted(base.rglob("*.yaml")):
            try:
                docs = [d for d in yaml.safe_load_all(p.read_text()) if isinstance(d, dict)]
            except Exception:
                continue
            yield p, docs


def check_h1(p, docs):
    """H1 —— Namespace/CRD 必须独占文件。"""
    kinds = {d.get("kind") for d in docs if d.get("kind")}
    hogging = kinds & FILE_HOGGING_KINDS
    if hogging and len(kinds) > 1:
        others = sorted(kinds - hogging)
        fail(
            "H1",
            p,
            f"{'/'.join(sorted(hogging))} 与 {', '.join(others)} 混在同一文件——"
            f"删这个文件会 prune 掉作用域大于本应用的对象。拆成专职文件（如 namespace.yaml）。",
        )


def check_h2(p, docs):
    """H2 —— Application 的 source.path 与 destination 必须同集群。"""
    for d in docs:
        if d.get("kind") != "Application":
            continue
        spec = d.get("spec") or {}
        name = (d.get("metadata") or {}).get("name", "?")
        server = ((spec.get("destination") or {}).get("server") or "").strip()
        sources = spec.get("sources") or ([spec["source"]] if spec.get("source") else [])
        for s in sources:
            path = (s or {}).get("path")
            if not path:
                continue  # chart 型 source 没有 path，静态上无从判断集群，跳过
            path = path.rstrip("/")
            for prefix, expect in PATH_CLUSTER:
                if path == prefix or path.startswith(prefix + "/"):
                    if server != expect:
                        who = "homelab" if expect == HOMELAB_SERVER else "oracle-k3s"
                        fail(
                            "H2",
                            p,
                            f"App `{name}` 的 path `{path}` 属于 {who}，"
                            f"但 destination.server 是 `{server or '<空>'}`，应为 `{expect}`。"
                            f"⚠️ `kubernetes.default.svc` 指的是 oracle（2026-08-02 起控制面在那）。",
                        )
                    break


def check_h3(p, docs):
    """H3 —— ReferenceGrant 必须是 v1beta1。"""
    for d in docs:
        if d.get("kind") != "ReferenceGrant":
            continue
        av = d.get("apiVersion", "")
        if av != REFERENCEGRANT_APIVERSION:
            name = (d.get("metadata") or {}).get("name", "?")
            fail(
                "H3",
                p,
                f"ReferenceGrant `{name}` 声明了 `{av}`，必须是 `{REFERENCEGRANT_APIVERSION}`"
                f"——它从未晋升到 v1，写错会让**整个 App** ComparisonError 不可用。",
            )


def backup_patterns(rel_script):
    """从备份脚本里取出 sqlite/config 白名单（`for pat in ... ; do`）。

    刻意直接读脚本而不是维护一份副本：副本会漂移，而漂移的检查器比没有更糟。
    取不到就报错——宁可吵，也不要静默放行。

    ⚠️ 必须锚定「行首的 shell 语句」：写这个检查时第一版用了宽松的
    `for pat in ([^;]+);`，结果匹配到脚本注释里那句「`for pat in ...` 是显式白名单」，
    把整段中文注释当成了白名单 → 两个本已备份的 PVC 被误报。
    脚本里有多个白名单循环时取并集。
    """
    f = ROOT / rel_script
    if not f.is_file():
        return None
    pats = []
    for m in re.finditer(r"^\s*for pat in ([^;#]+);", f.read_text(), re.MULTILINE):
        pats.extend(m.group(1).split())
    return pats or None


def check_h4():
    """H4 —— 清单里声明的每个 PVC 都必须有备份归属。"""
    cache = {}
    for tree, script in TREE_BACKUP_OVERLAY.items():
        cache[tree] = backup_patterns(script)
        if cache[tree] is None:
            fail("H4", ROOT / script, "解析不出 `for pat in ...;` 白名单——备份覆盖检查已失效，先修这里")

    for p, docs in iter_manifests():
        rel = str(p.relative_to(ROOT))
        tree = next((t for t in TREE_BACKUP_OVERLAY if rel.startswith(t + "/")), None)
        if tree is None or cache.get(tree) is None:
            continue
        for d in docs:
            if d.get("kind") != "PersistentVolumeClaim":
                continue
            name = (d.get("metadata") or {}).get("name", "")
            if not name or name in BACKUP_EXEMPT:
                continue
            if any(pat in name for pat in cache[tree]):
                continue
            fail(
                "H4",
                p,
                f"PVC `{name}` 既不在 {TREE_BACKUP_OVERLAY[tree]} 的白名单里，"
                f"也没在 check-manifests.py 的 BACKUP_EXEMPT 里写明豁免理由——"
                f"**它现在静默地没有备份**。二选一：加进白名单，或写清楚它靠什么保住。",
            )


RULES = [
    ("H1", "Namespace/CRD 必须独占文件", "2026-08-03 级联删除：删 calibre 清单 → prune 掉整个 ns → 删光同 ns 的 open-notebook 数据"),
    ("H2", "Application path ↔ destination 同集群", "控制面 2026-08-02 迁 oracle 后，kubernetes.default.svc 改指 oracle；写错会把 homelab 全套装到 oracle"),
    ("H3", "ReferenceGrant 必须 v1beta1", "从未晋升 v1，写 v1 会让整个 App ComparisonError 不可用"),
    ("H4", "PVC 必须有备份归属", "备份脚本是显式白名单；trends-data 曾因此静默未备份 2 个月（45MB）"),
]


def main():
    if "--list" in sys.argv:
        print("清单安全规则（每条都来自一次真实故障）:\n")
        for rid, desc, why in RULES:
            print(f"  {rid}  {desc}")
            print(f"      ← {why}\n")
        print("规则全文见 docs/reference/manifest-safety-checks.md")
        print("\n⚠️ 这些是**结构**检查。查不出的：配置值写错层级（tempo persistence）、")
        print("   ConfigMap 改了但 Pod 不重启、文档与集群漂移——那几类只能实测。")
        return 0

    for p, docs in iter_manifests():
        check_h1(p, docs)
        check_h2(p, docs)
        check_h3(p, docs)
    check_h4()

    total = sum(len(v) for v in violations.values())
    if not total:
        print("✅ 清单安全检查通过（H1-H4）")
        print("   注意：结构合规 ≠ 行为正确。值写错层级、改了不生效这类问题只能实测。")
        return 0

    print(f"❌ {total} 项违规\n")
    for rule in sorted(violations):
        print(f"[{rule}]")
        for v in violations[rule]:
            print(f"  {v}")
        print()
    print("规则全文与背景见 docs/reference/manifest-safety-checks.md")
    return 1


if __name__ == "__main__":
    sys.exit(main())
