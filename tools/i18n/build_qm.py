#!/usr/bin/env python3
"""Compile every app/i18n/crater_<code>.ts into a runtime crater_<code>.qm.

Thin wrapper over Qt's `lrelease`. The .qm are the binary catalogs app/CMakeLists
bundles at qrc:/i18n/ and TranslationService loads. Run this after editing any
.ts (or after build_catalogs.py regenerates them).

lrelease is located, in order, from:
  1. --lrelease <path>
  2. $LRELEASE
  3. $QTDIR/bin/lrelease(.exe)
  4. lrelease / lrelease-pro on PATH
  5. a few well-known install roots (Windows Qt layout)
"""
import argparse
import glob
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
I18N = os.path.join(REPO, "app", "i18n")

WELL_KNOWN = [
    r"C:\Qt\6.11.1\msvc2022_64\bin\lrelease.exe",
]


def find_lrelease(explicit: str | None) -> str | None:
    for cand in (
        explicit,
        os.environ.get("LRELEASE"),
        os.path.join(os.environ.get("QTDIR", ""), "bin", "lrelease.exe") if os.environ.get("QTDIR") else None,
        os.path.join(os.environ.get("QTDIR", ""), "bin", "lrelease") if os.environ.get("QTDIR") else None,
    ):
        if cand and os.path.exists(cand):
            return cand
    for name in ("lrelease", "lrelease-pro"):
        found = shutil.which(name)
        if found:
            return found
    for cand in WELL_KNOWN:
        if os.path.exists(cand):
            return cand
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--lrelease", help="path to Qt lrelease executable")
    args = ap.parse_args()

    lrelease = find_lrelease(args.lrelease)
    if not lrelease:
        print("error: could not locate lrelease. Pass --lrelease <path> or set QTDIR.",
              file=sys.stderr)
        return 1

    ts_files = sorted(
        f for f in glob.glob(os.path.join(I18N, "crater_*.ts"))
        if not f.endswith("crater_template.ts")
    )
    if not ts_files:
        print(f"error: no crater_<code>.ts in {I18N} — run build_catalogs.py first.",
              file=sys.stderr)
        return 1

    print(f"Using {lrelease}\nCompiling {len(ts_files)} catalogs:\n")
    failures = 0
    for ts in ts_files:
        qm = ts[:-3] + ".qm"
        result = subprocess.run([lrelease, ts, "-qm", qm],
                                capture_output=True, text=True)
        tail = (result.stdout or result.stderr).strip().splitlines()
        note = tail[-1] if tail else ""
        status = "ok " if result.returncode == 0 else "ERR"
        print(f"  [{status}] {os.path.basename(qm):<22} {note}")
        if result.returncode != 0:
            failures += 1

    print(f"\nDone. {len(ts_files) - failures}/{len(ts_files)} compiled.")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
