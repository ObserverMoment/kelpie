#!/usr/bin/env python3
"""Rebrand a Supacode source tree as Kelpie, in place.

Usage: scripts/rebrand.py <tree>

scripts/sync-upstream.sh runs this over each upstream snapshot so that merges
only carry real upstream changes. Keep it deterministic: the same input tree
must always produce the same output tree.
"""
import functools
import os
import pathlib
import re
import sys

REPO_URL = "https://github.com/ObserverMoment/kelpie"

# Skipped entirely: git metadata, submodules, and build output.
SKIP_DIRS = {".git", "ThirdParty", "git-wt", ".build"}
# The license keeps Supabit's name; lockfiles carry no brand strings.
SKIP_FILES = {"LICENSE", "Package.resolved"}
# Supabit's release and issue-bot pipelines, which need Supabit's secrets.
DROP_PATHS = [
    f".github/workflows/{name}.yml"
    for name in ("main", "issue-normalize", "issue-ready", "issue-received", "labels", "pr-policy", "pullfrog")
]

CONTENT_RULES = [
    # Links and identifiers that must not fall through to the generic rename.
    (r"https://supacode\.sh/download/latest/appcast\.xml", f"{REPO_URL}/releases/latest/download/appcast.xml"),
    (r"https://supacode\.sh", REPO_URL),
    (r"supabitapp/supacode", "ObserverMoment/kelpie"),
    (r"app\.supabit\.supacode", "com.observermoment.kelpie"),
    (r"app\.supabit\.", "com.observermoment."),
    (r"sh\.supacode\.", "com.observermoment.kelpie."),
    # zmx session prefix: same 5-byte length, so socket path budgets still hold.
    (r"supa-", "kelp-"),
    (r"supa_(rc|delay)", r"kelp_\1"),
    (r"SupaLogger", "KelpieLogger"),
    (r"SupaSessions", "KelpSessions"),
    (r"Supaignore", "Kelpieignore"),
    (r"supaignore", "kelpieignore"),
    (r"SUPACODE", "KELPIE"),
    (r"Supacode", "Kelpie"),
    (r"supacode", "kelpie"),
]
PATH_RULES = [
    (r"SupaLogger", "KelpieLogger"),
    (r"Supaignore", "Kelpieignore"),
    (r"supaignore", "kelpieignore"),
    (r"SUPACODE", "KELPIE"),
    (r"Supacode", "Kelpie"),
    (r"supacode", "kelpie"),
]


def rewrite(text, rules):
    return functools.reduce(lambda acc, rule: re.sub(rule[0], rule[1], acc), rules, text)


def walk(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        yield pathlib.Path(dirpath), dirnames, sorted(filenames)


def read_text(path):
    try:
        return path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return None


def rebrand(root):
    for relative in DROP_PATHS:
        (root / relative).unlink(missing_ok=True)

    files = [d / f for d, _, fs in walk(root) for f in fs if f not in SKIP_FILES]
    texts = {p: read_text(p) for p in files if not p.is_symlink()}
    changed = {p: rewrite(t, CONTENT_RULES) for p, t in texts.items() if t is not None}
    for path, new in changed.items():
        if new != texts[path]:
            path.write_text(new, encoding="utf-8")

    # Deepest paths first, so renaming a directory never invalidates a pending child rename.
    paths = sorted({d / n for d, ds, fs in walk(root) for n in ds + fs}, key=lambda p: len(p.parts), reverse=True)
    renames = [(p, p.with_name(rewrite(p.name, PATH_RULES))) for p in paths]
    for src, dst in renames:
        if src != dst:
            src.rename(dst)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    rebrand(pathlib.Path(sys.argv[1]))
