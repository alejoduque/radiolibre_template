#!/usr/bin/env python3
"""
Repair links whose only fault is capitalisation.

    fix-link-case.py --dry-run     report what would change, write nothing
    fix-link-case.py               back up, then rewrite

These archives were mirrored from case-insensitive filesystems, so a page can
link to "Re.html" while the file on disk is "re.html", or to "f0am_WORM/" while
the directory is "F0am_WORM/". That worked on the original server and 404s on
Linux, where the filesystem is case-sensitive.

The fix is to correct the links, not to rename the files: renaming would break
every OTHER link that already spells the name correctly.

A link is only rewritten when a case-insensitive walk finds EXACTLY ONE match
for every path segment. If a directory holds both "Re.html" and "re.html" the
link is ambiguous and is reported, never guessed at.

Tests: tools/test/test_link_case.py, which simulates a case-sensitive
filesystem. Building a real fixture on macOS proves nothing, because APFS is
case-insensitive and reports that "Re.html" exists when the file is "re.html".
"""

import argparse
import html
import os
import re
import subprocess
import sys
import time
from urllib.parse import quote, unquote, urlsplit

# URL prefix -> filesystem root. /mdelibre is a symlink to /var/www/html, and
# /var/www/html/dorkbotmde is a further symlink; os.scandir follows both.
URL_PREFIX = "/mdelibre/"
FS_ROOT = "/var/www/html"

# Directories scanned for HTML to repair.
ROOTS = ["/var/www/html", "/var/www/dorkbotmde", "/var/www/hotglues"]

OUR_HOSTS = {"altred.xyz", "www.altred.xyz"}

LINK_RE = re.compile(r'(?P<attr>\b(?:href|src))\s*=\s*"(?P<url>[^"]*)"', re.I)

SKIP_SCHEMES = ("mailto:", "javascript:", "data:", "tel:", "#")


def resolve_ci(path):
    """Resolve `path` case-insensitively, one segment at a time.

    Returns the real path, or None when a segment is missing or ambiguous.
    """
    if os.path.exists(path):
        return path

    parts = path.strip("/").split("/")
    current = "/"
    for part in parts:
        candidate = os.path.join(current, part)
        if os.path.exists(candidate):
            current = candidate
            continue
        try:
            entries = os.listdir(current)
        except OSError:
            return None
        matches = [e for e in entries if e.lower() == part.lower()]
        if len(matches) != 1:
            # Zero matches means it is genuinely gone; more than one means the
            # directory holds names differing only by case and we cannot know
            # which was meant.
            return None
        current = os.path.join(current, matches[0])
    return current


def url_to_fs(url_path, page_dir):
    """Map a URL path to a filesystem path, or None if it is not ours."""
    if url_path.startswith(URL_PREFIX):
        return os.path.join(FS_ROOT, unquote(url_path[len(URL_PREFIX):]))
    if url_path.startswith("/"):
        return None  # root-relative but outside /mdelibre/: not ours to fix
    return os.path.join(page_dir, unquote(url_path))


def fs_to_url(fs_path):
    """Map a filesystem path back to a URL path under /mdelibre/."""
    real_root = os.path.realpath(FS_ROOT)
    real = os.path.realpath(fs_path)
    if real.startswith(real_root + "/"):
        rel = real[len(real_root) + 1:]
    else:
        # Reached through a symlink that leaves FS_ROOT (dorkbotmde). Recover
        # the served path from the unresolved path instead.
        rel = os.path.relpath(fs_path, FS_ROOT)
        if rel.startswith(".."):
            return None
    return URL_PREFIX + quote(rel)


def iter_html(roots):
    for root in roots:
        for dirpath, _dirnames, filenames in os.walk(root, followlinks=False):
            for name in filenames:
                if name.lower().endswith((".html", ".htm")):
                    yield os.path.join(dirpath, name)


def main():
    global FS_ROOT, URL_PREFIX

    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--roots", nargs="*", default=ROOTS)
    # Overridable so the tool can be exercised against a fixture; URL-to-disk
    # mapping is the part most worth testing, and it is useless if the test
    # still resolves against the real /var/www/html.
    ap.add_argument("--fs-root", default=FS_ROOT)
    ap.add_argument("--url-prefix", default=URL_PREFIX)
    args = ap.parse_args()

    FS_ROOT = args.fs_root.rstrip("/")
    URL_PREFIX = args.url_prefix

    roots = [r for r in args.roots if os.path.isdir(r)]
    if not roots:
        sys.exit("error: none of the roots exist: " + " ".join(args.roots))

    files = list(iter_html(roots))
    print(f"html files: {len(files)}")

    edits = {}          # file -> [(old_url, new_url), ...]
    missing = 0

    for path in files:
        try:
            text = open(path, encoding="utf-8", errors="surrogateescape").read()
        except OSError:
            continue

        page_dir = os.path.dirname(path)
        changes = []

        for m in LINK_RE.finditer(text):
            raw = m.group("url").strip()
            if not raw or raw.lower().startswith(SKIP_SCHEMES):
                continue

            url = html.unescape(raw)
            split = urlsplit(url)
            if split.scheme and split.netloc not in OUR_HOSTS:
                continue  # somebody else's site
            if split.scheme and split.netloc in OUR_HOSTS:
                url_path = split.path
            else:
                url_path = split.path
            if not url_path:
                continue

            fs = url_to_fs(url_path, page_dir)
            if fs is None:
                continue
            if os.path.exists(fs):
                continue  # already correct

            fixed = resolve_ci(fs)
            if fixed is None:
                missing += 1
                continue

            new_url_path = fs_to_url(fixed)
            if new_url_path is None:
                continue

            # Preserve whatever form the original link used.
            if split.scheme:
                new_url = f"{split.scheme}://{split.netloc}{new_url_path}"
            elif url_path.startswith("/"):
                new_url = new_url_path
            else:
                new_url = os.path.relpath(fixed, page_dir)
                new_url = quote(new_url)
            if split.query:
                new_url += "?" + split.query
            if split.fragment:
                new_url += "#" + split.fragment

            if new_url != url:
                changes.append((raw, new_url))

        if changes:
            edits[path] = changes

    total = sum(len(v) for v in edits.values())
    print(f"links fixable by case: {total} in {len(edits)} file(s)")
    print(f"links still missing (no case-insensitive match): {missing}")
    print()

    for path, changes in sorted(edits.items())[:40]:
        print("  " + path)
        for old, new in changes[:6]:
            print(f"      {old}")
            print(f"   -> {new}")
    if len(edits) > 40:
        print(f"  ... and {len(edits) - 40} more file(s)")

    if args.dry_run:
        print()
        print("  nothing written (--dry-run)")
        return

    if not edits:
        print("nothing to do")
        return

    stamp = time.strftime("%Y-%m-%d-%H%M%S")
    backup = f"/root/html-linkcase-{stamp}.tar.gz"
    proc = subprocess.run(
        ["tar", "czf", backup, "--null", "-T", "-"],
        input="\0".join(sorted(edits)).encode() + b"\0",
    )
    if proc.returncode != 0:
        sys.exit("error: backup failed, nothing written")
    print(f"\nbackup: {backup}")

    for path, changes in edits.items():
        text = open(path, encoding="utf-8", errors="surrogateescape").read()
        for old, new in changes:
            text = text.replace(f'"{old}"', f'"{new}"')
        open(path, "w", encoding="utf-8", errors="surrogateescape").write(text)

    print(f"rewrote {total} link(s) in {len(edits)} file(s)")
    print(f"restore with:  tar xzf {backup} -C /")


if __name__ == "__main__":
    main()
