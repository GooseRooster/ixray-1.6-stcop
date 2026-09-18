#!/usr/bin/env python3
"""upstream-sync helper: ledger/hot-zone/pending state for the merge+skip-ledger
upstream sync model. Stdlib only. Run from the repo root (or anywhere — paths
resolve from this file's location).

Subcommands:
  pending [--since <ref>]   incoming upstream commits, interest-classified,
                            hot-zone overlaps flagged (read-only, after fetch)
  hotzone                   derived hot-zone file set (fork-vs-upstream diff)
                            unioned with the hand-curated registry
  hotzone-add <pattern> --reason <why> [--added-via manual] [--related-commit <hash>]
  record <json|@file>       append ledger entries (validated; rejects private paths)
  render [--verdict skip]   ledger as a table
  skip-reverts              ledger skip entries (for the post-merge re-revert pass)
  mark-synced <hash>        update meta.json after a successful sync
  meta                      print meta.json
"""

import argparse
import datetime
import fnmatch
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
AGENTS_DIR = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
STATE_DIR = os.path.join(AGENTS_DIR, "upstream-merge")
LEDGER = os.path.join(STATE_DIR, "ledger", "ledger.jsonl")
META = os.path.join(STATE_DIR, "ledger", "meta.json")
HOTZONES = os.path.join(STATE_DIR, "hotzones.jsonl")
LOCAL_PATHS = os.path.join(STATE_DIR, "paths.local.json")

VERDICTS = {"skip", "conflict_note", "review_note"}

INTEREST_CATEGORIES = {
    "perf": re.compile(
        r"optimi[sz]|multithread|parallel|simd|sse|cache|memory pool|throughput|"
        r"faster|speed|performance|frame.?time|lod|cull", re.I),
    "modding": re.compile(
        r"dltx|dxml|lua|script|bindin|callback|config|console|xml|ini|ltx|"
        r"modding|extension", re.I),
    "graphics": re.compile(
        r"shader|render|bloom|volumetric|ssao|hbao|post.?process|lighting|particles|"
        r"texture|dx11|d3d|hdr|anti.?alias|taa|dlss|fsr", re.I),
    "infra": re.compile(
        r"xrCore|build|cmake|allocat|seriali[sz]|thread|memory|debug|assert|"
        r"sanitiz|rail|logger|profil|crash|fixed|refactor|clean", re.I),
}


def repo_root():
    return subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True,
                          text=True, check=True).stdout.strip()


def git(*args, check=True):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=check)


def upstream_ref():
    meta = load_meta()
    remote, branch = meta["upstream_remote"], meta["upstream_branch"]
    ref = f"{remote}/{branch}"
    have = git("rev-parse", "--verify", "--quiet", ref, check=False)
    return ref if have.returncode == 0 else None


def load_meta():
    with open(META, encoding="utf-8") as f:
        return json.load(f)


def load_ledger():
    if not os.path.exists(LEDGER):
        return []
    entries = []
    with open(LEDGER, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                entries.append(json.loads(line))
    return entries


def ledger_hashes():
    return {e["hash"] for e in load_ledger()}


def load_hotzone_registry():
    entries = []
    if os.path.exists(HOTZONES):
        with open(HOTZONES, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("//"):
                    entries.append(json.loads(line))
    return entries


def private_roots():
    """Machine-local private repo roots — used only as a privacy backstop."""
    if not os.path.exists(LOCAL_PATHS):
        return []
    with open(LOCAL_PATHS, encoding="utf-8") as f:
        return [str(v) for v in json.load(f).values()
                if isinstance(v, str) and v.startswith("/")]


def derive_divergence_files(ref):
    """Files this fork has changed relative to upstream (merge-base .. HEAD)."""
    r = git("diff", "--name-only", f"{ref}...HEAD", check=False)
    if r.returncode != 0:
        return []
    return [l for l in r.stdout.splitlines() if l]


def hotzone_set():
    patterns = [e["pattern"] for e in load_hotzone_registry()]
    derived = []
    ref = upstream_ref()
    if ref:
        derived = derive_divergence_files(ref)
    # Registry patterns are fnmatch globs over repo-relative paths.
    matched = set()
    for pattern in patterns:
        for path in derived or all_files():
            if fnmatch.fnmatch(path, pattern):
                matched.add(path)
        if not derived and "/" not in pattern.strip("*"):
            # No upstream ref yet: pattern itself is the best-known hot-zone path.
            matched.add(pattern)
    return {"derived": derived, "registry_patterns": patterns,
            "files": sorted(set(derived) | matched)}


def all_files():
    r = git("ls-files")
    return [l for l in r.stdout.splitlines() if l]


def classify_subject(subject):
    cats = [c for c, rx in INTEREST_CATEGORIES.items() if rx.search(subject)]
    return cats[0] if cats else None


def commit_files(h):
    r = git("diff-tree", "--no-commit-id", "--name-only", "-r", h)
    return [l for l in r.stdout.splitlines() if l]


def cmd_pending(args):
    ref = upstream_ref()
    if not ref:
        print(json.dumps({"error": f"no {ref} — run: git fetch <upstream> <branch> (see meta.json)"}))
        return 1
    base = args.since or "HEAD"
    r = git("log", "--format=%H%x1f%ad%x1f%s", "--date=short", f"{base}..{ref}")
    hot = set(hotzone_set()["files"])
    already = ledger_hashes()
    commits = []
    for line in r.stdout.splitlines():
        h, date, subject = line.split("\x1f", 2)
        files = commit_files(h)
        hits = sorted(f for f in files if f in hot)
        commits.append({
            "hash": h[:12], "date": date, "subject": subject,
            "interest_category": classify_subject(subject),
            "hot_zone": bool(hits), "hot_zone_files": hits,
            "files_touched": len(files),
            "in_ledger": h in already or h[:12] in already,
        })
    print(json.dumps({
        "upstream_ref": ref, "total_new": len(commits),
        "hot_zone": [c for c in commits if c["hot_zone"]],
        "by_category": {c: [x for x in commits if x["interest_category"] == c]
                        for c in ("perf", "modding", "graphics", "infra")},
        "other": [c for c in commits if c["interest_category"] is None],
        "commits": commits,
    }, indent=1))
    return 0


def cmd_hotzone(_args):
    print(json.dumps(hotzone_set(), indent=1))
    return 0


def cmd_hotzone_add(args):
    if not args.reason:
        print("error: --reason is required", file=sys.stderr)
        return 1
    entry = {"pattern": args.pattern, "reason": args.reason,
             "added_via": args.added_via, "added_date": datetime.date.today().isoformat()}
    if args.related_commit:
        entry["related_commit"] = args.related_commit
    with open(HOTZONES, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    print(f"hot-zone added: {args.pattern}")
    return 0


def validate_entry(entry):
    if not isinstance(entry, dict):
        return "entry must be a JSON object"
    if entry.get("verdict") not in VERDICTS:
        return f"verdict must be one of {sorted(VERDICTS)}"
    if not entry.get("hash") or not re.fullmatch(r"[0-9a-f]{6,40}", entry["hash"]):
        return "hash must be a git hash (6-40 hex)"
    if not entry.get("reason"):
        return "reason is required"
    if entry["verdict"] == "skip" and not entry.get("revert_hash") and not entry.get("revert_pending"):
        return "skip entries need revert_hash (or revert_pending: true if the revert is still to be created)"
    return None


def cmd_record(args):
    raw = args.entry
    if raw.startswith("@"):
        with open(raw[1:], encoding="utf-8") as f:
            entries = json.load(f)
    else:
        entries = json.loads(raw)
    if isinstance(entries, dict):
        entries = [entries]
    roots = private_roots()
    os.makedirs(os.path.dirname(LEDGER), exist_ok=True)
    with open(LEDGER, "a", encoding="utf-8") as f:
        for e in entries:
            err = validate_entry(e)
            if err:
                print(f"error: invalid entry for {e.get('hash', '?')}: {err}", file=sys.stderr)
                return 1
            blob = json.dumps(e, ensure_ascii=False)
            for root in roots:
                if root in blob:
                    print(f"error: entry for {e['hash']} leaks the private path root {root!r} — "
                          f"rewrite using repo-relative paths only", file=sys.stderr)
                    return 1
            f.write(blob + "\n")
    print(f"recorded {len(entries)} ledger entries")
    return 0


def cmd_render(args):
    entries = [e for e in load_ledger() if not args.verdict or e.get("verdict") == args.verdict]
    if not entries:
        print("(ledger empty)")
        return 0
    width = max(len(e["hash"][:12]) for e in entries)
    for e in entries:
        flags = []
        if e.get("revert_hash"):
            flags.append(f"revert={e['revert_hash'][:12]}")
        if e.get("reviewed"):
            flags.append("reviewed")
        print(f"{e['hash'][:12]:<{width}}  {e['verdict']:<14} {' '.join(flags):<24} {e['reason'][:90]}")
    return 0


def cmd_skip_reverts(_args):
    skips = [e for e in load_ledger() if e["verdict"] == "skip"]
    print(json.dumps(skips, indent=1) if skips else "(no skip entries)")
    return 0


def cmd_mark_synced(args):
    meta = load_meta()
    git("merge-base", "--is-ancestor", args.hash, "HEAD")  # raises if not merged
    meta["last_synced_upstream_hash"] = args.hash
    with open(META, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"meta.json updated: last_synced_upstream_hash={args.hash}")
    return 0


def cmd_meta(_args):
    print(json.dumps(load_meta(), indent=1))
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("pending"); sp.add_argument("--since"); sp.set_defaults(fn=cmd_pending)
    sub.add_parser("hotzone").set_defaults(fn=cmd_hotzone)
    sp = sub.add_parser("hotzone-add")
    sp.add_argument("pattern"); sp.add_argument("--reason"); sp.add_argument("--added-via", default="manual")
    sp.add_argument("--related-commit"); sp.set_defaults(fn=cmd_hotzone_add)
    sp = sub.add_parser("record"); sp.add_argument("entry"); sp.set_defaults(fn=cmd_record)
    sp = sub.add_parser("render"); sp.add_argument("--verdict"); sp.set_defaults(fn=cmd_render)
    sub.add_parser("skip-reverts").set_defaults(fn=cmd_skip_reverts)
    sp = sub.add_parser("mark-synced"); sp.add_argument("hash"); sp.set_defaults(fn=cmd_mark_synced)
    sub.add_parser("meta").set_defaults(fn=cmd_meta)

    args = p.parse_args()
    sys.exit(args.fn(args))


if __name__ == "__main__":
    main()
