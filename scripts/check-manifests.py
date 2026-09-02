#!/usr/bin/env python3
"""清单结构安全检查 —— 把**已经发生过的事故**变成 CI 能拦的规则。

    H1  Namespace / CRD 必须独占文件      ← 2026-08-03 级联删除事故
    H2  Application 的 path / project 与 destination 同集群，AppProject 只许一个 destination
        ← AGENTS.md 的 ☠️ 警告；2026-09-02 起 project 那半由 ArgoCD 服务端兜底，本规则保证两边不脱节
    H3  ReferenceGrant 必须声明 v1beta1   ← 声明集群未提供的版本会炸掉整个 App
    H4  清单里的 PVC 必须有备份归属        ← 备份脚本是显式白名单，漏了静默无声
    H5  Namespace 必须显式声明 PSA 等级    ← 漏写 = 静默吃内置默认 privileged，且无 warn/audit

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
    ("argocd", ORACLE_SERVER),  # root / projects 两个元 App（in-cluster，只写 argocd ns）
]

# 2026-09-02 起每个集群一个 AppProject（docs/decisions/argocd-project-per-cluster.md）：
# destination 由 ArgoCD 服务端拒绝跨集群误投，本脚本负责「project 与 destination 不脱节」。
# chart 型 source 没有 path，此前 H2 对它们完全没网可兜，project 这一半正好补上。
# root / projects 两个元 App（source 在 argocd/ 下）挂内置的 `default` project：
# 挂 homelab / oracle-k3s 任一都会出现「App 管理自己所属 project」的自引用。
PROJECT_FOR_SERVER = {HOMELAB_SERVER: "homelab", ORACLE_SERVER: "oracle-k3s"}
META_PROJECT = "default"
META_PATH_PREFIX = "argocd"

# ── H3 ────────────────────────────────────────────────────────────────────
# 声明集群里**没有提供**的版本 → 整个 App ComparisonError
# "unable to resolve parseableType"，不是单个对象失败，是整个 App 不可用。
#
# ⚠️ 2026-08-11 更正（规则不变，理由变了）：本处原写"ReferenceGrant 至今未晋升到 v1"，
#    那是错的 —— 它早有 v1，而且 Cilium 1.20 反过来*要求* CRD 提供 v1（缺了则 Gateway API
#    控制器整个不初始化，两集群曾静默瘫 30 小时）。现装 Gateway API v1.6.1 的
#    referencegrants CRD **同时 served v1 与 v1beta1，且 v1beta1 仍是 storage 版本**，
#    所以继续写 v1beta1 是对的（改 v1 是无谓 churn），但别再把理由说成"v1 不存在"。
#    判据永远是：
#      kubectl get crd referencegrants.gateway.networking.k8s.io \
#        -o jsonpath='{.spec.versions[*].name}'
#    详见 docs/reference/manifest-safety-checks.md 的 H3 节。
REFERENCEGRANT_APIVERSION = "gateway.networking.k8s.io/v1beta1"

# ── H5 ────────────────────────────────────────────────────────────────────
# 无标签的 ns 不是「没定级」，是**定成了最宽的那档**：PSA 内置默认 enforce=privileged，
# 且 warn/audit 一并为空 → 连审计线索都没有。zitadel ns 就这样敞了一个多月
# （2026-07-06 迁入 → 2026-08-10 才补），期间 server dry-run 一个
# hostPID+hostNetwork+privileged+hostPath:/ 的 Pod 能建成且零 warning。
# 三个等级都算「显式声明」——privileged 是显式豁免，写出来就有人能审。
PSA_ENFORCE_LABEL = "pod-security.kubernetes.io/enforce"
PSA_LEVELS = {"privileged", "baseline", "restricted"}

# ── H4 ────────────────────────────────────────────────────────────────────
# 清单树 → 负责备份它的 overlay。
TREE_BACKUP_OVERLAY = {
    "k8s/helm/manifests": "backup/overlays/homelab/backup-script.yaml",
    "cloud/oracle/manifests": "backup/overlays/oracle/backup-script.yaml",
}

# 刻意不进白名单的 PVC —— 每条都必须写清楚「那它靠什么保住」。
# 加豁免比加白名单更需要理由：这是唯一能让数据合法地不进 restic 的出口。
BACKUP_EXEMPT = {
    # miniflux-db-pvc 于 2026-08-06 随 rss-postgres 退役删除，故移除其豁免条目——
    # 留着会让将来任何同名 PVC 被静默豁免。miniflux 现在住在 CNPG 的 apps-pg。
    # ⚠️ 注意 H4 看不到 CNPG 的 PVC（apps-pg-1 / zitadel-pg-1 由 operator 动态创建，
    #    不在任何清单里）。那两个库的备份归属靠 backup-script.yaml 里的逐库 pg_dump 行，
    #    加租户必须手工加一行，本检查器不会提醒。见 decisions/shared-postgres-platform.md。
    "open-notebook-surreal-local": "SurrealDB 数据目录，由 HTTP /export 逻辑导出覆盖（见 runbooks/backup-recovery.md）",
    "calibre-books-local": "23G 书库，由 backup-script.yaml 的 BOOKS_DIR 整目录纳入 restic，不走 sqlite 白名单",
    # litellm-pg-data-local 于 2026-08-25 随 litellm-pg 退役（库并入共享实例 apps-pg），
    # 故移除其豁免条目 —— 同 miniflux-db-pvc 的先例：留着会让将来任何同名 PVC 被静默豁免。
    # homelab 的共享实例（2026-08-25 起承载 litellm + multica 两个租户）。
    # ⚠️ 同 CNPG 那两个：**这条豁免只保住"卷不用进 restic"，保不住"库有没有被 dump"。**
    #    实例里加一个库，就必须去 backup/overlays/homelab/backup-script.yaml 加一行
    #    pg_dump —— 本检查器看不见"多了个库"，漏了只会静默不备份。
    "apps-pg-data-local": "homelab 共享 Postgres（databases/apps-pg，租户 litellm+multica），由 backup-script.yaml 的 2c)/2d) 两段逐库 pg_dump 覆盖；数据目录不能原样拷贝（无 WAL 自恢复）",
    # 多媒体仓库的媒体是**只读 NFS**（media-movie/tv/anime/music/podcast）——数据真相源在 NAS
    # 106 的 ZFS（raidz1 + sanoid 快照保护），serving 层读的是只读副本；restic 目标也是 106，
    # 跨机冗余本就做不到，媒体再进 restic 无意义。决策与取舍见
    # docs/decisions/multimedia-repository-nfs-readonly.md（唯一解释处）。
    "media-movie": "只读 NFS → 106 ZFS 保护（raidz1+sanoid），见 decisions/multimedia-repository-nfs-readonly.md",
    "media-tv": "只读 NFS → 106 ZFS 保护（raidz1+sanoid），见 decisions/multimedia-repository-nfs-readonly.md",
    "media-anime": "只读 NFS → 106 ZFS 保护（raidz1+sanoid），见 decisions/multimedia-repository-nfs-readonly.md",
    "media-music": "只读 NFS → 106 ZFS 保护（raidz1+sanoid），见 decisions/multimedia-repository-nfs-readonly.md",
    "media-podcast": "只读 NFS → 106 ZFS 保护（raidz1+sanoid），见 decisions/multimedia-repository-nfs-readonly.md",
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
    """H2 —— Application 的 path / project 与 destination 必须同集群；AppProject 只许一个 destination。"""
    for d in docs:
        kind = d.get("kind")
        spec = d.get("spec") or {}
        name = (d.get("metadata") or {}).get("name", "?")
        if kind == "AppProject":
            servers = sorted({(x or {}).get("server", "") for x in (spec.get("destinations") or [])})
            expect = next((srv for srv, prj in PROJECT_FOR_SERVER.items() if prj == name), None)
            if expect is None:
                fail("H2", p, f"AppProject `{name}` 不在已知集群表里（homelab / oracle-k3s）；"
                              "新集群要先登记进 check-manifests.py 的 PROJECT_FOR_SERVER")
            elif servers != [expect]:
                fail("H2", p, f"AppProject `{name}` 的 destinations 必须且只能是 `{expect}`，现为 {servers}。"
                              "一个 project 一个集群，多列或通配会让服务端那半兜底失守")
            continue
        if kind != "Application":
            continue
        server = ((spec.get("destination") or {}).get("server") or "").strip()
        project = spec.get("project") or ""
        sources = spec.get("sources") or ([spec["source"]] if spec.get("source") else [])
        paths = [((x or {}).get("path") or "").rstrip("/") for x in sources if (x or {}).get("path")]
        # ① path ↔ destination（chart 型 source 没有 path，这一条对它们无从判断，跳过）
        for path in paths:
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
        # ② project ↔ destination（对 chart 型 source 是唯一的静态兜底）
        is_meta = any(path == META_PATH_PREFIX or path.startswith(META_PATH_PREFIX + "/") for path in paths)
        if is_meta:
            if project != META_PROJECT:
                fail("H2", p, f"元 App `{name}`（source 在 argocd/ 下）必须挂 `{META_PROJECT}` project，现为 `{project}`")
        else:
            expect = PROJECT_FOR_SERVER.get(server)
            if expect is None:
                fail("H2", p, f"App `{name}` 的 destination.server `{server or '<空>'}` 不在已知集群表里")
            elif project != expect:
                fail("H2", p, f"App `{name}` 的 destination 是 {expect} 集群，但 project 是 `{project}`，应为 `{expect}`；"
                              "project 与 destination 脱节时 ArgoCD 会拒绝同步（响亮），但别等到那时")


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
                f"——本仓库统一用 v1beta1（它仍是 CRD 的 storage 版本）；"
                f"声明集群未提供的版本会让**整个 App** ComparisonError 不可用。",
            )


def check_h5(p, docs):
    """H5 —— Namespace 必须显式声明 PSA enforce 等级。"""
    for d in docs:
        if d.get("kind") != "Namespace":
            continue
        meta = d.get("metadata") or {}
        name = meta.get("name", "?")
        level = (meta.get("labels") or {}).get(PSA_ENFORCE_LABEL)
        if level is None:
            fail(
                "H5",
                p,
                f"Namespace `{name}` 没有 `{PSA_ENFORCE_LABEL}` 标签——"
                f"这不是「没定级」，是**静默吃 PSA 内置默认 privileged**，且 warn/audit 一并为空"
                f"（连审计线索都没有）。三档任选其一显式写出来，privileged 也行（那是显式豁免）。"
                f"收紧前先跑 `kubectl label ns {name} {PSA_ENFORCE_LABEL}=<档> --overwrite --dry-run=server`"
                f"，它会列出现存违规 Pod。",
            )
        elif level not in PSA_LEVELS:
            fail("H5", p, f"Namespace `{name}` 的 PSA 等级 `{level}` 不是 {sorted(PSA_LEVELS)} 之一。")


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
    ("H2", "Application path/project ↔ destination 同集群；AppProject 单 destination", "控制面 2026-08-02 迁 oracle 后，kubernetes.default.svc 改指 oracle；写错会把 homelab 全套装到 oracle。2026-09-02 起每集群一个 AppProject，服务端也兜底"),
    ("H3", "ReferenceGrant 必须 v1beta1", "v1beta1 仍是 CRD 的 storage 版本；声明集群未提供的版本会让整个 App ComparisonError 不可用"),
    ("H4", "PVC 必须有备份归属", "备份脚本是显式白名单；trends-data 曾因此静默未备份 2 个月（45MB）"),
    ("H5", "Namespace 必须显式声明 PSA 等级", "漏写不是没定级，是静默吃内置默认 privileged；zitadel ns 就这样敞了一个多月（2026-07-06→08-10）"),
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
        print("   H5 同理只看**清单里声明的** ns：Helm / ArgoCD CreateNamespace 建出来的")
        print("   （external-secrets、cnpg-system、trivy-system…）没有清单，扫不到。")
        return 0

    for p, docs in iter_manifests():
        check_h1(p, docs)
        check_h2(p, docs)
        check_h3(p, docs)
        check_h5(p, docs)
    check_h4()

    total = sum(len(v) for v in violations.values())
    if not total:
        print("✅ 清单安全检查通过（H1-H5）")
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
