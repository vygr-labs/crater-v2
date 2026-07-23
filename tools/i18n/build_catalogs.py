#!/usr/bin/env python3
"""Assemble app/i18n/crater_<code>.ts for every language in languages.json.

Pipeline recap:
  1. lupdate harvests qsTr() strings          -> app/i18n/crater_template.ts
  2. extract_sources.py flattens the template -> app/i18n/_sources.json
  3. the translation step produces one map    -> app/i18n/_map_<code>.json
  4. THIS script merges each map into the template -> app/i18n/crater_<code>.ts
  5. build_qm.py compiles the .ts via lrelease     -> app/i18n/crater_<code>.qm

A language with a missing or partial _map_<code>.json still yields a valid .ts:
unmapped strings stay type="unfinished", and Qt falls back to the English source
at runtime — so a translation that never arrived degrades to English, never to
blanks. Every language in languages.json always gets a .ts (and thus a .qm),
which keeps app/CMakeLists.txt's bundled-resource list satisfied.
"""
import json
import os
import sys

from merge_translations import merge_map

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
I18N = os.path.join(REPO, "app", "i18n")


def main() -> int:
    with open(os.path.join(HERE, "languages.json"), encoding="utf-8") as fh:
        langs = json.load(fh)["languages"]

    template = os.path.join(I18N, "crater_template.ts")
    if not os.path.exists(template):
        print(f"error: {template} not found — run lupdate first.", file=sys.stderr)
        return 1

    print(f"Building {len(langs)} catalogs from {template}\n")
    grand_total = 0
    for lang in langs:
        code = lang["code"]
        map_path = os.path.join(I18N, f"_map_{code}.json")
        out_path = os.path.join(I18N, f"crater_{code}.ts")
        mapping = {}
        if os.path.exists(map_path):
            with open(map_path, encoding="utf-8") as fh:
                mapping = json.load(fh)
        filled, total = merge_map(template, mapping, out_path, code)
        grand_total = total
        pct = (100 * filled // total) if total else 0
        flag = "" if os.path.exists(map_path) else "  (no map — English fallback)"
        print(f"  {code:<6} {filled:>3}/{total} ({pct:>3}%){flag}")

    print(f"\nDone. {len(langs)} .ts written to {I18N} ({grand_total} messages each).")
    print("Next: python tools/i18n/build_qm.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
