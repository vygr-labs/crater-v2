#!/usr/bin/env python3
"""Generates the built-in presentation themes and the migration that seeds them.

Why a generator instead of hand-written SQL
-------------------------------------------
Three themes times seven designs is twenty-one node graphs. Written by hand
they drift: the title in "Quote" ends up a different weight from the title in
"Section divider" for no reason anybody intended, and the drift is invisible
until an operator flips between two designs mid-service and the type jumps.

So each theme is declared once as a palette plus a type scale, and every
design is composed from shared builders. Changing the body colour of Stage
Bold is one edit here rather than seven edits in a 40KB SQL literal, and
"same theme, different design" is true by construction.

Outputs (both are committed; this script is not run at build time):
  core/src/db/migrations/app/V011__presentation_layouts.sql
  docs/examples/presentation-<slug>.theme.json   (readable reference copies)

Run from the repo root (qt/):
  python scripts/gen-presentation-themes.py
"""

import json
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
MIGRATION = REPO / "core/src/db/migrations/app/V011__presentation_layouts.sql"
EXAMPLES = REPO / "docs/examples"

FONT = "Segoe UI Variable Display"


# ── Node builders ──────────────────────────────────────────────────────────
# Geometry is percent of a 1920x1080 canvas throughout (theme-schema.md §5).

def container(nid, layer, box, *, color=None, fill=None, z=0, linkage=None,
              radius=None, opacity=1.0):
    style = {"x": box[0], "y": box[1], "width": box[2], "height": box[3],
             "z": z, "opacity": opacity}
    if color:
        style["backgroundColor"] = color
    if radius:
        for c in ("borderTopLeftRadius", "borderTopRightRadius",
                  "borderBottomLeftRadius", "borderBottomRightRadius"):
            style[c] = radius
    data = {"layerName": layer}
    if fill:
        data["fill"] = fill
    if linkage:
        data["linkage"] = linkage
    return {"id": nid, "kind": "container", "style": style, "data": data}


def card(nid, layer, box, members, *, z=1, gap=3.0, anchor="center",
         pad_top=0, pad_bottom=0, pad_x=0, fill=None, color=None):
    """A content-hugging group card (theme-schema.md §7).

    The card hugs whatever its members actually render to, so a design with
    an empty slot collapses cleanly instead of leaving a hole. That is why
    every text design here stacks inside one rather than pinning boxes.
    """
    node = container(nid, layer, box, z=z, fill=fill, color=color)
    node["data"]["group"] = {"members": members, "gap": gap,
                             "padTop": pad_top, "padBottom": pad_bottom,
                             "padX": pad_x, "anchor": anchor}
    return node


def text(nid, layer, linkage, box, *, color, size, weight=400, z=2,
         align="center", valign="center", line=1.2, spacing=None,
         transform=None, italic=False, auto=True, cap=None, shadow=None):
    style = {"x": box[0], "y": box[1], "width": box[2], "height": box[3],
             "z": z, "opacity": 1, "color": color, "fontFamily": FONT,
             "fontPixelSize": size, "fontWeight": weight,
             "lineHeightMultiplier": line,
             "textAlign": align, "verticalAlign": valign}
    if spacing is not None:
        style["letterSpacing"] = spacing
    if transform:
        style["textTransform"] = transform
    if italic:
        style["fontItalic"] = True
    if shadow:
        style["textShadowColor"] = shadow[0]
        style["textShadowOffsetY"] = shadow[1]
        style["textShadowBlur"] = shadow[2]
    data = {"layerName": layer, "linkage": linkage, "autoResize": auto}
    if auto:
        # autoResize fits to the node's OWN box height, so the box is a size
        # control and not merely a bound (theme-schema.md §8). cap defaults
        # generously above `size` so a one-line heading can actually grow.
        data["maxFontSize"] = cap if cap else int(size * 1.35)
    return {"id": nid, "kind": "text", "style": style, "data": data}


def layout(lid, name, nodes, *, default=False):
    l = {"id": lid, "name": name, "nodes": nodes}
    if default:
        l["default"] = True
    return l


# ── Theme definitions ──────────────────────────────────────────────────────
# A palette, a type scale and an alignment. Everything else is composed.

THEMES = [
    {
        "name": "Stage Bold",
        "slug": "stage-bold",
        "align": "center",
        "bg": "#1a0b1f",
        "bgFill": {"type": "gradient",
                   "gradient": {"style": "mesh",
                                "colors": ["#1a0b1f", "#3b0f4d", "#241038", "#120818"],
                                "angle": 0, "speed": 0.18, "animate": True}},
        "title": "#fff8e7",
        "body": "#e9dff2",
        "muted": "#b9a4c9",
        "accent": "#f5c36b",
        "band": "#33123f",
        # A drop shadow is what keeps cream text legible over a mesh that
        # moves under it; the two static themes below do not need one.
        "shadow": ("#cc000000", 3, 18),
        "titleWeight": 700,
    },
    {
        "name": "Clean Light",
        "slug": "clean-light",
        "align": "left",
        "bg": "#f8fafc",
        "bgFill": None,
        "title": "#0f172a",
        "body": "#334155",
        "muted": "#64748b",
        "accent": "#1d4ed8",
        "band": "#e8eefb",
        "shadow": None,
        "titleWeight": 700,
    },
    {
        "name": "Midnight Focus",
        "slug": "midnight-focus",
        "align": "center",
        "bg": "#020617",
        "bgFill": {"type": "gradient",
                   "gradient": {"style": "radial",
                                "colors": ["#0b1a3a", "#020617"],
                                "angle": 0, "animate": False}},
        "title": "#7dd3fc",
        "body": "#f1f5f9",
        "muted": "#94a3b8",
        "accent": "#38bdf8",
        "band": "#0b1a3a",
        "shadow": ("#b3000000", 2, 14),
        "titleWeight": 600,
    },
]


def build_layouts(t):
    al = t["align"]
    sh = t["shadow"]
    bg = lambda: container("bg", "Background", (0, 0, 100, 100),
                           color=t["bg"], fill=t["bgFill"], z=0)

    # 1. Title slide — the deck's opening frame. Title dominates; subtitle is
    #    a quiet second line, which is why it is a separate slot rather than
    #    the body: a body-sized second line reads as content, not as a
    #    sermon's date or series name.
    title_slide = layout("title", "Title slide", [
        bg(),
        card("card", "Title card", (8, 16, 84, 68), ["title", "subtitle"],
             z=1, gap=3.5),
        text("title", "Title", "presentationTitle", (8, 26, 84, 30),
             color=t["title"], size=110, weight=t["titleWeight"], z=3,
             align=al, line=1.05, cap=150, shadow=sh),
        text("subtitle", "Subtitle", "presentationSubtitle", (8, 58, 84, 12),
             color=t["muted"], size=44, weight=400, z=2,
             align=al, line=1.25, cap=58, shadow=sh),
    ])

    # 2. Section divider — one phrase, nothing else. The band is FIXED
    #    geometry, never content-adjacent: a hugging card re-centres per
    #    slide, so decoration drawn to bracket the text would sit right on a
    #    two-word divider and wrong on a seven-word one (theme-schema.md §8).
    section = layout("section", "Section divider", [
        bg(),
        container("band", "Accent band", (0, 30, 100, 40), color=t["band"], z=1),
        container("rule", "Accent rule", (0, 30, 100, 0.8), color=t["accent"], z=2),
        card("card", "Divider card", (8, 30, 84, 40), ["title"], z=3),
        text("title", "Title", "presentationTitle", (8, 36, 84, 28),
             color=t["title"], size=96, weight=t["titleWeight"], z=4,
             align=al, line=1.05, cap=132, shadow=sh),
    ])

    # 3. Title + content — the workhorse, and deliberately the same design
    #    the theme had before layouts existed, so upgrading changes nothing
    #    an operator had already built.
    content = layout("content", "Title + content", [
        bg(),
        card("card", "Slide card", (8, 10, 84, 80), ["title", "body"],
             z=1, gap=3.0),
        text("title", "Title", "presentationTitle", (8, 26, 84, 22),
             color=t["title"], size=88, weight=t["titleWeight"], z=3,
             align=al, line=1.1, cap=124, shadow=sh),
        text("body", "Body", "presentationBody", (8, 50, 84, 36),
             color=t["body"], size=54, weight=400, z=2,
             align=al, line=1.35, cap=74, shadow=sh),
    ], default=True)

    # 4. Two columns — the one design that CANNOT use a hugging card, because
    #    a card stacks its members vertically and these two sit side by side.
    #    So the boxes are pinned, and the title is pinned above them. Each
    #    column still auto-fits inside its own box, so uneven columns stay
    #    readable rather than one overflowing.
    two_col = layout("twoColumn", "Two columns", [
        bg(),
        text("title", "Title", "presentationTitle", (8, 9, 84, 16),
             color=t["title"], size=72, weight=t["titleWeight"], z=3,
             align=al, line=1.1, cap=96, shadow=sh),
        container("divider", "Column divider", (49.7, 30, 0.6, 56),
                  color=t["accent"], z=1, opacity=0.45),
        text("body", "Left column", "presentationBody", (8, 30, 39, 56),
             color=t["body"], size=46, weight=400, z=2,
             align="left", valign="start", line=1.4, cap=62, shadow=sh),
        text("bodyRight", "Right column", "presentationBodyRight", (53, 30, 39, 56),
             color=t["body"], size=46, weight=400, z=2,
             align="left", valign="start", line=1.4, cap=62, shadow=sh),
    ])

    # 5. Quote — hierarchy inverted on purpose. The body IS the headline and
    #    the title demotes to an attribution beneath it, which is why the
    #    card lists body first.
    quote = layout("quote", "Quote", [
        bg(),
        card("card", "Quote card", (10, 16, 80, 68), ["body", "title"],
             z=1, gap=4.5),
        text("body", "Quote", "presentationBody", (10, 24, 80, 40),
             color=t["title"], size=76, weight=500, z=3, italic=True,
             align=al, line=1.25, cap=104, shadow=sh),
        text("title", "Attribution", "presentationTitle", (10, 68, 80, 10),
             color=t["muted"], size=38, weight=500, z=2,
             align=al, line=1.2, spacing=2, transform="uppercase",
             cap=48, shadow=sh),
    ])

    # 6. Picture — a full-bleed image with a bottom-anchored caption. The
    #    picture container carries linkage "presentationImage", which is what
    #    makes the renderer feed it the SLIDE's media instead of the theme's.
    #    The scrim is a transparent-to-black gradient so a caption stays
    #    readable over a photograph nobody has seen yet.
    picture = layout("picture", "Picture", [
        bg(),
        container("picture", "Slide picture", (0, 0, 100, 100),
                  z=1, linkage="presentationImage"),
        container("scrim", "Caption scrim", (0, 48, 100, 52), z=2,
                  fill={"type": "gradient",
                        "gradient": {"style": "linear",
                                     "colors": ["#00000000", "#e6000000"],
                                     "angle": 90, "animate": False}}),
        card("card", "Caption card", (8, 56, 84, 34), ["title", "body"],
             z=3, gap=2.0, anchor="bottom", pad_bottom=2),
        text("title", "Caption title", "presentationTitle", (8, 62, 84, 16),
             color="#ffffff", size=64, weight=t["titleWeight"], z=5,
             align=al, line=1.1, cap=86,
             shadow=("#cc000000", 2, 16)),
        text("body", "Caption body", "presentationBody", (8, 78, 84, 14),
             color="#e2e8f0", size=40, weight=400, z=4,
             align=al, line=1.3, cap=52,
             shadow=("#cc000000", 2, 12)),
    ])

    # 7. Blank — background only. Not a filler entry: it is the slide an
    #    operator reaches for when the preacher wants the screen quiet
    #    without going to a black output, and having it as a design means
    #    they do not have to fake it with an empty content slide.
    blank = layout("blank", "Blank", [bg()])

    return [title_slide, section, content, two_col, quote, picture, blank]


def tokens_for(t):
    return {"version": 3,
            "canvas": {"width": 1920, "height": 1080},
            "layouts": build_layouts(t)}


# ── Emit ───────────────────────────────────────────────────────────────────

def sql_literal(s):
    return "'" + s.replace("'", "''") + "'"


def main():
    rows = []
    for t in THEMES:
        tok = tokens_for(t)
        compact = json.dumps(tok, separators=(",", ":"), ensure_ascii=False)
        rows.append((t["name"], compact))

        readable = {"name": t["name"], "kind": "presentation", "tokens": tok}
        out = EXAMPLES / f"presentation-{t['slug']}.theme.json"
        out.write_text(json.dumps(readable, indent=2, ensure_ascii=False) + "\n",
                       encoding="utf-8", newline="\n")

    header = """\
-- App schema v11 - presentation LAYOUTS (tokens v3).
--
-- GENERATED by scripts/gen-presentation-themes.py. Edit that script and
-- re-run it; hand edits here are lost. The same generator writes readable
-- copies of each theme to docs/examples/presentation-*.theme.json.
--
-- What changed and why
-- --------------------
-- Before this, a presentation theme was a single design, and every slide of
-- a deck came out the same shape. The only variation available was
-- accidental: a group card hugs its members, so leaving a slide's title
-- empty collapsed it and happened to read as a section divider.
--
-- A PowerPoint template does not work that way. It carries a set of named
-- designs - title slide, section header, title and content, two content -
-- and each slide picks one. Tokens v3 does the same: `layouts` replaces the
-- single `nodes` array, a slide stores the layout id it was built with, and
-- crater::tokens resolves it at render time (see crater/ThemeTokens.h).
--
-- Every theme here ships the same seven layout IDS on purpose. A deck's
-- layout id is a SOFT reference, because Crater lets the theme underneath a
-- deck change at any moment - per-deck override, per-output slot, per-kind
-- default, all swappable mid-service. Sharing the vocabulary means swapping
-- a deck from Stage Bold to Clean Light keeps every section divider a
-- section divider; an unknown id would merely fall back to the default.
--
-- The `content` layout of each theme is deliberately the design that theme
-- already had, and it is the one flagged default. An operator who upgrades
-- and opens an existing deck sees exactly what they saw yesterday.
--
-- tokens_version is stamped to 3 explicitly. V010's comment documents why
-- for v2, and it applies unchanged here: a row left at a lower number gets
-- re-run through the upgrade pass on next launch. That pass is idempotent
-- (crater::tokens::upgradeToV3 refuses to re-wrap existing layouts), but
-- stamping keeps it from doing pointless work on every start.
--
-- Built-ins are immutable by contract - ThemeService::update refuses to edit
-- them - so rewriting these rows in place cannot destroy a user's edits.
-- A user who wanted their own look duplicated the theme first, and their
-- copy is untouched here; the runtime v2 -> v3 pass upgrades it instead.
"""

    body = []
    for name, compact in rows:
        body.append(f"""
UPDATE themes
   SET tokens_json = {sql_literal(compact)},
       tokens_version = 3,
       updated_at = CAST(strftime('%s','now') AS INTEGER) * 1000
 WHERE kind = 'presentation' AND is_builtin = 1 AND name = {sql_literal(name)};""")

    MIGRATION.write_text(header + "".join(body) + "\n",
                         encoding="utf-8", newline="\n")

    print(f"wrote {MIGRATION.relative_to(REPO)} ({MIGRATION.stat().st_size} bytes)")
    for t in THEMES:
        n = len(build_layouts(t))
        print(f"  {t['name']:<16} {n} layouts")
    return 0


if __name__ == "__main__":
    sys.exit(main())
