#!/usr/bin/env python3
"""Generates the built-in lower thirds with motion and the migration that seeds them.

Slate is a lower third for streams: a dark card in the bottom left that hugs
its text, an amber bar down its left edge, and the reference (or the song
title) over the passage. Nothing else is drawn, so over NDI the rest of the
frame stays transparent for the switcher to key.

It is also the reference design for data.motion (docs/theme-schema.md §10):

  card       rises 36 px into place, 520 ms, smooth
  edge bar   grows up from the bottom, 420 ms, after 160 ms
  reference  slides in 24 px from the left, 420 ms, after 200 ms
  text       fades in, 380 ms, after 260 ms

On the way out the text goes first and the card sinks 18 px after it, so
nothing is left floating. A new verse or lyric only swaps the text
(160 ms out, 260 ms in) and the card eases to its new height.

One design, two kinds (scripture and song), so cutting from a verse to a
lyric keeps the same graphics. The song card also carries the credits line,
which keeps the projector's own credits line from drawing across the card.
It sits right-aligned on the title row rather than under the lyric: empty
text still measures a line, so as a card member an empty credits line
(the default) would leave a gap under every lyric.

Funnel Sans is the one family bundled with Crater (main.cpp registers it),
so it renders the same on the Windows and Linux builds.

These are added to the Themes tab only. No default changes, on fresh
installs or upgrades: a lower third with a transparent background is the
wrong first thing to show on a projector.

Outputs (both are committed; this script is not run at build time):
  core/src/db/migrations/app/V014__motion_themes.sql
  docs/examples/<kind>-slate-lower-third.theme.json   (readable reference copies)

Run from the repo root (qt/):
  python scripts/gen-motion-themes.py
"""

import json
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
MIGRATION = REPO / "core/src/db/migrations/app/V014__motion_themes.sql"
EXAMPLES = REPO / "docs/examples"

FONT = "Funnel Sans"
NAME = "Slate Lower Third"
SLUG = "slate-lower-third"

CARD = "#eb12161c"      # 92% slate
ACCENT = "#f2b84b"      # amber
TEXT = "#f5f7fa"
MUTED = "#a9b1bc"

# Card geometry, percent of a 1920x1080 canvas (theme-schema.md §5). The
# card hugs its members and holds its bottom edge at 94%, so a long passage
# grows it upward instead of pushing it off the frame.
CARD_X, CARD_Y, CARD_W, CARD_H = 4.5, 50, 62, 44
PAD_TOP, PAD_BOTTOM, PAD_X, GAP = 2.4, 2.8, 2.6, 0.8

TEXT_IN = {"type": "fade", "duration": 380, "delay": 260, "easing": "out"}
TEXT_OUT = {"type": "fade", "duration": 180, "easing": "in"}


def nodes(kind):
    body_linkage = "scriptureText" if kind == "scripture" else "lyric"
    members = ["reference", "body"]

    out = [
        {
            "id": "card", "kind": "container",
            "style": {"x": CARD_X, "y": CARD_Y, "width": CARD_W, "height": CARD_H, "z": 1,
                      "opacity": 1, "backgroundColor": CARD,
                      "borderTopLeftRadius": 4, "borderTopRightRadius": 4,
                      "borderBottomLeftRadius": 4, "borderBottomRightRadius": 4},
            "data": {"layerName": "Card",
                     "group": {"members": members, "gap": GAP, "padTop": PAD_TOP,
                               "padBottom": PAD_BOTTOM, "padX": PAD_X, "anchor": "bottom"},
                     "motion": {
                         "in":  {"type": "slide", "edge": "bottom", "distance": 36,
                                 "duration": 520, "easing": "smooth"},
                         "out": {"type": "slide", "edge": "bottom", "distance": 18,
                                 "duration": 320, "delay": 90, "easing": "in"}}},
        },
        {
            # Hugs the card, so it is always exactly as tall as the card.
            "id": "edge", "kind": "container",
            "style": {"x": CARD_X, "y": CARD_Y, "width": 0.32, "height": CARD_H, "z": 2,
                      "opacity": 1, "backgroundColor": ACCENT},
            "data": {"layerName": "Edge bar",
                     "autoHeight": {"source": "card", "padTop": 0, "padBottom": 0},
                     "motion": {
                         "in":  {"type": "grow", "edge": "bottom", "duration": 420,
                                 "delay": 160, "easing": "smooth"},
                         "out": {"type": "fade", "duration": 200, "easing": "in"}}},
        },
        {
            "id": "reference", "kind": "text",
            "style": {"x": CARD_X + PAD_X, "y": 60, "width": CARD_W - 2 * PAD_X, "height": 4.4,
                      "z": 3, "opacity": 1, "color": ACCENT, "fontFamily": FONT,
                      "fontPixelSize": 26, "fontWeight": 600, "letterSpacing": 2,
                      "lineHeightMultiplier": 1.15, "textTransform": "uppercase",
                      "textAlign": "left", "verticalAlign": "start"},
            "data": {"layerName": "Reference" if kind == "scripture" else "Song title",
                     "linkage": "scriptureRef", "autoResize": True, "maxFontSize": 26,
                     "motion": {
                         "in":  {"type": "slide", "edge": "left", "distance": 24,
                                 "duration": 420, "delay": 200, "easing": "smooth"},
                         "out": TEXT_OUT}},
        },
        {
            "id": "body", "kind": "text",
            "style": {"x": CARD_X + PAD_X, "y": 66, "width": CARD_W - 2 * PAD_X, "height": 24,
                      "z": 3, "opacity": 1, "color": TEXT, "fontFamily": FONT,
                      "fontPixelSize": 44, "fontWeight": 500, "lineHeightMultiplier": 1.24,
                      "textAlign": "left", "verticalAlign": "start"},
            "data": {"layerName": "Verse" if kind == "scripture" else "Lyric",
                     "linkage": body_linkage, "autoResize": True, "maxFontSize": 46,
                     "motion": {"in": TEXT_IN, "out": TEXT_OUT,
                                "swap": {"out": 160, "in": 260}}},
        },
    ]
    if kind == "scripture":
        out[-1]["data"]["verseNumberColor"] = ACCENT
    else:
        # On the title row, right-aligned: its bottom sits one gap above
        # the lyric, the same as the title's.
        out.append({
            "id": "credits", "kind": "text",
            "style": {"x": CARD_X + CARD_W - PAD_X - 26, "y": 60, "width": 26, "height": 4.4,
                      "z": 3, "opacity": 1, "color": MUTED, "fontFamily": FONT,
                      "fontPixelSize": 20, "fontWeight": 400, "lineHeightMultiplier": 1.15,
                      "textAlign": "right", "verticalAlign": "end"},
            "data": {"layerName": "Credits", "linkage": "songCredits",
                     "autoResize": True, "maxFontSize": 20,
                     "autoPosition": {"place": "above", "source": "body", "gap": GAP},
                     "motion": {"in": TEXT_IN, "out": TEXT_OUT}},
        })
    return out


def tokens(kind):
    return {"version": 3, "canvas": {"width": 1920, "height": 1080},
            "layouts": [{"id": "content", "name": "Content", "default": True,
                         "nodes": nodes(kind)}]}


def sql_literal(s):
    return "'" + s.replace("'", "''") + "'"


def main():
    EXAMPLES.mkdir(parents=True, exist_ok=True)
    inserts = []
    for kind in ("scripture", "song"):
        tok = tokens(kind)
        compact = json.dumps(tok, separators=(",", ":"), ensure_ascii=False)
        inserts.append(f"""
INSERT INTO themes (kind, name, tokens_json, is_builtin, tokens_version, created_at, updated_at)
SELECT {sql_literal(kind)}, {sql_literal(NAME)}, {sql_literal(compact)}, 1, 3,
       CAST(strftime('%s','now') AS INTEGER) * 1000,
       CAST(strftime('%s','now') AS INTEGER) * 1000
 WHERE NOT EXISTS (SELECT 1 FROM themes
                    WHERE kind = {sql_literal(kind)} AND is_builtin = 1 AND name = {sql_literal(NAME)});""")

        readable = {"name": NAME, "kind": kind, "tokens": tok}
        out = EXAMPLES / f"{kind}-{SLUG}.theme.json"
        out.write_text(json.dumps(readable, indent=2, ensure_ascii=False) + "\n",
                       encoding="utf-8", newline="\n")

    header = """\
-- App schema v14 - built-in lower thirds with motion.
--
-- GENERATED by scripts/gen-motion-themes.py. Edit that script and re-run
-- it; hand edits here are lost. The same generator writes readable copies
-- to docs/examples/<kind>-slate-lower-third.theme.json.
--
-- Seeds Slate Lower Third for scripture and for songs. Its nodes carry
-- data.motion, so on a stream the card rises in, the text swaps in place
-- for each verse, and Clear plays the exit. No default changes: these are
-- added to the Themes tab only.
--
-- tokens_version is stamped 3 explicitly (see V006 and V011 for why).
-- NOT EXISTS keeps the inserts safe on a DB that somehow already has them.
"""

    MIGRATION.write_text(header + "".join(inserts) + "\n",
                         encoding="utf-8", newline="\n")
    print(f"wrote {MIGRATION.relative_to(REPO)} ({MIGRATION.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
