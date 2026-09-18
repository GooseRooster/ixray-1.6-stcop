#!/usr/bin/env python3
"""upstream-review helper: group the incoming upstream batch by subsystem theme
for deep-dive review. Read-only (writes only the report file when asked).

Subcommands:
  group            incoming commits grouped by theme, riskiest-first
                   (hot-zone count, then size), with per-commit file lists
  write-report <slug> <json-file>   create reviews/<slug>-<date>.md stub
                                   (the agent fills in the analysis)
  list-reports     existing review reports
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
STATE_DIR = os.path.abspath(os.path.join(HERE, "..", "..", "..", "upstream-merge"))
REVIEWS_DIR = os.path.join(STATE_DIR, "reviews")

THEME_MAP = [
    (r"^src/xrGame/", "game-logic"),
    (r"^src/Layers/", "rendering"),
    (r"^src/xrCore/", "core-xrcore"),
    (r"^src/xrEngine/", "engine-xrengine"),
    (r"^src/xrScripts/", "scripting-modding"),
    (r"^src/(xrNetServer|xrServer|xrServerEntities|xrSound|xrPhysics|xrParticles|xrUI)/", "engine-libs"),
    (r"^cmake/|^CMakeLists|^CMakePresets|^\.github/", "build-system"),
    (r"^(utils|util|src/utils|src/Editors)/", "tools-sdk"),
    (r"^gamedata/", "gamedata"),
    (r"^docs/", "docs"),
]


def git(*args, check=True):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=check)


def theme_for(path):
    for rx, name in THEME_MAP:
        if re.search(rx, path):
            return name
    return "other"


def upstream_ref():
    r = git("rev-parse", "--verify", "--quiet", "upstream/default", check=False)
    return "upstream/default" if r.returncode == 0 else None


def cmd_group(_args):
    ref = upstream_ref()
    if not ref:
        print(json.dumps({"error": "no upstream/default — fetch first"}))
        return 1
    log = git("log", "--format=%H%x1f%ad%x1f%s", "--date=short", f"HEAD..{ref}")
    themes = {}
    for line in log.stdout.splitlines():
        h, date, subject = line.split("\x1f", 2)
        files = [l for l in git("diff-tree", "--no-commit-id", "--name-only", "-r", h).stdout.splitlines() if l]
        themes.setdefault("other", {"theme": "other", "commits": []})
        for f in files:
            t = theme_for(f)
            bucket = themes.setdefault(t, {"theme": t, "commits": [], "_files": set()})
            bucket["_files"].add(f)
        # attribute commit to the dominant theme
        counts = {}
        for f in files:
            counts[theme_for(f)] = counts.get(theme_for(f), 0) + 1
        dominant = max(counts, key=counts.get) if counts else "other"
        themes[dominant]["commits"].append({"hash": h[:12], "date": date, "subject": subject,
                                            "files": files})
    out = []
    for t in themes.values():
        t["commit_count"] = len(t["commits"])
        t["files"] = sorted(t.pop("_files"))
        out.append(t)
    out.sort(key=lambda t: (-len(t["files"]), -t["commit_count"]))
    print(json.dumps({"upstream_ref": ref, "themes": out}, indent=1))
    return 0


def cmd_write_report(args):
    with open(args.json_file, encoding="utf-8") as f:
        data = json.load(f)
    os.makedirs(REVIEWS_DIR, exist_ok=True)
    today = datetime.date.today().isoformat()
    path = os.path.join(REVIEWS_DIR, f"{args.slug}-{today}.md")
    if os.path.exists(path) and not args.force:
        print(f"error: {path} exists (use --force)", file=sys.stderr)
        return 1
    with open(path, "w", encoding="utf-8") as f:
        f.write(f"# Upstream review: {args.slug} ({today})\n\n")
        f.write(f"Upstream ref: {data.get('upstream_ref', 'upstream/default')}\n\n")
        f.write("## Commits under review\n\n")
        for c in data.get("commits", []):
            f.write(f"- `{c['hash']}` ({c.get('date','')}) {c.get('subject','')}\n")
        f.write("\n## Analysis\n\n(agent fills this in)\n\n")
        f.write("## Gotchas / flags\n\n- [ ] cross-compile hazards: \n- [ ] hot-zone conflicts expected: \n"
                "- [ ] playtest reminders: \n- [ ] behavior changes: \n")
    print(path)
    return 0


def cmd_list_reports(_args):
    if not os.path.isdir(REVIEWS_DIR):
        print("(no reviews yet)")
        return 0
    for name in sorted(os.listdir(REVIEWS_DIR)):
        print(name)
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("group").set_defaults(fn=cmd_group)
    sp = sub.add_parser("write-report")
    sp.add_argument("slug"); sp.add_argument("json_file"); sp.add_argument("--force", action="store_true")
    sp.set_defaults(fn=cmd_write_report)
    sub.add_parser("list-reports").set_defaults(fn=cmd_list_reports)
    args = p.parse_args()
    sys.exit(args.fn(args))


if __name__ == "__main__":
    main()
