#!/usr/bin/env python3
"""Generates the built-in song themes and the migration that seeds them.

Classic Dark, the song default since V001, sets the lyric small in the
middle of a flat black screen in a font that only exists on Windows. These
themes give the lyric the room it needs: large, centred, Funnel Sans, over
the same static mesh backgrounds as the scripture themes (V012), so a
service that moves from a reading to a song stays in one look. Each song
theme carries the name of its scripture partner.

The credits box binds `songCredits`, which is empty unless Show author or
Show CCLI number is on, so it costs nothing on a church that never shows
credits and sits in a considered place when it does.

Funnel Sans is the one family bundled with Crater (main.cpp registers it),
so the design renders the same on the Windows, macOS and Linux builds.

Outputs (both are committed; this script is not run at build time):
  core/src/db/migrations/app/V013__song_themes.sql
  docs/examples/song-<slug>.theme.json   (readable reference copies)

Run from the repo root (qt/):
  python scripts/gen-song-themes.py
"""

import json
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
MIGRATION = REPO / "core/src/db/migrations/app/V013__song_themes.sql"
EXAMPLES = REPO / "docs/examples"

FONT = "Funnel Sans"

# Same palettes as gen-scripture-themes.py. The first entry becomes the
# song default on fresh installs.
THEMES = [
    {
        "name": "Plum & Rose",
        "slug": "plum-rose",
        "bg": "#110910",
        "mesh": ["#110910", "#571f44", "#1a0c18", "#391528"],
        "accent": "#f29cac",
        "text": "#fcf3f5",
        "muted": "#c9a3ad",
        "shadow": "#07030a",
    },
    {
        "name": "Graphite & Cyan",
        "slug": "graphite-cyan",
        "bg": "#0b0c0e",
        "mesh": ["#0b0c0e", "#17343c", "#0e1013", "#191c24"],
        "accent": "#3ac8d4",
        "text": "#f4f6f8",
        "muted": "#9fb0b6",
        "shadow": "#030405",
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
            # 72 px keeps a typical hymn line ("Amazing grace! How sweet the
            # sound") on one line, so a stanza never strands a single word.
            # Centred both ways: a congregation reads a lyric together from
            # every seat, and a two-line chorus and a six-line verse should
            # both sit in the middle of the wall. Auto-fit only ever shrinks
            # a long stanza. The soft shadow keeps the words clean when the
            # output is keyed over video in a stream.
            # 92% wide keeps a 47-character hymn line ("Strength for today and
            # bright hope for tomorrow") on one line at the full 80px.
            "id": "lyric", "kind": "text",
            "style": {"x": 4, "y": 12, "width": 92, "height": 70, "z": 2, "opacity": 1,
                      "color": t["text"], "fontFamily": FONT, "fontPixelSize": 72,
                      "fontWeight": 600, "lineHeightMultiplier": 1.22,
                      "letterSpacing": -0.5,
                      "textAlign": "center", "verticalAlign": "center",
                      "textShadowColor": t["shadow"], "textShadowOffsetX": 0,
                      "textShadowOffsetY": 4, "textShadowBlur": 18},
            "data": {"layerName": "Lyric", "linkage": "lyric",
                     "autoResize": True, "maxFontSize": 80},
        },
        {
            "id": "credits", "kind": "text",
            "style": {"x": 10, "y": 88.5, "width": 80, "height": 6, "z": 3, "opacity": 1,
                      "color": t["muted"], "fontFamily": FONT, "fontPixelSize": 30,
                      "fontWeight": 500, "letterSpacing": 1, "lineHeightMultiplier": 1.2,
                      "textAlign": "center", "verticalAlign": "center"},
            "data": {"layerName": "Credits", "linkage": "songCredits", "autoResize": True,
                     "maxFontSize": 30},
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
SELECT 'song', {sql_literal(t["name"])}, {sql_literal(compact)}, 1, 3,
       CAST(strftime('%s','now') AS INTEGER) * 1000,
       CAST(strftime('%s','now') AS INTEGER) * 1000
 WHERE NOT EXISTS (SELECT 1 FROM themes
                    WHERE kind = 'song' AND is_builtin = 1 AND name = {sql_literal(t["name"])});""")

        readable = {"name": t["name"], "kind": "song", "tokens": tok}
        out = EXAMPLES / f"song-{t['slug']}.theme.json"
        out.write_text(json.dumps(readable, indent=2, ensure_ascii=False) + "\n",
                       encoding="utf-8", newline="\n")

    header = """\
-- App schema v13 - built-in song themes.
--
-- GENERATED by scripts/gen-song-themes.py. Edit that script and re-run
-- it; hand edits here are lost. The same generator writes readable copies
-- of each theme to docs/examples/song-*.theme.json.
--
-- Seeds two song themes that pair with the V012 scripture themes, and
-- makes the first one the song default on FRESH installs only, for the
-- same reason V012 does: an operator who never picked a song default is
-- implicitly on Classic Dark, and switching it on update would change
-- what the congregation sees without anyone choosing it. They get the new
-- themes in the Themes tab instead.
--
-- Fresh versus upgrade is told apart the way V012 does it: on a fresh
-- install V001's built-ins were created moments ago.
--
-- tokens_version is stamped 3 explicitly (see V006 and V011 for why).
-- NOT EXISTS keeps the inserts safe on a DB that somehow already has
-- them, and INSERT OR IGNORE never overwrites a default someone chose.
"""

    first = THEMES[0]["name"]
    default = f"""
INSERT OR IGNORE INTO kv (key, value)
SELECT 'default_song_theme_id', CAST(t.id AS TEXT)
  FROM themes t
 WHERE t.kind = 'song' AND t.is_builtin = 1 AND t.name = {sql_literal(first)}
   AND EXISTS (SELECT 1 FROM themes c
                WHERE c.kind = 'song' AND c.is_builtin = 1 AND c.name = 'Classic Dark'
                  AND c.created_at >= CAST(strftime('%s','now') AS INTEGER) * 1000 - 60000);
"""

    MIGRATION.write_text(header + "".join(inserts) + "\n" + default,
                         encoding="utf-8", newline="\n")
    print(f"wrote {MIGRATION.relative_to(REPO)} ({MIGRATION.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
