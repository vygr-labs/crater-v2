#!/usr/bin/env python3
"""Generates the built-in scripture themes and the migration that seeds them.

Classic Dark, the scripture default since V001, is white text centred on
black with no reference: the room never sees which verse is up. These
themes share one design (a heavy reference eyebrow with the passage
left-aligned beneath it, Funnel Sans throughout) in two palettes, so
switching between them never moves the text.

Funnel Sans is the one family bundled with Crater (main.cpp registers it),
so the design renders the same on the Windows and Linux builds.

Outputs (both are committed; this script is not run at build time):
  core/src/db/migrations/app/V012__scripture_themes.sql
  docs/examples/scripture-<slug>.theme.json   (readable reference copies)

Run from the repo root (qt/):
  python scripts/gen-scripture-themes.py
"""

import json
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
MIGRATION = REPO / "core/src/db/migrations/app/V012__scripture_themes.sql"
EXAMPLES = REPO / "docs/examples"

FONT = "Funnel Sans"

# The first entry becomes the scripture default on fresh installs.
THEMES = [
    {
        "name": "Plum & Rose",
        "slug": "plum-rose",
        "bg": "#110910",
        # Static mesh: two soft glows over a near-black base. Static because a
        # verse can sit on screen for minutes and a moving background under
        # reading text pulls the eye.
        "mesh": ["#110910", "#571f44", "#1a0c18", "#391528"],
        "accent": "#f29cac",
        "text": "#fcf3f5",
    },
    {
        "name": "Graphite & Cyan",
        "slug": "graphite-cyan",
        "bg": "#0b0c0e",
        "mesh": ["#0b0c0e", "#17343c", "#0e1013", "#191c24"],
        "accent": "#3ac8d4",
        "text": "#f4f6f8",
    },
]


# Geometry is percent of a 1920x1080 canvas (theme-schema.md §5).
def nodes(t):
    return [
        {
            "id": "bg", "kind": "container",
            "style": {"x": 0, "y": 0, "width": 100, "height": 100, "z": 0,
                      "opacity": 1.0, "backgroundColor": t["bg"]},
            "data": {"layerName": "Background",
                     "fill": {"type": "gradient",
                              "gradient": {"style": "mesh", "colors": t["mesh"],
                                           "angle": 0, "animate": False}}},
        },
        {
            "id": "reference", "kind": "text",
            "style": {"x": 9, "y": 11, "width": 82, "height": 7, "z": 3, "opacity": 1,
                      "color": t["accent"], "fontFamily": FONT, "fontPixelSize": 43,
                      # 800 is the heaviest Funnel Sans goes.
                      "fontWeight": 800, "letterSpacing": 5, "lineHeightMultiplier": 1.2,
                      "textTransform": "uppercase",
                      "textAlign": "left", "verticalAlign": "center"},
            "data": {"layerName": "Reference", "linkage": "scriptureRef", "autoResize": False},
        },
        {
            # Top-aligned so a one-verse slide and a whole passage start on
            # the same line under the reference; auto-fit grows a short verse
            # into the empty space below and shrinks a long passage, but never
            # pushes the first line down.
            "id": "verse", "kind": "text",
            "style": {"x": 9, "y": 21, "width": 80, "height": 71, "z": 2, "opacity": 1,
                      "color": t["text"], "fontFamily": FONT, "fontPixelSize": 72,
                      "fontWeight": 600, "lineHeightMultiplier": 1.26,
                      "textAlign": "left", "verticalAlign": "start"},
            "data": {"layerName": "Verse", "linkage": "scriptureText",
                     "autoResize": True, "maxFontSize": 120,
                     "verseNumberColor": t["accent"]},
        },
    ]


def tokens(t):
    return {"version": 3, "canvas": {"width": 1920, "height": 1080},
            "layouts": [{"id": "content", "name": "Content", "default": True,
                         "nodes": nodes(t)}]}


def sql_literal(s):
    return "'" + s.replace("'", "''") + "'"


def main():
    EXAMPLES.mkdir(parents=True, exist_ok=True)
    inserts = []
    for t in THEMES:
        tok = tokens(t)
        compact = json.dumps(tok, separators=(",", ":"), ensure_ascii=False)
        inserts.append(f"""
INSERT INTO themes (kind, name, tokens_json, is_builtin, tokens_version, created_at, updated_at)
SELECT 'scripture', {sql_literal(t["name"])}, {sql_literal(compact)}, 1, 3,
       CAST(strftime('%s','now') AS INTEGER) * 1000,
       CAST(strftime('%s','now') AS INTEGER) * 1000
 WHERE NOT EXISTS (SELECT 1 FROM themes
                    WHERE kind = 'scripture' AND is_builtin = 1 AND name = {sql_literal(t["name"])});""")

        readable = {"name": t["name"], "kind": "scripture", "tokens": tok}
        out = EXAMPLES / f"scripture-{t['slug']}.theme.json"
        out.write_text(json.dumps(readable, indent=2, ensure_ascii=False) + "\n",
                       encoding="utf-8", newline="\n")

    header = """\
-- App schema v12 - built-in scripture themes.
--
-- GENERATED by scripts/gen-scripture-themes.py. Edit that script and
-- re-run it; hand edits here are lost. The same generator writes readable
-- copies of each theme to docs/examples/scripture-*.theme.json.
--
-- Seeds two scripture themes that show the reference above the passage,
-- and makes the first one the scripture default on FRESH installs only.
--
-- Why fresh installs only: ThemeService::defaultFor falls back to the
-- first built-in of a kind when no default is stored, so an operator who
-- never picked one is still implicitly on Classic Dark. Switching them on
-- update would change what the congregation sees without anyone choosing
-- it. They get the new themes in the Themes tab instead.
--
-- Telling the two apart in SQL: on a fresh install every migration runs in
-- one pass, so V001's built-ins were created moments ago. On an upgrade
-- they are at least as old as the previous launch. A minute of slack
-- covers a slow first run.
--
-- tokens_version is stamped 3 explicitly (see V006 and V011 for why).
-- NOT EXISTS keeps the inserts safe on a DB that somehow already has
-- them, and INSERT OR IGNORE never overwrites a default someone chose.
"""

    first = THEMES[0]["name"]
    default = f"""
INSERT OR IGNORE INTO kv (key, value)
SELECT 'default_scripture_theme_id', CAST(t.id AS TEXT)
  FROM themes t
 WHERE t.kind = 'scripture' AND t.is_builtin = 1 AND t.name = {sql_literal(first)}
   AND EXISTS (SELECT 1 FROM themes c
                WHERE c.kind = 'scripture' AND c.is_builtin = 1 AND c.name = 'Classic Dark'
                  AND c.created_at >= CAST(strftime('%s','now') AS INTEGER) * 1000 - 60000);
"""

    MIGRATION.write_text(header + "".join(inserts) + "\n" + default,
                         encoding="utf-8", newline="\n")
    print(f"wrote {MIGRATION.relative_to(REPO)} ({MIGRATION.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
