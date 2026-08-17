#!/usr/bin/env python3
"""术语正典检查 —— 正典全文见 docs/reference/terminology.md。

设计原则（和 check-docs.py / check-manifests.py 一致）：**只查机械可判、且判错就是事实
错误的东西**。风格类变体（K3s vs K8s 的语义选择、App vs Application、把 106 当简称）
故意不管 —— 那些只能靠 terminology.md + review，写成规则必然误报，误报多了整个检查就
会被绕过。

豁免（按 docs/RULES.md R1）：
  · `docs/plans/` 全部 —— 写完即冻结的历史快照，不代表现状，改它反而抹掉历史
  · `docs/records/` —— 故障复盘同为历史快照
  · `docs/reference/terminology.md` 自己 —— 它必须**列出**这些禁止写法才能说明规则
  · fenced code block / 行内 code / 链接目标 —— 那些是标识符或命令，照抄才对
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# 扫这些；对 .md 会剥掉代码块，对代码文件只看注释外的原文（见 scan_text）
GLOBS = ("*.md", "*.yaml", "*.yml", "*.sh", "*.py", "*.tf", "justfile")

SKIP_DIRS = {".git", "node_modules", ".terraform", "venv", ".venv", "__pycache__"}
SKIP_PATHS = {
    "docs/plans",                                  # R1：冻结快照
    "docs/records",                                # 故障复盘同为快照
    "docs/reference/terminology.md",               # 正典本身要列出反例
    "scripts/check-terminology.py",                # 本文件
}

failures: list[tuple[str, Path, int, str]] = []


def fail(rule: str, path: Path, line: int, msg: str) -> None:
    failures.append((rule, path.relative_to(ROOT), line, msg))


def strip_noise(text: str) -> str:
    """把代码块 / 行内 code / 链接目标替成等长空白，保持行号与列不变。"""
    def blank(m: re.Match) -> str:
        return re.sub(r"[^\n]", " ", m.group(0))
    text = re.sub(r"```.*?```", blank, text, flags=re.S)
    text = re.sub(r"`[^`\n]*`", blank, text)
    text = re.sub(r"\]\([^)\n]*\)", blank, text)     # 链接目标（含文件名）
    return text


# ---- T1：不存在的 context / 集群名 -------------------------------------------
# 真值：kubectl context 是 k3s-homelab 与 oracle-k3s；Cilium cluster-name 是 homelab 与
# oracle-k3s。下面这些形式在任何一层都不存在，出现即是笔误，会让人打到错误的集群。
# ⚠️ 不要往这里加 `homelab-cluster` —— 它是**真实标识符**（oracle-k3s 上 argocd ns 里
# ArgoCD cluster secret 与 ExternalSecret 的名字，实测存在），不是笔误。
BOGUS = {
    "homelab-k3s": "context 是 `k3s-homelab`，Cilium/ArgoCD/指标那一层叫 `homelab`",
    "k3s-oracle": "写作 `oracle-k3s`",
    "k8s-homelab": "context 是 `k3s-homelab`",
    "oracle-k8s": "写作 `oracle-k3s`",
}

# ---- T2：拼写正典 -------------------------------------------------------------
# (正则, 正典, 说明)。只放全仓已经压倒性一致、另一种写法纯属漏网的。
SPELLING = [
    (re.compile(r"\bArgo CD\b"), "ArgoCD", "全仓 ArgoCD 455 : Argo CD 0"),
    (re.compile(r"\bCluster Mesh\b"), "ClusterMesh", "Cilium 官方写法无空格"),
    (re.compile(r"\bZitadel\b"), "ZITADEL", "产品名全大写"),
    (re.compile(r"\bK3S\b"), "K3s", None),
    (re.compile(r"控制平面"), "控制面", "全仓 控制面 97 : 控制平面 1"),
    # 只查裸 `storage106`（指主机时）。`storage106-as-homelab-worker` /
    # `storage106-experiment-vm` 是已定的 ADR 文件名 slug，重命名要动 R5 索引和一堆引用，
    # 不值得 —— 故后面跟 `-` 的一律放过。
    (re.compile(r"storage106(?!-)"), "storage-106",
     "主机名带连字符；ADR 文件名 slug `storage106-*` 不在此列"),
]

# ---- T3：reference/ + runbooks/ 里不能把 homelab 说成单节点 -------------------
# homelab 2026-08-13 起是双节点（控制面 + worker）。oracle-k3s 仍是单节点，所以只在
# 与 homelab 同句出现时才判违规。这两个目录按 R6 必须反映现状。
# ---- T4：`master` 不再用来指控制面节点 ----------------------------------------
# 2026-08-18 全仓改写 73 处。它在本仓库有三个**合法**含义，都必须放过：
#   · LiteLLM / ZITADEL 的 `master key`
#   · git 的 master 分支
#   · kube-bench `--targets master,etcd,controlplane,node,policies` 里的 target 名
#     （连解释它的注释也要放过，否则注释与实参脱节）
# 除此之外指节点时一律写 `控制面`（中文）/ `control-plane`（英文），或直呼 `k8s-node`。
MASTER = re.compile(r"(?<![-\w/])master(?![-\w])")
MASTER_OK = re.compile(
    r"master[-_ ]?key|master 分支|\bbranch\b|Mastering"
    r"|origin[/\s]+master"                       # origin/master 与 `git pull origin master`
    r"|\bgit\b[^\n]*\bmaster\b"                  # 任何 git 命令行里的分支名
    r"|master\s*[,/]\s*(etcd|controlplane)|(etcd|controlplane)\s*[,/]\s*master",
    re.I,
)

CURRENT_DIRS = ("docs/reference/", "docs/runbooks/")
SINGLE_NODE = re.compile(r"单节点")
HOMELAB_CTX = re.compile(r"homelab|5600H|笔记本")
# 已经自己交代了"当时是单节点、现在加了 worker"的句子不算违规 —— 那是正确的限定写法，
# 不是过期事实。判据是同一行里出现拓扑变更日期或明确的时态限定词。
QUALIFIED = re.compile(r"2026-08-13|该次|当时|那时|彼时|历史上|曾经|已加|加了 worker")


def scan(path: Path) -> None:
    rel = path.relative_to(ROOT).as_posix()
    if any(rel == s or rel.startswith(s + "/") for s in SKIP_PATHS):
        return
    try:
        raw = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return
    text = strip_noise(raw) if path.suffix == ".md" else raw

    for n, line in enumerate(text.splitlines(), 1):
        for bad, hint in BOGUS.items():
            if bad in line:
                fail("T1", path, n, f"`{bad}` 不是任何一层的真名 —— {hint}")
        for rx, canon, why in SPELLING:
            if rx.search(line):
                fail("T2", path, n,
                     f"`{rx.pattern}` -> 正典 `{canon}`" + (f"（{why}）" if why else ""))
        if MASTER.search(line) and not MASTER_OK.search(line):
            fail("T4", path, n,
                 "`master` 指控制面节点已废弃 -> 写 `控制面`/`control-plane`，或直呼 `k8s-node`"
                 "（`master key` / git 分支 / kube-bench target 不在此列）")
        if (rel.startswith(CURRENT_DIRS) and SINGLE_NODE.search(line)
                and HOMELAB_CTX.search(line) and not QUALIFIED.search(line)):
            fail("T3", path, n,
                 "homelab 2026-08-13 起是双节点；这两个目录必须反映现状。"
                 "指控制面就写「控制面」，讲 oracle 就写「oracle-k3s 单节点」")


def main() -> int:
    seen: set[Path] = set()
    for g in GLOBS:
        for p in ROOT.rglob(g):
            if seen.intersection({p}) or any(d in p.parts for d in SKIP_DIRS):
                continue
            seen.add(p)
            scan(p)

    if not failures:
        print(f"✅ 术语正典检查通过（扫描 {len(seen)} 个文件，T1-T4）")
        print("   注意：只查机械可判的那几条。K3s/K8s 的语义选择、App/Application、"
              "106 简称靠 docs/reference/terminology.md + review。")
        return 0

    print(f"❌ 术语违规 {len(failures)} 处\n")
    for rule in ("T1", "T2", "T3", "T4"):
        rows = [f for f in failures if f[0] == rule]
        if not rows:
            continue
        print(f"[{rule}]")
        for _, path, line, msg in rows:
            print(f"  {path}:{line}  {msg}")
        print()
    print("正典全文见 docs/reference/terminology.md。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
