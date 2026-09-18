#!/usr/bin/env python3
"""port-ow-feature helper: machine-local private repo path resolution.

The pointer file .agents/upstream-merge/paths.local.json is GITIGNORED and must
never be committed — it holds absolute paths to the private Old World repos.
Nothing tracked in this repo may contain those paths (sync_helpers.record
mechanically rejects ledger entries that leak them).

Subcommands:
  set-path <oldworld_repo> <oldworld_game> <xray_monolith>
                            one-time machine setup (absolute paths, must exist)
  resolve                   print the resolved paths as JSON
"""

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
STATE_DIR = os.path.abspath(os.path.join(HERE, "..", "..", "..", "upstream-merge"))
LOCAL_PATHS = os.path.join(STATE_DIR, "paths.local.json")
EXAMPLE = LOCAL_PATHS + ".example"


def cmd_set_path(args):
    paths = {"oldworld_repo": os.path.abspath(args.oldworld_repo),
             "oldworld_game": os.path.abspath(args.oldworld_game),
             "xray_monolith": os.path.abspath(args.xray_monolith)}
    for key, p in paths.items():
        if not os.path.isdir(p):
            print(f"error: {key}: {p} is not a directory", file=sys.stderr)
            return 1
    repo_root = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
    for key, p in paths.items():
        if os.path.commonpath([repo_root, p]) in (repo_root, p) and p != repo_root:
            if os.path.commonpath([repo_root, p]) == repo_root:
                print(f"error: {key}: {p} is inside this engine repo — expected a separate private repo",
                      file=sys.stderr)
                return 1
    with open(LOCAL_PATHS, "w", encoding="utf-8") as f:
        json.dump(paths, f, indent=2)
        f.write("\n")
    print(f"paths.local.json written ({', '.join(paths)})")
    return 0


def cmd_resolve(_args):
    if not os.path.exists(LOCAL_PATHS):
        print(json.dumps({
            "error": "paths.local.json not set up",
            "fix": f"run: python3 {__file__} set-path <oldworld_repo> <oldworld_game> <xray_monolith>  "
                   f"(schema: {EXAMPLE})",
        }))
        return 1
    with open(LOCAL_PATHS, encoding="utf-8") as f:
        print(json.dumps(json.load(f), indent=1))
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sp = sub.add_parser("set-path")
    sp.add_argument("oldworld_repo"); sp.add_argument("oldworld_game"); sp.add_argument("xray_monolith")
    sp.set_defaults(fn=cmd_set_path)
    sub.add_parser("resolve").set_defaults(fn=cmd_resolve)
    args = p.parse_args()
    sys.exit(args.fn(args))


if __name__ == "__main__":
    main()
