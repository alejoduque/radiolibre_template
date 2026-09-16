#!/usr/bin/env python3
"""
Put back the modification times that the in-place rewrites destroyed.

    restore-mtimes.py --dry-run     report what would change, touch nothing
    restore-mtimes.py               apply the oldest known mtime per file

rewrite-old-domains.sh and fix-link-case.py edit files in place, and any
in-place edit resets mtime to now. That dated twenty-year-old pages to this
week, and the index shows that date — so the archive began asserting its own
contents were made yesterday.

Those tools take a tar backup before writing, and tar records mtimes, so the
real dates survive in /root/*.tar.gz.

This reads the timestamps out of the tar INDEX and never extracts anything.
The shell version unpacked every archive to a temp directory first, which on
eight overlapping backups of the same content meant writing the whole corpus
to disk eight times over before it could begin.

Only timestamps are touched. Content is never restored: the rewrites
themselves are wanted, it is only their side effect on mtime that is not.
Timestamps only ever move backwards, so re-running changes nothing.
"""

import argparse
import glob
import os
import sys
import tarfile
import time


def oldest_mtimes(paths):
    """Map absolute path -> oldest mtime seen across every backup.

    Oldest rather than newest because each successive backup captured the
    damage done by the run before it.
    """
    best = {}
    for archive in paths:
        try:
            with tarfile.open(archive) as tf:
                for m in tf:
                    if not m.isfile():
                        continue
                    # tar strips the leading slash; put it back.
                    target = "/" + m.name.lstrip("/")
                    if target not in best or m.mtime < best[target]:
                        best[target] = m.mtime
        except (tarfile.TarError, OSError) as exc:
            print(f"  skip {archive}: {exc}", file=sys.stderr)
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--glob", default="/root/*.tar.gz")
    ap.add_argument("--limit", type=int, default=40,
                    help="how many changes to print (default 40)")
    args = ap.parse_args()

    archives = sorted(glob.glob(args.glob))
    if not archives:
        sys.exit(f"error: no backups matching {args.glob}")

    print(f"backups: {len(archives)}")
    for a in archives:
        print(f"  {a}  ({os.path.getsize(a) / 1e6:.1f} MB)")
    print()

    best = oldest_mtimes(archives)
    print(f"files recorded in backups: {len(best)}")

    restored = already = missing = 0
    shown = 0
    for target, mtime in sorted(best.items()):
        try:
            current = os.stat(target).st_mtime
        except OSError:
            missing += 1
            continue

        if mtime >= current:
            already += 1
            continue

        restored += 1
        if shown < args.limit:
            shown += 1
            print(f"  {target}")
            print(f"     {time.strftime('%Y-%m-%d', time.localtime(current))}"
                  f" -> {time.strftime('%Y-%m-%d', time.localtime(mtime))}")
        if not args.dry_run:
            # Leave atime alone-ish; only mtime is meaningful here.
            os.utime(target, (mtime, mtime))

    if restored > shown:
        print(f"  ... and {restored - shown} more")

    print()
    print(f"  restored:          {restored}")
    print(f"  already older:     {already}")
    print(f"  no longer present: {missing}")
    if args.dry_run:
        print("  nothing touched (--dry-run)")


if __name__ == "__main__":
    main()
