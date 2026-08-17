#!/usr/bin/env python3
"""calibre-web 书库去重。

取代 cleanup-duplicates.sh（2026-08-18）。旧脚本只认**完全同名**，60 组重复里只抓到 6 组；
且用 `DELETE FROM books` 收尾——link 表留孤儿行、书文件留在磁盘上，还把错误 `|| true` 吞掉。

本脚本：
  · 归一化标题匹配（忽略标点/空白/换行/版本号/括注），前缀匹配需作者交集
  · **拿真实磁盘核对计划**：calibre 的 books.path 可能过期（作者改名、标题含换行），
    "路径指不到文件" ≠ "文件没了"。误判会删掉活文件。
  · 同一本书的 EPUB/PDF 合并成一个条目（不同版本之间**不**合并，内容不同）
  · 用 `calibredb`（pod 内自带）删除——它会清 link 表并把书移入 .caltrash（14 天可恢复）
  · 备份 metadata.db 并**校验**（字节数 + integrity_check），校验不过就中止
  · 任何一步失败即非零退出，不吞错误

单文件双模式：本地运行时把**自己**送进 pod 再以 --worker 重新调用，因此没有重复实现。

用法（本地）：
    scripts/cleanup-duplicates.py --dry-run          # 只出计划，不动任何东西
    scripts/cleanup-duplicates.py                    # 交互确认后执行
    scripts/cleanup-duplicates.py --yes              # 跳过确认（CI/自动化）
配方见 k8s/helm/justfile 的 cleanup-calibre-dry-run / cleanup-calibre-duplicates。
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import unicodedata
from collections import defaultdict

# ---------------------------------------------------------------- 共用：匹配规则

_ORD = {"first": 1, "1st": 1, "1": 1, "second": 2, "2nd": 2, "2": 2, "third": 3, "3rd": 3,
        "3": 3, "fourth": 4, "4th": 4, "4": 4, "fifth": 5, "5th": 5, "5": 5, "sixth": 6,
        "6th": 6, "6": 6, "seventh": 7, "7th": 7, "7": 7, "eighth": 8, "8th": 8, "8": 8}
_ED_RE = re.compile(r"\b(first|second|third|fourth|fifth|sixth|seventh|eighth"
                    r"|\d+(?:st|nd|rd|th)?)\s+edition\b")
MEAP = -2          # Manning 预售草稿：排在**无版本标记的正式版**(None -> -1)之下
COMPANION = {"workbook", "companion", "solutions", "exercises"}


def edition(title: str):
    """版本序号。MEAP=草稿；`1 Edition` 视同无标记（就是初版）；查不到返回 None。"""
    t = title.lower()
    if "meap" in t:
        return MEAP
    m = _ED_RE.search(t)
    if not m:
        return None
    v = _ORD.get(m.group(1))
    return None if v == 1 else v


def ed_rank(e):
    return -1 if e is None else e


def norm(title: str) -> str:
    t = unicodedata.normalize("NFKC", title).lower()
    t = re.sub(r"[‐-―]", "-", t)
    t = re.sub(r"\(.*?\)|\[.*?\]", " ", t)          # 去掉 (for True Epub) 这类括注
    t = _ED_RE.sub(" ", t)
    t = re.sub(r"\bmeap\s*v?\d*\b", " ", t)
    t = re.sub(r"\bedition\b", " ", t)
    return re.sub(r"[^0-9a-z一-鿿]+", "", t)


def author_tokens(a: str) -> set:
    a = unicodedata.normalize("NFKC", a).lower()
    return set(re.findall(r"[a-z一-鿿]{3,}", a)) - {"etc", "and"}


def is_companion(t1: str, t2: str) -> bool:
    """`... Workbook` 是配套分册，不是主书的重复本。"""
    w1 = set(re.findall(r"[a-z]+", t1.lower()))
    w2 = set(re.findall(r"[a-z]+", t2.lower()))
    return bool((w1 ^ w2) & COMPANION)


def meta_score(title: str, author: str) -> float:
    s = 0.0
    if ":" in title:
        s += 2                                       # 冒号没被文件名清洗掉，元数据更完整
    if "_" in title:
        s -= 1
    if author and author.lower() not in ("unknown", "welcome.html"):
        s += 2
    return s + min(len(author), 40) / 40


# ---------------------------------------------------------------- pod 内：worker

def _lib_index(library: str) -> dict:
    """basename -> [绝对路径]，用来救回 path 已过期的记录。"""
    idx = defaultdict(list)
    for root, dirs, files in os.walk(library):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for f in files:
            if f.lower().endswith((".epub", ".pdf", ".mobi", ".azw", ".azw3", ".cbz", ".cbr", ".djvu")):
                idx[f].append(os.path.join(root, f))
    return idx


def _resolve(library: str, book_id: int, path: str, name: str, fmt: str, idx: dict,
             title: str = ""):
    """返回该格式在磁盘上的真实路径，找不到返回 None。

    依次尝试：DB 原路径 → 换行被清洗成空格/下划线的变体 → 全库 basename 索引。

    ☠️ basename 命中的采信条件是**两条同时成立**：目录名以 `(<book_id>)` 结尾，**且**目录名
    的标题部分与该书标题归一化后前缀相符。只查 `(id)` 是不够的——这个库里存在 id 被复用的
    历史遗留目录（`JavaScript Design Patterns (1513)` 而现役 1513 是另一本书），只按 id
    采信会把**别人的文件**挂到这本书上。2026-08-18 实测踩到。
    """
    rel = f"{path}/{name}.{fmt.lower()}"
    cands = [f"{library}/{rel}"]
    for repl in (" ", "_"):
        cands.append(f"{library}/{rel}".replace("\n", repl))
    for c in cands:
        if os.path.isfile(c):
            return c
    want = norm(title) if title else ""
    for hit in idx.get(f"{name}.{fmt.lower()}", []):
        d = os.path.basename(os.path.dirname(hit))
        if not d.endswith(f"({book_id})"):
            continue
        if want:
            got = norm(re.sub(r"\s*\(\d+\)$", "", d))
            if not (got and (want.startswith(got) or got.startswith(want))):
                continue                             # 目录标题与书名不符 -> 很可能是 id 复用
        return hit
    return None


def worker_plan(library: str) -> dict:
    import sqlite3
    db = sqlite3.connect(f"{library}/metadata.db")
    idx = _lib_index(library)

    books = []
    for bid, title, path in db.execute("SELECT id,title,path FROM books"):
        authors = ", ".join(r[0] for r in db.execute(
            "SELECT a.name FROM books_authors_link l JOIN authors a ON a.id=l.author WHERE l.book=?",
            (bid,)))
        real = {}
        for fmt, name in db.execute("SELECT format,name FROM data WHERE book=?", (bid,)):
            p = _resolve(library, bid, path, name, fmt, idx, title)
            if p:
                real[fmt] = p
        flat = re.sub(r"\s+", " ", title)
        books.append(dict(id=bid, title=flat, author=authors, real=real,
                          size=sum(os.path.getsize(p) for p in real.values()),
                          n=norm(title), a=author_tokens(authors), ed=edition(title)))

    # --- 分组：完全同名，或长前缀 + 作者交集
    seen, groups = set(), []
    for i, x in enumerate(books):
        if x["id"] in seen or not x["n"]:
            continue
        g = [x]
        for y in books[i + 1:]:
            if y["id"] in seen or not y["n"]:
                continue
            same = x["n"] == y["n"]
            shorter = min(x["n"], y["n"], key=len)
            pref = len(shorter) >= 18 and (x["n"].startswith(y["n"]) or y["n"].startswith(x["n"]))
            if not (same or pref):
                continue
            if pref and not same and not (x["a"] & y["a"]):
                continue
            if is_companion(x["title"], y["title"]):
                continue
            g.append(y)
        if len(g) > 1:
            seen.update(m["id"] for m in g)
            groups.append(g)

    corrections, merges, dels, view = [], [], [], []
    for g in sorted(groups, key=lambda g: min(m["id"] for m in g)):
        have = [m for m in g if m["real"]]
        if not have:
            corrections.append(f"{[m['id'] for m in g]}: 全组在磁盘上都没有文件 -> 整组跳过")
            continue
        keep = max(have, key=lambda m: (ed_rank(m["ed"]), len(m["real"]), m["size"],
                                        meta_score(m["title"], m["author"])))
        ghosts = [m["id"] for m in g if not m["real"]]
        if ghosts:
            corrections.append(f"id={ghosts} 磁盘上没有文件（空壳记录）-> 直接删除")
        kept_fmts = set(keep["real"])
        for m in have:
            if m["id"] == keep["id"]:
                continue
            if m["ed"] != keep["ed"]:
                corrections.append(
                    f"id={m['id']} 与保留项 {keep['id']} 版本不同 -> 删除，**不**合并格式（内容不同）")
                continue
            for fmt, p in sorted(m["real"].items()):
                if fmt not in kept_fmts:
                    merges.append([keep["id"], fmt, p])
                    kept_fmts.add(fmt)
        dels.extend(m["id"] for m in g if m["id"] != keep["id"])
        view.append(dict(keep=keep["id"],
                         members=[[m["id"], m["title"][:70], m["author"][:50],
                                   "+".join(sorted(m["real"])) or "-", m["size"], m["ed"]]
                                  for m in sorted(g, key=lambda m: m["id"])]))

    assert not (set(dels) & {v["keep"] for v in view}), "同一本书既保留又删除"
    return dict(groups=view, merges=merges, dels=sorted(dels), corrections=corrections,
                total_books=db.execute("SELECT COUNT(*) FROM books").fetchone()[0])


def worker_apply(library: str, plan: dict) -> dict:
    cdb = ["calibredb", f"--with-library={library}"]
    out = {"merged": [], "merge_failed": [], "removed": 0, "remove_output": ""}
    for keep, fmt, path in plan["merges"]:
        if not os.path.isfile(path):
            out["merge_failed"].append([keep, fmt, "源文件在执行前消失了"])
            continue
        r = subprocess.run(cdb + ["add_format", str(keep), path],
                           capture_output=True, text=True)
        # add_format 会打 calibre/db/page_count.py 的 traceback（可选的页数统计 worker），
        # 那是**非致命**的——只看 returncode。
        if r.returncode == 0:
            out["merged"].append([keep, fmt])
        else:
            out["merge_failed"].append([keep, fmt, (r.stdout + r.stderr).strip()[:300]])
    if out["merge_failed"]:
        return out                                   # 合并有失败 -> 一本都不删
    if plan["dels"]:
        r = subprocess.run(cdb + ["remove", ",".join(map(str, plan["dels"]))],
                           capture_output=True, text=True)
        out["remove_output"] = (r.stdout + r.stderr).strip()[:600]
        out["remove_rc"] = r.returncode
        if r.returncode == 0:
            out["removed"] = len(plan["dels"])
    return out


def worker_verify(library: str) -> dict:
    import sqlite3
    db = sqlite3.connect(f"{library}/metadata.db")
    orphans = {}
    for t in ("books_authors_link", "books_tags_link", "books_series_link",
              "books_publishers_link", "books_languages_link", "data", "comments", "identifiers"):
        try:
            orphans[t] = db.execute(
                f"SELECT COUNT(*) FROM {t} WHERE book NOT IN (SELECT id FROM books)").fetchone()[0]
        except sqlite3.Error:
            orphans[t] = -1
    idx = _lib_index(library)
    missing = 0
    for bid, title, path in db.execute("SELECT id,title,path FROM books"):
        for fmt, name in db.execute("SELECT format,name FROM data WHERE book=?", (bid,)):
            if not _resolve(library, bid, path, name, fmt, idx, title):
                missing += 1
    trash = 0
    for root, _d, files in os.walk(f"{library}/.caltrash"):
        trash += sum(os.path.getsize(os.path.join(root, f)) for f in files)
    return dict(books=db.execute("SELECT COUNT(*) FROM books").fetchone()[0],
                orphan_rows=orphans, files_missing=missing,
                remaining_groups=len(worker_plan(library)["groups"]),
                trash_bytes=trash)


# ---------------------------------------------------------------- 本地：orchestrator

def kubectl(ctx: str, args: list, **kw) -> subprocess.CompletedProcess:
    return subprocess.run(["kubectl", "--context", ctx] + args,
                          capture_output=True, text=True, **kw)


def human(n: float) -> str:
    for u in ("B", "K", "M", "G"):
        if n < 1024 or u == "G":
            return f"{n:.1f}{u}"
        n /= 1024


def main() -> int:
    p = argparse.ArgumentParser(description="calibre-web 书库去重")
    p.add_argument("--context", default="oracle-k3s",
                   help="kubectl context（calibre 2026-08-02 起在 oracle-k3s）")
    p.add_argument("--namespace", default="personal-services")
    p.add_argument("--selector", default="app=calibre-web")
    p.add_argument("--container", default="calibre-web")
    p.add_argument("--library", default="/calibre-library")
    p.add_argument("--backup-dir", default=os.path.expanduser("~/.local/share/calibre-cleanup"))
    p.add_argument("--dry-run", action="store_true", help="只出计划，不动任何东西")
    p.add_argument("--yes", action="store_true", help="跳过交互确认")
    p.add_argument("--no-restart", action="store_true", help="结束后不重启 deployment")
    # worker 模式（pod 内自用，不要手动调）
    p.add_argument("--worker", choices=["plan", "apply", "verify"], help=argparse.SUPPRESS)
    a = p.parse_args()

    if a.worker:                                     # ---- 在 pod 内
        if a.worker == "plan":
            print(json.dumps(worker_plan(a.library)))
        elif a.worker == "apply":
            print(json.dumps(worker_apply(a.library, json.load(open("/tmp/dedup-plan.json")))))
        else:
            print(json.dumps(worker_verify(a.library)))
        return 0

    # ---- 1. 定位 pod
    r = kubectl(a.context, ["-n", a.namespace, "get", "pod", "-l", a.selector,
                            "-o", "jsonpath={.items[*].metadata.name}"])
    pods = r.stdout.split()
    if r.returncode != 0 or not pods:
        print(f"✗ 在 {a.context}/{a.namespace} 找不到 {a.selector} 的 pod\n{r.stderr.strip()}",
              file=sys.stderr)
        return 1
    pod = pods[0]
    print(f"ℹ pod: {pod}  ({a.context}/{a.namespace}, library={a.library})")

    def in_pod(args: list, stdin: str | None = None):
        return kubectl(a.context, ["-n", a.namespace, "exec"] + (["-i"] if stdin else []) +
                       [pod, "-c", a.container, "--"] + args, input=stdin)

    # ---- 2. 把自己送进 pod
    me = open(__file__, "rb").read()
    r = in_pod(["sh", "-c", "base64 -d > /tmp/dedup.py"], stdin=base64.b64encode(me).decode())
    if r.returncode != 0:
        print(f"✗ 无法把脚本送进 pod: {r.stderr.strip()}", file=sys.stderr)
        return 1

    # ---- 3. 出计划（在 pod 内直读 sqlite + 核对磁盘）
    r = in_pod(["python3", "/tmp/dedup.py", "--worker", "plan", "--library", a.library])
    if r.returncode != 0:
        print(f"✗ 生成计划失败: {(r.stdout + r.stderr).strip()[:800]}", file=sys.stderr)
        return 1
    plan = json.loads(r.stdout)

    for g in plan["groups"]:
        print(f"\n[keep={g['keep']}]")
        for bid, title, author, fmt, size, ed in g["members"]:
            print(f"  {'保留' if bid == g['keep'] else '删除'} {bid:<6}{human(size):>8} "
                  f"{fmt:<10} ed={ed if ed is not None else '-':<4} {title}")
            print(f"         {author}")
    if plan["corrections"]:
        print(f"\n判定说明 ({len(plan['corrections'])}):")
        for c in plan["corrections"]:
            print("  -", c)
    print(f"\n{'=' * 66}")
    print(f"  {plan['total_books']} 本 -> {plan['total_books'] - len(plan['dels'])} 本"
          f"（{len(plan['groups'])} 组重复，删 {len(plan['dels'])} 本，合并 {len(plan['merges'])} 个格式）")
    print("=" * 66)

    if not plan["dels"] and not plan["merges"]:
        print("✓ 没有重复书籍")
        return 0
    if a.dry_run:
        print("✓ dry-run，未改动任何东西")
        return 0

    # ---- 4. 备份 metadata.db 并校验（校验不过就中止——旧脚本这里是 `|| true`）
    #
    # ☠️ metadata.db 是 **WAL 模式**：最近的事务都还在 metadata.db-wal 里，直接 `cat`
    # 主库文件会拿到一份**落后的**快照。而且骗人的地方在于——文件字节数可能一模一样
    # （SQLite 删行不缩容），integrity_check 也照样 ok。所以：
    #   ① 用 sqlite3 的 `.backup`（online-backup API，含 WAL 内容）
    #   ② 校验必须比 **books 行数与现网是否一致**，不能只比字节数
    os.makedirs(a.backup_dir, exist_ok=True)
    ts = in_pod(["date", "+%Y%m%d-%H%M%S"]).stdout.strip()
    dest = os.path.join(a.backup_dir, f"metadata-{ts}.db")
    tmp = "/tmp/calibre-metadata-backup.db"
    r = in_pod(["sh", "-c", f"rm -f {tmp} && sqlite3 {a.library}/metadata.db '.backup {tmp}'"])
    if r.returncode != 0:
        print(f"✗ 生成一致快照失败，中止: {r.stderr.strip()[:300]}", file=sys.stderr)
        return 1
    want = int(in_pod(["stat", "-c", "%s", tmp]).stdout.strip())
    # 二进制必须走 bytes（text=True 会按 utf-8 解码并破坏内容）
    with open(dest, "wb") as fh:
        rc = subprocess.run(["kubectl", "--context", a.context, "-n", a.namespace, "exec",
                             pod, "-c", a.container, "--", "cat", tmp],
                            stdout=fh, stderr=subprocess.DEVNULL).returncode
    got = os.path.getsize(dest) if os.path.isfile(dest) else 0
    if rc != 0 or want != got:
        print(f"✗ 备份字节数不符 (pod={want} local={got})，中止", file=sys.stderr)
        return 1
    import sqlite3
    if sqlite3.connect(dest).execute("PRAGMA integrity_check").fetchone()[0] != "ok":
        print("✗ 备份 integrity_check 不通过，中止", file=sys.stderr)
        return 1
    n_backup = sqlite3.connect(dest).execute("SELECT COUNT(*) FROM books").fetchone()[0]
    if n_backup != plan["total_books"]:
        print(f"✗ 备份里是 {n_backup} 本、现网是 {plan['total_books']} 本——快照落后于现网"
              f"（WAL 没被包含？），中止", file=sys.stderr)
        return 1
    in_pod(["rm", "-f", tmp])
    print(f"✓ 备份已校验: {dest} ({want} bytes, integrity_check=ok, books={n_backup} 与现网一致)")

    # ---- 5. 确认
    if not a.yes:
        try:
            if input(f"\n删除 {len(plan['dels'])} 本、合并 {len(plan['merges'])} 个格式？(y/N): ")\
                    .strip().lower() not in ("y", "yes"):
                print("已取消")
                return 0
        except EOFError:
            print("✗ 非交互环境请显式加 --yes", file=sys.stderr)
            return 1

    # ---- 6. 执行：先合并，任一合并失败则一本都不删
    in_pod(["sh", "-c", "base64 -d > /tmp/dedup-plan.json"],
           stdin=base64.b64encode(json.dumps(plan).encode()).decode())
    r = in_pod(["python3", "/tmp/dedup.py", "--worker", "apply", "--library", a.library])
    if r.returncode != 0:
        print(f"✗ 执行失败: {(r.stdout + r.stderr).strip()[:800]}", file=sys.stderr)
        return 1
    res = json.loads(r.stdout)
    print(f"\n✓ 合并 {len(res['merged'])} 个格式")
    if res["merge_failed"]:
        print(f"✗ {len(res['merge_failed'])} 个合并失败，**未删除任何书**：", file=sys.stderr)
        for f in res["merge_failed"]:
            print(f"    {f}", file=sys.stderr)
        return 1
    if res.get("remove_rc", 0) != 0:
        print(f"✗ calibredb remove 失败: {res['remove_output']}", file=sys.stderr)
        return 1
    print(f"✓ 删除 {res['removed']} 本")

    # ---- 7. 复验
    r = in_pod(["python3", "/tmp/dedup.py", "--worker", "verify", "--library", a.library])
    v = json.loads(r.stdout) if r.returncode == 0 else {}
    bad = [t for t, n in v.get("orphan_rows", {}).items() if n]
    print(f"\n复验：{v.get('books')} 本 · 残留重复组 {v.get('remaining_groups')} · "
          f"孤儿链接行 {'0（全部干净）' if not bad else bad} · "
          f"DB 有记录但磁盘缺文件 {v.get('files_missing')} 个格式")
    print(f"       .caltrash {human(v.get('trash_bytes', 0))}"
          f"（被删的书在这里，calibre 默认 14 天后自动过期；期间可恢复）")

    # ---- 8. 日志 + 重启
    log = os.path.join(a.backup_dir, f"cleanup-{ts}.log")
    with open(log, "w") as fh:
        fh.write(f"calibre 去重 {ts}  context={a.context} ns={a.namespace} library={a.library}\n")
        fh.write(f"备份: {dest} ({want} bytes, integrity_check=ok)\n")
        fh.write(f"{plan['total_books']} -> {v.get('books')} 本；删 {res['removed']}，"
                 f"合并格式 {len(res['merged'])}\n")
        fh.write(f"复验: 残留重复组={v.get('remaining_groups')} 孤儿行={v.get('orphan_rows')} "
                 f"缺文件={v.get('files_missing')} trash={v.get('trash_bytes')}B\n\n")
        for c in plan["corrections"]:
            fh.write(f"  - {c}\n")
        fh.write("\n")
        for g in plan["groups"]:
            fh.write(f"[keep={g['keep']}]\n")
            for bid, title, author, fmt, size, ed in g["members"]:
                fh.write(f"  {'KEEP' if bid == g['keep'] else 'DEL '} {bid:<6}{size:>12} "
                         f"{fmt:<10} ed={ed} {title}\n")
            fh.write("\n")
    print(f"✓ 日志: {log}")

    if not a.no_restart:
        print("ℹ 重启 calibre-web（让它丢掉缓存的 DB）...")
        kubectl(a.context, ["-n", a.namespace, "rollout", "restart", "deployment/calibre-web"])
        rs = kubectl(a.context, ["-n", a.namespace, "rollout", "status",
                                 "deployment/calibre-web", "--timeout=180s"])
        print("✓ 已重启" if rs.returncode == 0 else "⚠ 重启未在 180s 内就绪，自己看一眼")
    return 0


if __name__ == "__main__":
    sys.exit(main())
