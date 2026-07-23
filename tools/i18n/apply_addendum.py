#!/usr/bin/env python3
"""Fold a nested translation addendum into each per-language _map_<code>.json.

When new source strings are added (e.g. after widening the lupdate scan to
app/src), it's wasteful to re-translate the whole catalog. Instead the new
strings are translated once into `_map_addendum.json`, shaped as:

    { "<english source>": { "es": "…", "fr": "…", …, "ar": "…" }, … }

This script distributes those into the existing `_map_<code>.json` files (one
key per source per language), so a subsequent `build_catalogs.py` run fills the
new messages too. Existing keys are overwritten by the addendum, so it doubles
as a correction channel.

Usage:
    python apply_addendum.py            # uses app/i18n/_map_addendum.json
    python apply_addendum.py <addendum.json>
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
I18N = os.path.join(REPO, "app", "i18n")


def main() -> int:
    addendum_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(I18N, "_map_addendum.json")
    with open(addendum_path, encoding="utf-8") as fh:
        addendum = json.load(fh)

    with open(os.path.join(HERE, "languages.json"), encoding="utf-8") as fh:
        codes = [l["code"] for l in json.load(fh)["languages"]]

    print(f"Applying {len(addendum)} source string(s) from {os.path.basename(addendum_path)}\n")
    for code in codes:
        map_path = os.path.join(I18N, f"_map_{code}.json")
        mapping = {}
        if os.path.exists(map_path):
            with open(map_path, encoding="utf-8") as fh:
                mapping = json.load(fh)
        added = 0
        for source, per_lang in addendum.items():
            value = per_lang.get(code)
            if value:
                mapping[source] = value
                added += 1
        with open(map_path, "w", encoding="utf-8") as fh:
            json.dump(mapping, fh, ensure_ascii=False, indent=1)
        miss = len(addendum) - added
        note = "" if miss == 0 else f"  ({miss} missing for this language)"
        print(f"  {code:<6} +{added} -> {len(mapping)} keys{note}")

    print("\nDone. Next: python tools/i18n/build_catalogs.py && python tools/i18n/build_qm.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
