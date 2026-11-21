#!/usr/bin/env python3
"""Generates the Strong's theme kind migration and its built-in theme.

Until this migration Strong's had no themes of its own: a dictionary entry
went to the projector in the scripture default theme, which was designed
for a reference over a passage, not a word, its part of speech and a
definition. This adds 'strongs' as a fourth theme kind and seeds Lexicon,
a design for it:

  word             the Strong's number, the original word and its
                   transliteration ("G26 · ἀγάπη (agápē)"), top left
  part of speech   small caps under it
  text             the page of the entry that is up, under a short accent
                   rule, left-aligned, shrinking to fit
  page             "1 / 3" in the bottom corner when the entry runs over
                   more than one page (StrongsService::sections packs it)

Four new text linkages bind those slots (docs/theme-schema.md §4):
strongsWord, strongsPartOfSpeech, strongsText, strongsPage.

Defaults, following V012's rule that an update never changes what the
congregation sees without someone choosing it:
  fresh install  Lexicon is the first built-in Strong's theme, so
                 ThemeService::defaultFor('strongs') falls back to it.
  upgrade        Strong's was showing the scripture default. That theme
                 is copied as a Strong's theme ("<name> (Strong's)") and
                 made the Strong's default, so the screen looks the same,
                 and the copy can now be changed without touching
                 scripture. Lexicon is in the Themes tab to switch to.

The kind is a CHECK constraint on themes.kind (V001), which SQLite can only
change by rebuilding the table. The rebuild keeps every row, id and column
in place, and the AUTOINCREMENT high-water mark, so a deleted theme's id is
never handed out again.

Outputs (both are committed; this script is not run at build time):
  core/src/db/migrations/app/V015__strongs_themes.sql
  docs/examples/strongs-lexicon.theme.json   (readable reference copy)

Run from the repo root (qt/):
  python scripts/gen-strongs-themes.py
"""

import json
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
MIGRATION = REPO / "core/src/db/migrations/app/V015__strongs_themes.sql"
EXAMPLES = REPO / "docs/examples"

FONT = "Funnel Sans"
NAME = "Lexicon"
SLUG = "lexicon"

BG = "#0d1014"
MESH = ["#0d1014", "#1b2a36", "#0f1318", "#16202a"]
ACCENT = "#7cc4e0"
TEXT = "#f3f6f8"
MUTED = "#9aa6b2"


# Geometry is percent of a 1920x1080 canvas (theme-schema.md §5).
def nodes():
    return [
        {
            "id": "bg", "kind": "container",
            "style": {"x": 0, "y": 0, "width": 100, "height": 100, "z": 0,
                      "opacity": 1.0, "backgroundColor": BG},
            "data": {"layerName": "Background",
                     "fill": {"type": "gradient",
                              "gradient": {"style": "mesh", "colors": MESH,
                                           "angle": 0, "animate": False}}},
        },
        {
            # Shrinks rather than wraps: a long lemma with its
            # transliteration still fits on the one line.
            "id": "word", "kind": "text",
            "style": {"x": 8, "y": 9, "width": 84, "height": 10, "z": 3, "opacity": 1,
                      "color": TEXT, "fontFamily": FONT, "fontPixelSize": 64,
                      "fontWeight": 600, "lineHeightMultiplier": 1.15,
                      "textAlign": "left", "verticalAlign": "center"},
            "data": {"layerName": "Word", "linkage": "strongsWord",
                     "autoResize": True, "maxFontSize": 72},
        },
        {
            "id": "pos", "kind": "text",
            "style": {"x": 8, "y": 19.5, "width": 84, "height": 5, "z": 3, "opacity": 1,
                      "color": MUTED, "fontFamily": FONT, "fontPixelSize": 30,
                      "fontWeight": 500, "letterSpacing": 3, "lineHeightMultiplier": 1.2,
                      "textTransform": "uppercase",
                      "textAlign": "left", "verticalAlign": "center"},
            "data": {"layerName": "Part of speech", "linkage": "strongsPartOfSpeech",
                     "autoResize": True, "maxFontSize": 30},
        },
        {
            "id": "rule", "kind": "container",
            "style": {"x": 8, "y": 27.5, "width": 3.75, "height": 0.4, "z": 2,
                      "opacity": 1, "backgroundColor": ACCENT},
            "data": {"layerName": "Accent rule"},
        },
        {
            # Top-aligned so a one-line gloss and a long usage list start on
            # the same line; auto-fit only shrinks the long ones.
            "id": "text", "kind": "text",
            "style": {"x": 8, "y": 31, "width": 82, "height": 58, "z": 2, "opacity": 1,
                      "color": TEXT, "fontFamily": FONT, "fontPixelSize": 54,
                      "fontWeight": 500, "lineHeightMultiplier": 1.3,
                      "textAlign": "left", "verticalAlign": "start"},
            "data": {"layerName": "Definition", "linkage": "strongsText",
                     "autoResize": True, "maxFontSize": 60},
        },
        {
            "id": "page", "kind": "text",
            "style": {"x": 72, "y": 91.5, "width": 20, "height": 4, "z": 3, "opacity": 1,
                      "color": MUTED, "fontFamily": FONT, "fontPixelSize": 26,
                      "fontWeight": 500, "letterSpacing": 2, "lineHeightMultiplier": 1.2,
                      "textAlign": "right", "verticalAlign": "center"},
            "data": {"layerName": "Page", "linkage": "strongsPage",
                     "autoResize": False},
        },
    ]


def tokens():
    return {"version": 3, "canvas": {"width": 1920, "height": 1080},
            "layouts": [{"id": "content", "name": "Content", "default": True,
                         "nodes": nodes()}]}


def sql_literal(s):
    return "'" + s.replace("'", "''") + "'"


REBUILD = """
-- 1. Let themes.kind hold 'strongs'. Same columns, same order (V001 plus
--    V003's tokens_version, which ALTER TABLE appended), same rows and ids.
CREATE TEMP TABLE _themes_seq AS
    SELECT seq FROM sqlite_sequence WHERE name = 'themes';

CREATE TABLE themes_v15 (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    kind           TEXT NOT NULL CHECK (kind IN ('song', 'scripture', 'presentation', 'strongs')),
    name           TEXT NOT NULL,
    tokens_json    TEXT NOT NULL,
    is_builtin     INTEGER NOT NULL DEFAULT 0 CHECK (is_builtin IN (0, 1)),
    created_at     INTEGER NOT NULL,
    updated_at     INTEGER NOT NULL,
    tokens_version INTEGER NOT NULL DEFAULT 1
);
INSERT INTO themes_v15 (id, kind, name, tokens_json, is_builtin, created_at, updated_at, tokens_version)
    SELECT id, kind, name, tokens_json, is_builtin, created_at, updated_at, tokens_version FROM themes;
DROP TABLE themes;
ALTER TABLE themes_v15 RENAME TO themes;
CREATE INDEX idx_themes_kind ON themes(kind);

-- The rename carries the copy's sequence row over; put back the old
-- high-water mark when it was higher (themes deleted from the top).
UPDATE sqlite_sequence
   SET seq = MAX(seq, COALESCE((SELECT seq FROM _themes_seq), 0))
 WHERE name = 'themes';
DROP TABLE _themes_seq;
"""


# Fresh install vs upgrade, as V012 tells them apart: on a fresh install
# every migration runs in one pass, so V001's Classic Dark was created
# moments ago.
UPGRADE_ONLY = """
       AND NOT EXISTS (SELECT 1 FROM themes c
                        WHERE c.kind = 'scripture' AND c.is_builtin = 1 AND c.name = 'Classic Dark'
                          AND c.created_at >= CAST(strftime('%s','now') AS INTEGER) * 1000 - 60000)"""

# The scripture theme Strong's was showing: the stored scripture default
# when it still exists, else the first built-in scripture theme (which is
# what ThemeService::defaultFor falls back to).
EFFECTIVE_SCRIPTURE = """(SELECT id FROM themes
          WHERE kind = 'scripture'
            AND id = (SELECT CAST(value AS INTEGER) FROM kv WHERE key = 'default_scripture_theme_id'))"""
FIRST_BUILTIN_SCRIPTURE = """(SELECT id FROM themes
          WHERE kind = 'scripture' AND is_builtin = 1 ORDER BY id LIMIT 1)"""


def main():
    EXAMPLES.mkdir(parents=True, exist_ok=True)
    tok = tokens()
    compact = json.dumps(tok, separators=(",", ":"), ensure_ascii=False)

    seed = f"""
-- 2. Lexicon, the built-in Strong's theme. First built-in of its kind, so
--    a fresh install's Strong's default falls back to it.
INSERT INTO themes (kind, name, tokens_json, is_builtin, tokens_version, created_at, updated_at)
SELECT 'strongs', {sql_literal(NAME)}, {sql_literal(compact)}, 1, 3,
       CAST(strftime('%s','now') AS INTEGER) * 1000,
       CAST(strftime('%s','now') AS INTEGER) * 1000
 WHERE NOT EXISTS (SELECT 1 FROM themes
                    WHERE kind = 'strongs' AND is_builtin = 1 AND name = {sql_literal(NAME)});
"""

    upgrade = f"""
-- 3. Upgrade only: keep Strong's looking as it did. Copy the scripture
--    theme it was showing as a Strong's theme and make that the Strong's
--    default. Its scriptureRef / scriptureText nodes resolve for a
--    Strong's entry exactly as before (the word, then the section text).
--    A default someone already set is never replaced.
CREATE TEMP TABLE _strongs_src AS
    SELECT COALESCE({EFFECTIVE_SCRIPTURE},
                    {FIRST_BUILTIN_SCRIPTURE}) AS id;

INSERT INTO themes (kind, name, tokens_json, is_builtin, tokens_version, created_at, updated_at)
SELECT 'strongs', s.name || ' (Strong''s)', s.tokens_json, 0, s.tokens_version,
       CAST(strftime('%s','now') AS INTEGER) * 1000,
       CAST(strftime('%s','now') AS INTEGER) * 1000
  FROM themes s
 WHERE s.id = (SELECT id FROM _strongs_src)
   AND NOT EXISTS (SELECT 1 FROM kv WHERE key = 'default_strongs_theme_id'){UPGRADE_ONLY};

INSERT OR IGNORE INTO kv (key, value)
SELECT 'default_strongs_theme_id', CAST(last_insert_rowid() AS TEXT)
 WHERE changes() = 1
   AND EXISTS (SELECT 1 FROM themes WHERE id = last_insert_rowid() AND kind = 'strongs' AND is_builtin = 0);

DROP TABLE _strongs_src;
"""

    readable = {"name": NAME, "kind": "strongs", "tokens": tok}
    out = EXAMPLES / f"strongs-{SLUG}.theme.json"
    out.write_text(json.dumps(readable, indent=2, ensure_ascii=False) + "\n",
                   encoding="utf-8", newline="\n")

    header = """\
-- App schema v15 - Strong's gets its own theme kind.
--
-- GENERATED by scripts/gen-strongs-themes.py. Edit that script and re-run
-- it; hand edits here are lost. The same generator writes a readable copy
-- of the theme to docs/examples/strongs-lexicon.theme.json.
--
-- Adds 'strongs' to themes.kind and seeds Lexicon, the built-in Strong's
-- theme. On an upgrade, Strong's keeps the look it had: the scripture
-- theme it was showing is copied as a Strong's theme and made the Strong's
-- default. On a fresh install Lexicon is the default. See the script's
-- docstring for the why.
--
-- tokens_version is stamped 3 explicitly (see V006 and V011 for why).
"""

    MIGRATION.write_text(header + REBUILD + seed + upgrade, encoding="utf-8", newline="\n")
    print(f"wrote {MIGRATION.relative_to(REPO)} ({MIGRATION.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
