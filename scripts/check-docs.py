#!/usr/bin/env python3
"""文档组织规则检查器 —— 强制 docs/RULES.md 里的 R1-R7。

用法:
    python3 scripts/check-docs.py          # 检查，有违规则 exit 1
    python3 scripts/check-docs.py --list   # 只列出规则覆盖情况

设计原则: **本脚本能查的，和 docs/RULES.md 写的规则必须一一对应。**
规则文档说得比检查器严，规则就是摆设；检查器比文档严，就会误伤。
改任何一边都要同步另一边。

只用标准库（CI 上不装依赖）。
"""
import re
import subprocess
import sys
import pathlib
from collections import defaultdict

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
# 第三方 vendored skill 包（skills-lock.json 管理），内部相对链接指向各自上游仓库，
# 不受本仓库文档规则约束。必须按 resolve() 后的路径判断：Python 3.13 之前
# rglob 会跟随目录软链，同一文件还会以 .claude/skills/<name>/ 路径再出现一次。
VENDORED = ROOT / ".agents"

# 带日期前缀的目录（R2）；其余为常青目录，文件名不得带日期
DATED_DIRS = {"plans", "records"}
# 需要 README 完整索引的目录（R5）
INDEXED = ["reference", "decisions", "runbooks", "guides", "records"]
# R4 状态标记：状态行必须带其中之一，否则无法扫读
STATUS_MARKERS = ["✅", "🚧", "📐", "⚠️", "❌"]

DATE_PREFIX = re.compile(r"^\d{4}-\d{2}-\d{2}-")
DATE_ANY = re.compile(r"\d{4}-\d{2}-\d{2}|\d{8}")
MD_LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
# 非 docs 文件里对 docs/ 的引用（注释里最常见，markdown 链接检查抓不到）
# ⚠️ 前面紧邻 `<字词>/` 的**不算本仓库的引用** —— 那是别的仓库的路径，本检查管不着它。
# 实例：prometheus-rules.yaml 里的 `nv-dgx-spark/docs/auto-mitigation-cn.md`（DGX 那个仓库的
# 规格文档）被当成本仓 docs/ 的坏链，自 2026-08-15 起让本检查在 main 上常红。
# 相对引用 `../docs/x.md` / `./docs/x.md` 不受影响（前一个字符是 `.` 不是 `[\w-]`），仍会被查。
DOCS_REF = re.compile(r"(?<![\w-]/)docs/[A-Za-z0-9_./-]+\.md")
# 文首的 `Last updated: YYYY-MM-DD` 字段（reference/ 必填，runbooks/guides 惯例也写）
LAST_UPDATED = re.compile(r"Last updated:\s*(\d{4}-\d{2}-\d{2})")

violations = defaultdict(list)


def fail(rule, path, msg, line=None):
    loc = f"{path.relative_to(ROOT)}" + (f":{line}" if line else "")
    violations[rule].append(f"{loc}  {msg}")


def head(text, n=16):
    return "\n".join(text.splitlines()[:n])


def status_line(text):
    """取文首那段里的状态行。

    只认**行首字段**（`> 状态:` / `> Status:` / `> Deprecated:`），不匹配标题或
    正文里恰好含"状态/Status"字样的行——2026-08-10 一篇 ADR 标题带"无状态"
    曾被误判成状态行，连带 R4 误报。
    """
    for i, ln in enumerate(text.splitlines()[:16], 1):
        if re.search(r"^\s*>?\s*(状态|Status|Deprecated)\s*[:：]", ln, re.I):
            return i, ln
    return None, None


def check_naming(md, rel):
    """R2 — 带日期的目录用 YYYY-MM-DD- 前缀，常青目录不带日期；全部小写 kebab-case。

    docs/ 顶层文档（README/AGENTS/ARCHITECTURE/ROADMAP）是约定俗成的
    全大写名，工具链按名字识别它们，豁免命名规则。
    """
    if md.name == "README.md" or len(rel.parts) == 1:
        return
    top = rel.parts[0]
    if top in DATED_DIRS:
        if not DATE_PREFIX.match(md.name):
            fail("R2", md, "缺 YYYY-MM-DD- 日期前缀")
    elif top:
        if DATE_ANY.search(md.name):
            fail("R2", md, "常青目录的文件名不应带日期——带日期通常说明它其实是快照，应移进 plans/")
    if md.name != md.name.lower():
        fail("R2", md, "文件名必须全小写")
    if "_" in md.stem:
        fail("R2", md, "用 kebab-case，不要下划线")


def check_h1(md, text):
    """R3 — H1 必须是第一行（banner/warning 放 H1 之后）。"""
    lines = [l for l in text.splitlines() if l.strip()]
    if not lines:
        fail("R3", md, "空文件")
    elif not lines[0].startswith("# "):
        fail("R3", md, f"H1 不在首行（首行是 {lines[0][:40]!r}）")


def check_frontmatter(md, rel, text):
    """R3 — 各目录的文首必填字段。README 是索引不是文档，不适用。"""
    if md.name == "README.md":
        return
    top = rel.parts[0] if len(rel.parts) > 1 else ""
    h = head(text)
    if top == "reference":
        if not re.search(r"Last updated", h):
            fail("R3", md, "reference/ 必须有 `Last updated:`")
        if not re.search(r"Status", h):
            fail("R3", md, "reference/ 必须有 `Status:`")
    elif top == "decisions":
        if not re.search(r"日期|Date", h):
            fail("R3", md, "ADR 必须有日期")
        if not re.search(r"^\s*>?\s*(状态|Status)\s*[:：]", h, re.I | re.M):
            fail("R3", md, "ADR 必须有状态")
    elif top == "plans":
        if not re.search(r"状态|Status|Deprecated", h):
            fail("R3", md, "plan 必须在文首写状态")
    elif top == "runbooks":
        if not re.search(r"触发|Trigger|适用|When to [Uu]se|使用场景|Goal|Purpose|目标", text):
            fail("R3", md, "runbook 必须写明触发条件/目标")


def check_status_enum(md, rel, text):
    """R4 — plans/decisions 的状态行必须带枚举标记，便于扫读。"""
    top = rel.parts[0] if len(rel.parts) > 1 else ""
    if top not in ("plans", "decisions") or md.name == "README.md":
        return
    ln, line = status_line(text)
    if line is None:
        return  # 缺状态由 R3 报，不重复
    if not any(m in line for m in STATUS_MARKERS):
        fail("R4", md, f"状态行缺枚举标记（{'/'.join(STATUS_MARKERS)}）: {line.strip()[:60]}", ln)


def check_indexes():
    """R5 — 每个目录的 README 列出本目录全部文档，且不含已不存在的条目。"""
    dirs = [DOCS / d for d in INDEXED] + sorted(p for p in (DOCS / "plans").glob("*") if p.is_dir())
    for d in dirs:
        if not d.is_dir():
            continue
        idx = d / "README.md"
        if not idx.exists():
            fail("R5", d, "缺 README.md 索引")
            continue
        body = idx.read_text()
        present = {f.name for f in d.glob("*.md")} - {"README.md"}
        for name in sorted(present):
            if name not in body:
                fail("R5", idx, f"未收录 {name}")
        # 反向：索引里指向本目录但已不存在的文件
        for target in MD_LINK.findall(body):
            t = target.split("#")[0]
            if not t or t.startswith(("http", "mailto:")) or "/" in t:
                continue
            if t.endswith(".md") and t not in present and t != "README.md":
                fail("R5", idx, f"索引指向已不存在的 {t}")


def check_plan_counts():
    """R5 — plans/README.md 的「份数」列必须与各类别实际文件数一致。

    这一列纯手工维护，每加一份 plan 就会漂（2026-08-03 architecture/storage 两行都漂了）。
    check_indexes 已经算过每个目录的实际份数，顺手比一下就行。
    """
    idx = DOCS / "plans" / "README.md"
    if not idx.exists():
        return
    row = re.compile(r"^\|\s*\[(\w[\w-]*)/\]\([^)]*\)\s*\|.*\|\s*(\d+)\s*\|\s*$")
    for i, line in enumerate(idx.read_text().splitlines(), 1):
        m = row.match(line)
        if not m:
            continue
        name, claimed = m.group(1), int(m.group(2))
        d = DOCS / "plans" / name
        if not d.is_dir():
            fail("R5", idx, f"份数表里的 {name}/ 不存在", i)
            continue
        actual = len({f.name for f in d.glob("*.md")} - {"README.md"})
        if actual != claimed:
            fail("R5", idx, f"{name}/ 份数写 {claimed}，实际 {actual}", i)


def check_readme_trees():
    """非 docs 的 README 里，目录树画出的子目录必须真实存在。

    2026-08-03 `cloudflare/README.md` 画了个早已退役的 `workers/`（Sink submodule，
    2026-05-27 删除）——目录树是最容易在重构后变成化石的部分，而它又是新人读的第一眼。
    只校验树的**第一层**（顶格 ├──/└──）且以 `/` 结尾的条目；更深的层级缩进后跳过。
    """
    entry = re.compile(r"^[├└]── ([^\s#]+)/")
    for p in sorted(ROOT.rglob("README.md")):
        rel = p.relative_to(ROOT)
        parts = rel.parts
        if parts[0] in (".git", "docs") or ".terraform" in parts or ".worktrees" in parts:
            continue
        if p.resolve().is_relative_to(VENDORED):
            continue
        base, in_fence = None, False
        for i, line in enumerate(p.read_text().splitlines(), 1):
            if line.startswith("```"):
                in_fence = not in_fence
                if not in_fence:
                    base = None
                continue
            if not in_fence:
                continue
            if base is None:
                # 树的第一行是根路径（相对仓库根），如 `argocd/` 或 `cloud/oracle/`
                root_line = line.strip()
                if root_line.endswith("/") and (ROOT / root_line).is_dir():
                    base = ROOT / root_line
                continue
            m = entry.match(line)
            if m and not (base / m.group(1)).is_dir():
                fail("TREE", p, f"目录树画了不存在的 {m.group(1)}/", i)


def check_links(md, text):
    """所有 docs 内的相对 markdown 链接必须解析得到。"""
    for i, line in enumerate(text.splitlines(), 1):
        for target in MD_LINK.findall(line):
            t = target.split("#")[0]
            if not t or t.startswith(("http", "mailto:", "#")):
                continue
            if not (md.parent / t).resolve().exists():
                fail("LINK", md, f"死链 -> {target}", i)


def check_external_refs():
    """非 docs 文件（yaml/sh/justfile 注释）里对 docs/ 的引用也必须解析得到。

    这类引用 markdown 链接检查抓不到，而它们恰恰最容易在文档改名后失效。
    """
    exts = {".md", ".yaml", ".yml", ".sh", ".tf"}
    for p in ROOT.rglob("*"):
        if not p.is_file():
            continue
        rel = p.relative_to(ROOT)
        parts = rel.parts
        if parts[0] in (".git", "docs") or ".terraform" in parts or ".worktrees" in parts:
            continue
        if p.resolve().is_relative_to(VENDORED):
            continue
        if p.suffix not in exts and p.name != "justfile":
            continue
        try:
            text = p.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        for i, line in enumerate(text.splitlines(), 1):
            for m in DOCS_REF.findall(line):
                # 外链里的 docs/ 路径（如 GitHub URL）不算
                if "://" in line.split(m)[0][-80:]:
                    continue
                if not (ROOT / m).exists():
                    fail("LINK", p, f"引用了不存在的 {m}", i)


def git(*args):
    """跑一条 git，失败返回 None（没有 git / 不是仓库 / 命令出错都当"查不了"）。"""
    try:
        r = subprocess.run(["git", "-C", str(ROOT), *args],
                           capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout if r.returncode == 0 else None


def last_content_commit(rel, limit=10):
    """该文件最后一次**内容**提交的日期；只改 `Last updated:` 那一行的提交不算。

    否则会自相矛盾：为了修时间戳而提交，本身又让时间戳变旧。
    """
    log = git("log", f"-{limit}", "--follow", "--format=%H %as", "--", rel)
    if not log:
        return None
    for line in log.splitlines():
        sha, _, date = line.partition(" ")
        patch = git("show", "--format=", "--unified=0", sha, "--", rel)
        if patch is None:
            return date.strip()
        changed = [l for l in patch.splitlines()
                   if l[:1] in "+-" and not l.startswith(("+++", "---"))]
        # 空 patch（改名提交在旧路径上取不到 diff）与纯时间戳提交一样，继续往前找
        if any(not LAST_UPDATED.search(l) for l in changed):
            return date.strip()
    return None


def check_last_updated():
    """`Last updated:` 不得早于该文件最后一次内容提交。

    2026-08-13 清理时 21 篇文档的时间戳落后于实际内容（services.md 写 08-06，
    正文却已含 08-11 的 BentoPDF）——读者据此判断"这页还新鲜"，判断的是假的。
    浅克隆/无 git 时**整条跳过**：历史不全，宁可不查也不误报。
    """
    if git("rev-parse", "--git-dir") is None:
        return
    if (git("rev-parse", "--is-shallow-repository") or "").strip() == "true":
        return
    for md in sorted(DOCS.rglob("*.md")):
        m = LAST_UPDATED.search(head(md.read_text(), 12))
        if not m:
            continue
        actual = last_content_commit(md.relative_to(ROOT).as_posix())
        if actual and m.group(1) < actual:
            fail("STAMP", md,
                 f"Last updated 写 {m.group(1)}，但内容最后一次提交是 {actual}——改了内容就得改这行")


RULES_COVERED = [
    ("R2", "命名（日期前缀 / 常青不带日期 / 小写 kebab-case）", "✅ 自动"),
    ("R3", "H1 在首行 + 各目录文首必填字段", "✅ 自动"),
    ("R4", "plans/decisions 状态带枚举标记", "✅ 自动"),
    ("R5", "目录 README 索引双向完整 + plans/README.md 份数与实际一致", "✅ 自动"),
    ("--", "docs 内相对链接 + 非 docs 文件对 docs/ 的引用", "✅ 自动"),
    ("--", "非 docs README 的目录树只画真实存在的子目录", "✅ 自动"),
    ("--", "`Last updated:` 不早于最后一次内容提交（浅克隆时跳过）", "✅ 自动"),
    ("R1", "目录归属（这份文档该放哪）", "⚠️ 需人判断"),
    ("R6", "唯一真相源（同一事实只维护一处）", "⚠️ 需人判断"),
    ("R7", "命令带执行上下文", "⚠️ 需人判断"),
]


def main():
    if "--list" in sys.argv:
        print("规则覆盖情况:\n")
        for rid, desc, cov in RULES_COVERED:
            print(f"  {cov}  {rid:3} {desc}")
        print("\n⚠️ 标记的三条是判断题，脚本查不了；且**没有任何检查能发现文档与集群漂移**")
        print("   （2026-07-31 那次 NFS 错误格式完美，是 kubectl 照出来的）。")
        return 0

    for md in sorted(DOCS.rglob("*.md")):
        rel = md.relative_to(DOCS)
        text = md.read_text()
        check_naming(md, rel)
        check_h1(md, text)
        check_frontmatter(md, rel, text)
        check_status_enum(md, rel, text)
        check_links(md, text)
    check_indexes()
    check_plan_counts()
    check_readme_trees()
    check_external_refs()
    check_last_updated()

    total = sum(len(v) for v in violations.values())
    n_docs = len(list(DOCS.rglob("*.md")))
    if not total:
        print(f"✅ {n_docs} 篇文档，0 违规")
        print("   注意：结构合规 ≠ 内容正确。文档与集群是否漂移，只能实测。")
        return 0

    print(f"❌ {n_docs} 篇文档，{total} 项违规\n")
    for rule in sorted(violations):
        print(f"[{rule}]")
        for v in violations[rule]:
            print(f"  {v}")
        print()
    print("规则全文见 docs/RULES.md。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
