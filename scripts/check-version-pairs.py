#!/usr/bin/env python3
"""版本配对断言 —— 把「⚠️ 两处同步改」的注释变成 CI 真能拦的东西。

    V1  同一 chart 出现在多个 Application 里 → targetRevision 必须一致
    V2  声明为「同一事实」的版本变量组 → 取值必须一致
    V3  cilium_version 与 gateway_api_version 必须符合兼容表
    V4  versions.just 里的共享变量不得被 import 方重新定义（会静默覆盖）

每条都对应真实故障：

  V3/V2 ← **2026-08-11 的 30 小时静默 stall**：Cilium 1.20 升级时漏配 Gateway API CRD
          （现网 v1.2.1 vs 要求的 v1.6.1），operator 的 Gateway API 控制器整个不初始化，
          而旧路由照常 200、无任何告警，只有新增路由静默 503。
          2026-08-13 复查又发现 `cloud/oracle/ansible/playbooks/setup-k3s.yaml` **仍钉
          着 v1.2.1**，注释却写着"与 homelab 一致"——同一事实散在三处，两处已改、
          一处漏改，且漏的那处只在**重建集群时**才会爆。注释挡不住这个，CI 可以。
  V1    ← 跨集群镜像部署的 App 对（external-dns / opencost / trivy-operator 各两份）：
          升级时只改一侧，另一侧就静默留在旧版本，直到某天行为不一致才被发现。

设计原则（与 check-manifests.py / check-docs.py 同）：**本脚本能查的，和
docs/reference/manifest-safety-checks.md 写的规则必须一一对应**，改一边就要改另一边。
误报会让整个检查被无视，比没有检查更糟 —— 所以 V2 **只断言人工声明过的组**，
不做"同名变量一律必须相等"的推断（见 DECLARED_PAIRS 下面那段反例）。

豁免：在版本所在行写行内注释 `version-pair-ok: <理由>`（如刻意的灰度/单侧先行）。

用法:
    uv run --with pyyaml python scripts/check-version-pairs.py
    uv run --with pyyaml python scripts/check-version-pairs.py --list
"""
import pathlib
import re
import sys
from collections import defaultdict

try:
    import yaml
except ImportError:
    sys.exit("需要 pyyaml —— 用 `uv run --with pyyaml python scripts/check-version-pairs.py`")

ROOT = pathlib.Path(__file__).resolve().parent.parent
EXEMPT = "version-pair-ok:"

# ── V2：声明为「同一事实」的版本变量组 ────────────────────────────────────────
# 每组是**同一个事实**写在多处，不是"名字碰巧一样"。加组前先问：改了一处不改另一处，
# 会不会出事？会才加。
#
# ☠️ 刻意 **不** 收 `node_exporter_version`：它在 proxmox / k8s / macbook 三套
# ansible 里各有一份（写本脚本时实测 1.11.1 / 1.10.0 / 1.11.1），那是三个独立机队
# 各自的 exporter 版本 —— 不一致是"该升级了"，不是"配置错了"。把它算违规就会
# 制造一条谁都不看的红灯。这类漂移交给 Renovate 开 PR（见 decisions/renovate-adoption.md）。
#
# 同理不收 `eso_version`：两集群各自独立安装 ESO，版本可以不同步，没有耦合。
DECLARED_PAIRS = {
    "gateway_api_version": {
        "why": "两集群装同一版本的 Gateway API CRD。两个 justfile 已于 2026-09-02 改为 import "
               "versions.just（单一真相源），但 ansible 剧本里那份是 YAML 变量、import 不进来，"
               "只能靠断言 —— 而它正是 2026-08-13 被抓到的那份：剧本钉着旧值，注释却写"
               "「与 homelab 一致」。漏改一处 = 重建集群时重放 2026-08-11 的 30h 控制器 stall。",
        "files": [
            "versions.just",
            "cloud/oracle/ansible/playbooks/setup-k3s.yaml",
        ],
    },
    # cilium_version 于 2026-09-02 收敛到 versions.just（两个 justfile import 它），
    # 单一真相源就不需要"多处一致"的断言了 —— 改由 V4 守住"不许被重新定义"。
    "k3s_version": {
        "why": "homelab 控制面与 worker 是**同一个集群**，k3s 不保证 agent 新于 server "
               "可用；oracle 与它们按舰队惯例同步升（见 runbooks/k3s-cluster-upgrade.md）。"
               "2026-08-30 加：此前两个 server 剧本根本没钉版本（`curl … | sh -` 裸装），"
               "重建任何一台都会装上 stable 频道当天的值 —— 现网 v1.34.5、stable 已 "
               "v1.36.4，中间还隔着一次不可跳的 minor，而 worker 那份偏偏是钉死的。"
               "分阶段升级（一侧先行）在先行那侧的行尾写 `version-pair-ok: <理由>` 豁免。",
        "files": [
            "k8s/ansible/playbooks/setup-k3s.yaml",
            "k8s/ansible/playbooks/setup-k3s-worker.yaml",
            "cloud/oracle/ansible/playbooks/setup-k3s.yaml",
        ],
    },
}

# ── V3：Cilium ↔ Gateway API CRD 兼容表 ──────────────────────────────────────
# 值取自升级时读的 Cilium 官方前置条件（不是猜的），按 major.minor 索引。
# ⚠️ 升 Cilium 时**必须**给这里加一行 —— 查不到对应行就报错，是特意的：
# 它强迫升级者去读一遍上游要求，而不是假设旧 CRD 还能用（那正是 08-11 的死法）。
CILIUM_GATEWAY_API = {
    "1.20": "1.6.1",
}

# ── V4：共享版本变量的遮蔽守卫 ──────────────────────────────────────────────
# `just import` 允许 import 方重新定义同名变量并**静默胜出**。那正好复刻了本次收敛要
# 消灭的漂移，且比原来更隐蔽：文件里明明写着 import，读的人会以为值来自共享文件。
SHARED_VERSIONS = "versions.just"
IMPORTERS = ["k8s/helm/justfile", "cloud/oracle/justfile"]

VAR_RE = {
    # justfile: name := "1.2.3"
    "justfile": re.compile(r'^\s*([a-z0-9_]+)\s*:=\s*"([^"]+)"'),
    # yaml vars: name: "1.2.3" / name: 1.2.3 / name: v1.34.5+k3s1
    # 允许 v 前缀：k3s 的版本号自带它（`INSTALL_K3S_VERSION` 只认 `v…+k3sN`），
    # 不允许的话 find_var 会返回 None，报成「配对声明与实际不符」的假违规。
    "yaml": re.compile(r'^\s*([a-z0-9_]+):\s*"?(v?[0-9][^"\s#]*)"?'),
}

violations = defaultdict(list)


def read_lines(rel):
    p = ROOT / rel
    if not p.exists():
        violations["V0"].append(f"{rel}: 配对声明指向的文件不存在（改名后忘了同步本脚本？）")
        return []
    return p.read_text(encoding="utf-8").splitlines()


def find_var(rel, name):
    """在文件里找 name 的取值，返回 (value, lineno, exempt) 或 None。"""
    # `.just` 后缀的共享文件（versions.just）与 justfile 同语法；按后缀也认，
    # 否则会掉进 yaml 分支、把 `name := "1.2.3"` 解析不出来，报成"变量被删/改名"的假违规。
    fname = pathlib.Path(rel).name   # 不叫 name —— 那是本函数要找的变量名参数
    kind = "justfile" if fname == "justfile" or fname.endswith(".just") else "yaml"
    for i, line in enumerate(read_lines(rel), 1):
        m = VAR_RE[kind].match(line)
        if m and m.group(1) == name:
            return m.group(2), i, EXEMPT in line
    return None


def check_v1():
    """同名 chart 的 targetRevision 必须一致。"""
    apps = ROOT / "argocd" / "applications"
    if not apps.is_dir():
        return
    # chart -> [(revision, "file:line", exempt)]
    charts = defaultdict(list)
    for p in sorted(apps.glob("*.yaml")):
        text = p.read_text(encoding="utf-8")
        lines = text.splitlines()
        try:
            docs = [d for d in yaml.safe_load_all(text) if isinstance(d, dict)]
        except yaml.YAMLError as e:
            violations["V1"].append(f"{p.relative_to(ROOT)}: YAML 解析失败 {e}")
            continue
        for doc in docs:
            if doc.get("kind") != "Application":
                continue
            spec = doc.get("spec") or {}
            sources = spec.get("sources") or ([spec["source"]] if "source" in spec else [])
            for src in sources:
                if not isinstance(src, dict):
                    continue
                chart, rev = src.get("chart"), src.get("targetRevision")
                if not chart or not rev:
                    continue
                # 行号 + 行内豁免：找声明了这个版本的那一行
                lineno, exempt = 0, False
                for i, line in enumerate(lines, 1):
                    if "targetRevision" in line and str(rev) in line:
                        lineno, exempt = i, EXEMPT in line
                        break
                charts[chart].append((str(rev), f"{p.relative_to(ROOT)}:{lineno}", exempt))

    for chart, entries in sorted(charts.items()):
        if len(entries) < 2:
            continue
        if any(e[2] for e in entries):          # 任一处显式豁免 → 整组跳过
            continue
        revs = {e[0] for e in entries}
        if len(revs) > 1:
            where = "  ".join(f"{loc}={rev}" for rev, loc, _ in entries)
            violations["V1"].append(
                f"chart {chart} 在多个 Application 里版本不一致：{where}"
            )


def check_v2():
    """声明为同一事实的版本变量组必须取值一致。"""
    for name, group in DECLARED_PAIRS.items():
        found = []
        for rel in group["files"]:
            hit = find_var(rel, name)
            if hit is None:
                violations["V2"].append(
                    f"{rel}: 找不到 {name} —— 配对声明与实际不符（变量被删/改名？）"
                )
                continue
            found.append((hit[0], f"{rel}:{hit[1]}", hit[2]))
        if len(found) < 2 or any(f[2] for f in found):
            continue
        if len({f[0] for f in found}) > 1:
            where = "  ".join(f"{loc}={val}" for val, loc, _ in found)
            violations["V2"].append(f"{name} 各处取值不一致：{where}\n    理由：{group['why']}")


def check_v4():
    """versions.just 的共享变量不得被 import 方重新定义（会静默覆盖）。"""
    shared = {}
    for line in read_lines(SHARED_VERSIONS):
        m = VAR_RE["justfile"].match(line)
        if m:
            shared[m.group(1)] = m.group(2)
    if not shared:
        violations["V4"].append(f"{SHARED_VERSIONS}: 一个变量都没解析到（文件被清空/改格式？）")
        return
    for rel in IMPORTERS:
        lines = read_lines(rel)
        if not any(line.strip().startswith("import ") and SHARED_VERSIONS in line for line in lines):
            violations["V4"].append(
                f"{rel}: 没有 import {SHARED_VERSIONS} —— 共享版本会退回各写一份的老路"
            )
            continue
        for i, line in enumerate(lines, 1):
            m = VAR_RE["justfile"].match(line)
            if m and m.group(1) in shared and EXEMPT not in line:
                violations["V4"].append(
                    f"{rel}:{i}: 重新定义了共享变量 {m.group(1)}={m.group(2)}"
                    f"（{SHARED_VERSIONS} 里是 {shared[m.group(1)]}）——"
                    "import 方的定义会静默胜出，等于绕开单一真相源。"
                    "确实要分阶段升级时在行尾写 `version-pair-ok: <理由>` 豁免"
                )


def check_v3():
    """cilium_version 与 gateway_api_version 必须符合兼容表。"""
    cil = find_var(SHARED_VERSIONS, "cilium_version")
    gw = find_var(SHARED_VERSIONS, "gateway_api_version")
    if not cil or not gw:
        return
    minor = ".".join(cil[0].split(".")[:2])
    want = CILIUM_GATEWAY_API.get(minor)
    if want is None:
        violations["V3"].append(
            f"cilium {cil[0]} 不在兼容表里 —— 升级 Cilium 时请读上游的 Gateway API "
            f"前置条件，然后往 scripts/check-version-pairs.py 的 CILIUM_GATEWAY_API "
            f"加一行 '{minor}': '<所需 Gateway API 版本>'。"
            f"（别假设旧 CRD 还能用：2026-08-11 就是这么静默停摆 30 小时的）"
        )
    elif gw[0] != want:
        violations["V3"].append(
            f"cilium {cil[0]} 要求 Gateway API {want}，但 gateway_api_version={gw[0]}"
            f"（{SHARED_VERSIONS}:{gw[1]}）。升 Cilium 后必须跑 "
            f"`just deploy-gateway-api-crds`。验收判据是**新建一条 HTTPRoute 能拿到 "
            f".status**；operator 日志里 'Required GatewayAPI resources are not found' "
            f"是故障信号（有输出=坏了），健康时不打日志，所以 grep 不到不等于健康。"
        )


RULES = {
    "V1": "同一 chart 在多个 Application 里必须同版本",
    "V2": "声明为同一事实的版本变量组必须取值一致",
    "V3": "cilium_version 与 gateway_api_version 必须符合兼容表",
    "V4": "versions.just 的共享变量不得被 import 方重新定义",
}


def main():
    if "--list" in sys.argv:
        for k, v in RULES.items():
            print(f"{k}  {v}")
        print(f"\n豁免：在版本所在行写 `{EXEMPT} <理由>`")
        return 0

    check_v1()
    check_v2()
    check_v3()
    check_v4()

    total = sum(len(v) for v in violations.values())
    if not total:
        print("✅ 版本配对检查通过（V1-V4）")
        print("   注意：本检查只保证「多处副本互相一致」与「配对符合表」，")
        print("   保证不了这些值与**现网实际跑的版本**一致 —— 那只能实测。")
        return 0

    print(f"❌ {total} 项违规\n")
    for rule in sorted(violations):
        print(f"[{rule}] {RULES.get(rule, '配对声明本身有问题')}")
        for v in violations[rule]:
            print(f"  {v}")
        print()
    print("规则全文与背景见 docs/reference/manifest-safety-checks.md")
    return 1


if __name__ == "__main__":
    sys.exit(main())
