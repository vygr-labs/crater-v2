#!/usr/bin/env python3
"""Fill a Qt Linguist .ts template with translations from a flat JSON map.

The translation step produces one `_map_<code>.json` per language — a plain
{ english_source: translated_text } object. This script stamps those strings
back into a copy of the lupdate template, producing a ready-to-compile
crater_<code>.ts. Any source string missing from the map (or mapped to an
empty value) is left `type="unfinished"`, so Qt falls back to the English
source at runtime — partial catalogs degrade gracefully, never to blanks.

Usage:
    python merge_translations.py <template.ts> <map.json> <out.ts> <lang_code>

<lang_code> is the Qt locale that lands in the <TS language="..."> attribute,
e.g. "es", "pt_BR", "zh_CN".
"""
import json
import sys
import xml.etree.ElementTree as ET


def merge_map(template_path: str, mapping: dict, out_path: str, lang: str) -> tuple[int, int]:
    """Stamp `mapping` (english_source -> translation) into the template."""
    tree = ET.parse(template_path)
    root = tree.getroot()
    root.set("language", lang)
    root.set("sourcelanguage", "en")

    filled = 0
    total = 0
    for message in root.iter("message"):
        # Leave plural/numerus messages for a translator — a flat map can't
        # express per-form text safely.
        if message.get("numerus") == "yes":
            continue
        src = message.find("source")
        if src is None or src.text is None:
            continue
        total += 1
        value = mapping.get(src.text)
        if not value:
            continue
        trans = message.find("translation")
        if trans is None:
            trans = ET.SubElement(message, "translation")
        trans.text = value
        if "type" in trans.attrib:  # drop type="unfinished"
            del trans.attrib["type"]
        filled += 1

    body = ET.tostring(root, encoding="unicode")
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write('<?xml version="1.0" encoding="utf-8"?>\n<!DOCTYPE TS>\n')
        fh.write(body)
        if not body.endswith("\n"):
            fh.write("\n")
    return filled, total


def merge(template_path: str, map_path: str, out_path: str, lang: str) -> tuple[int, int]:
    """File-based wrapper around merge_map(): loads the JSON map, then merges."""
    with open(map_path, encoding="utf-8") as fh:
        mapping = json.load(fh)
    return merge_map(template_path, mapping, out_path, lang)


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__)
        return 2
    template_path, map_path, out_path, lang = sys.argv[1:5]
    filled, total = merge(template_path, map_path, out_path, lang)
    print(f"{lang}: filled {filled}/{total} messages -> {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
