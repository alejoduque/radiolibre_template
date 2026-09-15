#!/usr/bin/env python3
"""Tests for fix-link-case.py's case-insensitive path resolution.

    python3 tools/test/test_link_case.py

The filesystem is SIMULATED rather than created on disk, deliberately. macOS
is case-insensitive by default, so a fixture built there reports that
"Re.html" exists when the file is "re.html" — the exact bug this tool fixes
cannot be reproduced, and the tests would pass without proving anything.
"""

import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "..", "fix-link-case.py")

spec = importlib.util.spec_from_file_location("flc", TOOL)
flc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(flc)

FILES = {
    "/r/lab/re.html",
    "/r/lab/k2o/F0am_WORM/EMF_spheres.html",
    "/r/amb/Page.html",
    "/r/amb/page.html",
}
DIRS = {"/"}
for _f in FILES:
    _parts = _f.strip("/").split("/")
    for _i in range(1, len(_parts)):
        DIRS.add("/" + "/".join(_parts[:_i]))


def fake_exists(p):
    p = p.rstrip("/") or "/"
    return p in FILES or p in DIRS


def fake_listdir(d):
    d = d.rstrip("/") or "/"
    pre = d if d.endswith("/") else d + "/"
    out = set()
    for p in FILES | DIRS:
        if p.startswith(pre) and p != d:
            out.add(p[len(pre):].split("/")[0])
    return sorted(out)


flc.os.path.exists = fake_exists
flc.os.listdir = fake_listdir

CASES = [
    ("/r/lab/Re.html", "/r/lab/re.html", "wrong case on the file"),
    ("/r/lab/k2o/f0am_WORM/EMF_spheres.html",
     "/r/lab/k2o/F0am_WORM/EMF_spheres.html", "wrong case on a directory"),
    ("/r/lab/re.html", "/r/lab/re.html", "already correct, unchanged"),
    ("/r/amb/PAGE.html", None, "ambiguous: both Page.html and page.html exist"),
    ("/r/lab/GoneForever.html", None, "genuinely missing"),
]


def main():
    failed = 0
    for inp, want, label in CASES:
        got = flc.resolve_ci(inp)
        ok = got == want
        print(f"  {'PASS' if ok else 'FAIL'}  {label}")
        if not ok:
            print(f"        input:    {inp}")
            print(f"        expected: {want}")
            print(f"        actual:   {got}")
            failed += 1
    print()
    print(f"  {len(CASES) - failed}/{len(CASES)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
