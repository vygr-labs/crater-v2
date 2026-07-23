#!/usr/bin/env python3
"""Extract the unique translatable source strings from a Qt Linguist .ts file.

Crater's UI is fully marked with qsTr(); `lupdate` harvests those strings into
a template .ts (crater_template.ts). This script flattens that template into a
plain JSON array of the UNIQUE English source strings — the payload we hand to
the per-language translation step. Duplicates across QML contexts collapse to a
single entry (the same button label gets one translation everywhere).

Usage:
    python extract_sources.py <template.ts> <out_sources.json>
"""
import json
import sys
import xml.etree.ElementTree as ET


def extract(template_path: str) -> list[str]:
    tree = ET.parse(template_path)
    root = tree.getroot()
    seen: dict[str, None] = {}  # dict preserves insertion order, dedups
    for message in root.iter("message"):
        src = message.find("source")
        if src is None or src.text is None:
            continue
        text = src.text
        if text not in seen:
            seen[text] = None
    return list(seen.keys())


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    template_path, out_path = sys.argv[1], sys.argv[2]
    sources = extract(template_path)
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(sources, fh, ensure_ascii=False, indent=1)
    print(f"Extracted {len(sources)} unique source strings -> {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
