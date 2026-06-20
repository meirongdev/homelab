#!/usr/bin/env python3
"""
Sync local ebooks into a calibre-web (cwa) ingest folder running in Kubernetes.

Compares a local directory against the calibre library DB + the ingest folder,
validates file integrity, copies new books into the pod's ingest path, and keeps
a local backup. Pod is resolved dynamically from a label selector (never hardcoded).

All inputs are parameterized — see `--help`. Defaults target the homelab
calibre-web (context k3s-homelab, ns personal-services, selector app=calibre-web).
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import zipfile

SUPPORTED_EXTS_DEFAULT = ".pdf,.epub,.mobi,.azw,.azw3,.cbz,.cbr,.djvu"

# Heuristic non-ebook filter (resumes, Confluence exports, work docs) — opt-in via --filter-non-ebooks.
NON_EBOOK_PATTERNS = [
    re.compile(r"^[A-Z]{1,2}_"),                 # BE_, SRE_, PM_ ...
    re.compile(r"linkedin_", re.I),
    re.compile(r"resume|\bcv\b|简历|履历", re.I),
    re.compile(r"-\d{6}-\d{6}\."),               # Name-YYMMDD-HHMMSS.pdf (Confluence export)
    re.compile(r"confluence", re.I),
    re.compile(r"\bfee\b|endpoint|finance", re.I),
]


def parse_args():
    p = argparse.ArgumentParser(
        description="Sync local ebooks into a calibre-web ingest folder (Kubernetes).",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("--source", default="~/Downloads/books", help="Local directory to scan for ebooks")
    p.add_argument("--context", default="k3s-homelab", help="kubectl context")
    p.add_argument("--namespace", default="personal-services", help="calibre-web namespace")
    p.add_argument("--selector", default="app=calibre-web", help="Label selector to find the calibre-web pod")
    p.add_argument("--ingest-path", default="/cwa-book-ingest", help="Ingest folder inside the pod")
    p.add_argument("--db-path", default="/calibre-library/metadata.db", help="calibre metadata.db path inside the pod")
    p.add_argument("--backup-dir", default="~/.local/share/calibre-web-sync-backup", help="Local backup directory")
    p.add_argument("--exts", default=SUPPORTED_EXTS_DEFAULT, help="Comma-separated supported extensions")
    p.add_argument("--dry-run", "--check-only", dest="dry_run", action="store_true",
                   help="Classify only; do not copy or back up")
    p.add_argument("--skip-validation", action="store_true", help="Skip epub/pdf integrity checks")
    p.add_argument("--no-backup", action="store_true", help="Do not keep a local backup of synced files")
    p.add_argument("--filter-non-ebooks", action="store_true",
                   help="Skip resumes / Confluence exports / work docs by filename heuristics")
    p.add_argument("--timeout", type=int, default=60, help="Timeout (s) for kubectl query/exec calls")
    p.add_argument("--cp-timeout", type=int, default=600, help="Timeout (s) for each kubectl cp (large files)")
    p.add_argument("--verbose", action="store_true", help="Verbose output")
    return p.parse_args()


def run_kubectl(ctx, args, timeout):
    cmd = ["kubectl", "--context", ctx] + args
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def resolve_pod(args):
    """Resolve the calibre-web pod name from the label selector. Abort if not found."""
    try:
        r = run_kubectl(args.context, [
            "get", "pods", "-n", args.namespace, "-l", args.selector,
            "--field-selector=status.phase=Running",
            "-o", "jsonpath={.items[0].metadata.name}",
        ], args.timeout)
    except FileNotFoundError:
        sys.exit("ERROR: kubectl not found on PATH")
    except subprocess.TimeoutExpired:
        sys.exit(f"ERROR: timed out resolving pod (context {args.context})")
    pod = r.stdout.strip()
    if r.returncode != 0 or not pod:
        sys.exit(f"ERROR: no Running pod matching '{args.selector}' in {args.context}/{args.namespace}\n"
                 f"  {r.stderr.strip()}")
    return pod


def get_existing_titles(args, pod):
    """Book titles from the calibre DB. Abort on failure (empty would defeat dedup)."""
    r = run_kubectl(args.context, [
        "exec", "-n", args.namespace, pod, "--",
        "sqlite3", args.db_path, "SELECT DISTINCT title FROM books;",
    ], args.timeout)
    if r.returncode != 0:
        sys.exit(f"ERROR: failed to read calibre DB ({args.db_path}) in pod {pod}\n"
                 f"  {r.stderr.strip()}\n"
                 f"  Refusing to continue — without titles, dedup is bypassed and duplicates would be ingested.")
    return {ln.strip() for ln in r.stdout.splitlines() if ln.strip()}


def get_ingest_filenames(args, pod):
    """Filenames already in the ingest dir. On failure, warn and continue (skip-set just empty)."""
    r = run_kubectl(args.context, [
        "exec", "-n", args.namespace, pod, "--",
        "find", args.ingest_path, "-maxdepth", "1", "-type", "f",
    ], args.timeout)
    if r.returncode != 0:
        print(f"  WARN: could not list ingest dir ({r.stderr.strip()}); continuing without ingest-skip")
        return set()
    return {os.path.basename(ln.strip()) for ln in r.stdout.splitlines() if ln.strip()}


def extract_title(filename):
    name = os.path.splitext(filename)[0]
    name = re.sub(r"\s*\([^)]*\)\s*$", "", name)   # (Author) / (Z-Library)
    name = re.sub(r"\s*\[[^]]*\]\s*$", "", name)   # [Z-Library]
    name = re.sub(r"\s+-\s+[^-]*$", "", name)       # " - Author" suffix
    return name.strip()


def is_non_ebook(filename):
    return any(p.search(filename) for p in NON_EBOOK_PATTERNS)


def validate_epub(path):
    try:
        with zipfile.ZipFile(path, "r") as zf:
            bad = zf.testzip()
            if bad:
                return False, f"Corrupted entry: {bad}"
            names = zf.namelist()
            if "mimetype" not in names:
                return False, "Missing mimetype"
            if not any("container.xml" in n for n in names):
                return False, "Missing container.xml"
        return True, "OK"
    except zipfile.BadZipFile:
        return False, "Not a valid ZIP"
    except Exception as e:  # noqa: BLE001
        return False, str(e)


def validate_pdf(path):
    try:
        with open(path, "rb") as f:
            if f.read(4) != b"%PDF":
                return False, "Missing %PDF header"
        return True, "OK"
    except Exception as e:  # noqa: BLE001
        return False, str(e)


def validate_file(path):
    ext = os.path.splitext(path)[1].lower()
    if ext == ".epub":
        return validate_epub(path)
    if ext == ".pdf":
        return validate_pdf(path)
    return True, "OK (no validation)"


def human_size(n):
    return f"{n / 1024:.0f}K" if n < 1024 * 1024 else f"{n / 1024 / 1024:.1f}M"


def main():
    args = parse_args()
    source = os.path.expanduser(args.source)
    backup_dir = os.path.expanduser(args.backup_dir)
    exts = {e if e.startswith(".") else f".{e}" for e in
            (x.strip().lower() for x in args.exts.split(",")) if e}

    if not os.path.isdir(source):
        sys.exit(f"ERROR: source directory not found: {source}")

    print("=" * 60)
    print("Ebook Sync" + ("  [DRY-RUN]" if args.dry_run else ""))
    print("=" * 60)
    print(f"Source:    {source}")
    print(f"Target:    {args.context}/{args.namespace}  ({args.selector}){args.ingest_path}")
    if not args.no_backup and not args.dry_run:
        print(f"Backup:    {backup_dir}")
    print()

    pod = resolve_pod(args)
    print(f"[1/5] calibre-web pod: {pod}")

    existing_titles = get_existing_titles(args, pod)
    print(f"[2/5] DB titles: {len(existing_titles)}")

    ingest_files = get_ingest_filenames(args, pod)
    print(f"[3/5] Files already in ingest: {len(ingest_files)}")

    print("[4/5] Classifying local files...")
    local = sorted(
        os.path.join(source, f) for f in os.listdir(source)
        if os.path.isfile(os.path.join(source, f))
        and os.path.splitext(f)[1].lower() in exts
    )
    to_sync, skip_ingest, skip_dup, skip_filter, corrupted = [], [], [], [], []
    for fp in local:
        fname = os.path.basename(fp)
        if fname in ingest_files:
            skip_ingest.append(fname); continue
        if args.filter_non_ebooks and is_non_ebook(fname):
            skip_filter.append(fname); continue
        if extract_title(fname) in existing_titles:
            skip_dup.append(fname); continue
        if not args.skip_validation:
            ok, msg = validate_file(fp)
            if not ok:
                corrupted.append((fname, msg)); continue
        to_sync.append((fp, fname, os.path.getsize(fp)))

    print(f"  ebooks found: {len(local)} | to sync: {len(to_sync)} | "
          f"in-ingest: {len(skip_ingest)} | duplicate: {len(skip_dup)} | "
          f"filtered: {len(skip_filter)} | corrupted: {len(corrupted)}")
    if corrupted:
        print("  Corrupted (skipped):")
        for fname, msg in corrupted:
            print(f"    - {fname}: {msg}")
    if args.verbose and to_sync:
        print("  To sync:")
        for _, fname, size in to_sync:
            print(f"    + {fname} ({human_size(size)})")

    if args.dry_run:
        print("\n[5/5] dry-run — nothing copied.")
        return 0

    if not args.no_backup:
        os.makedirs(backup_dir, exist_ok=True)

    print(f"\n[5/5] Syncing {len(to_sync)} book(s)...")
    success = failed = 0
    for fp, fname, size in to_sync:
        print(f"  {fname} ({human_size(size)})...", end=" ", flush=True)
        try:
            r = run_kubectl(args.context, [
                "cp", fp, f"{args.namespace}/{pod}:{args.ingest_path}/{fname}",
            ], args.cp_timeout)
        except subprocess.TimeoutExpired:
            print(f"FAILED (timeout > {args.cp_timeout}s)"); failed += 1; continue
        if r.returncode != 0:
            print("FAILED"); print(f"    {r.stderr.strip()}"); failed += 1; continue
        if not args.no_backup:
            try:
                shutil.copy2(fp, backup_dir)
            except Exception as e:  # noqa: BLE001
                print(f"OK (backup failed: {e})"); success += 1; continue
        print("OK"); success += 1

    print("\n" + "=" * 60)
    print(f"  synced: {success} | failed: {failed} | duplicate: {len(skip_dup)} | "
          f"in-ingest: {len(skip_ingest)} | filtered: {len(skip_filter)} | corrupted: {len(corrupted)}")
    if success and not args.no_backup:
        print(f"  backups: {backup_dir}")
    print("=" * 60)
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
