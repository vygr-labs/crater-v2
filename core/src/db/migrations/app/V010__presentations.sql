-- App schema v10 — presentation decks (sermon notes) + the built-in
-- presentation themes that render them.
--
-- Two halves, and they have to land together: the decks are the first
-- content Crater has ever had of kind 'presentation', and until now the
-- only built-in presentation theme was a v1 row whose single text node
-- was linked to `custom` with an empty string. It could not display a
-- slide even in principle, because there were no slides. Shipping the
-- table without the themes would give operators decks that project a
-- background and nothing else.

-- ── Decks ───────────────────────────────────────────────────────────────
-- One row per deck; slides live in a JSON column rather than a child
-- table. A deck is read and written whole (the editor loads all of it and
-- saves all of it), it is a few KB, and nothing queries across slides —
-- a child table would buy per-slide ordering and partial reads that
-- nothing asks for, at the cost of a join on every load.
--
-- slide_count is denormalized so the library list can render "6 slides"
-- for every row without parsing every deck's JSON on every refresh. Every
-- write path in PresentationService recomputes it from the JSON it just
-- serialized, so the two cannot drift.
--
-- theme_id is a per-deck theme override, mirroring the per-item themeId
-- songs already carry. 0 means "no override": resolution falls through to
-- the output's presentation slot and then the per-kind default, which is
-- exactly what AppState.resolveItemTheme already does for other kinds.
-- Deliberately NOT a foreign key — deleting a theme must not delete or
-- block a deck, and the resolver already treats a dangling id as "no
-- override" by checking the looked-up theme's id.
CREATE TABLE presentations (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    title        TEXT    NOT NULL,
    slides_json  TEXT    NOT NULL DEFAULT '[]',   -- [{title, body, notes}, ...]
    slide_count  INTEGER NOT NULL DEFAULT 0,
    theme_id     INTEGER NOT NULL DEFAULT 0,
    created_at   INTEGER NOT NULL,
    updated_at   INTEGER NOT NULL
);

-- The library lists decks most-recently-edited first, which is the order an
-- operator wants on a Sunday morning: this week's sermon at the top.
CREATE INDEX idx_presentations_updated ON presentations(updated_at DESC);

-- ── Built-in presentation themes ────────────────────────────────────────
-- V006 left a note for exactly this migration: seed v2 token JSON with
-- tokens_version set EXPLICITLY to 2, because a row left at the column
-- default of 1 gets re-run through the v1->v2 converter on next launch.
--
-- All three use a group card (see docs/theme-schema.md §7) holding
-- ["title", "body"] with anchor "center". That one choice is the whole
-- layout system for slides: the card hugs whatever its members actually
-- render to, so a slide with a title and no body reads as a section
-- divider, a slide with a body and no title reads as a plain content
-- slide, and a slide with both reads as a heading over content — with no
-- per-slide layout enum for the theme and the deck to disagree about.
-- Centering (rather than the lower-third bottom anchor scripture themes
-- use) is what keeps a one-line slide and an eight-line slide both looking
-- deliberate instead of both hanging off the same lower edge.

-- Stage Bold is the row V001 seeded and defaultFor('presentation') still
-- resolves to (first built-in of the kind, by id). Rewritten in place
-- rather than superseded, so the default an operator gets on first run is
-- one that can actually render a slide. Safe to overwrite: built-ins are
-- immutable by contract (ThemeService::update refuses to edit them), so
-- there are no user edits here to lose.
UPDATE themes
   SET tokens_json = '{"version":2,"canvas":{"width":1920,"height":1080},"nodes":[{"id":"bg","kind":"container","style":{"x":0,"y":0,"width":100,"height":100,"z":0,"opacity":1,"backgroundColor":"#1a0b1f"},"data":{"layerName":"Background","fill":{"type":"gradient","gradient":{"style":"mesh","colors":["#1a0b1f","#3b0f4d","#241038","#120818"],"angle":0,"speed":0.18,"animate":true}}}},{"id":"card","kind":"container","style":{"x":8,"y":10,"width":84,"height":80,"z":1,"opacity":1},"data":{"layerName":"Slide card","group":{"members":["title","body"],"gap":3,"padTop":0,"padBottom":0,"padX":0,"anchor":"center"}}},{"id":"title","kind":"text","style":{"x":8,"y":26,"width":84,"height":20,"z":3,"opacity":1,"color":"#fff8e7","fontFamily":"Segoe UI Variable Display","fontPixelSize":96,"fontWeight":700,"letterSpacing":0.5,"lineHeightMultiplier":1.1,"textAlign":"center","verticalAlign":"center","textShadowColor":"#cc000000","textShadowOffsetY":3,"textShadowBlur":18},"data":{"layerName":"Title","linkage":"presentationTitle","autoResize":true,"maxFontSize":132}},{"id":"body","kind":"text","style":{"x":8,"y":50,"width":84,"height":34,"z":2,"opacity":1,"color":"#e9dff2","fontFamily":"Segoe UI Variable Display","fontPixelSize":56,"fontWeight":400,"lineHeightMultiplier":1.35,"textAlign":"center","verticalAlign":"center","textShadowColor":"#99000000","textShadowOffsetY":2,"textShadowBlur":12},"data":{"layerName":"Body","linkage":"presentationBody","autoResize":true,"maxFontSize":76}}]}',
       tokens_version = 2,
       updated_at = CAST(strftime('%s','now') AS INTEGER) * 1000
 WHERE kind = 'presentation' AND is_builtin = 1 AND name = 'Stage Bold';

-- Two more, so the kind ships with a real choice rather than one look.
-- Both are solid-colour or static-gradient only: the projection machine is
-- specified down to an Intel HD 4000 (ARCHITECTURE.md §6), and an animated
-- mesh on every output at once is the one thing in the theme system that
-- can cost real frame budget. Stage Bold animates because it is the
-- showpiece; these two stay still.
INSERT INTO themes (kind, name, tokens_json, is_builtin, tokens_version, created_at, updated_at) VALUES
  ('presentation', 'Clean Light',
   '{"version":2,"canvas":{"width":1920,"height":1080},"nodes":[{"id":"bg","kind":"container","style":{"x":0,"y":0,"width":100,"height":100,"z":0,"opacity":1,"backgroundColor":"#f8fafc"},"data":{"layerName":"Background"}},{"id":"rule","kind":"container","style":{"x":10,"y":16,"width":9,"height":1.1,"z":1,"opacity":1,"backgroundColor":"#1d4ed8"},"data":{"layerName":"Accent rule"}},{"id":"card","kind":"container","style":{"x":10,"y":22,"width":80,"height":62,"z":2,"opacity":1},"data":{"layerName":"Slide card","group":{"members":["title","body"],"gap":3.5,"padTop":0,"padBottom":0,"padX":0,"anchor":"center"}}},{"id":"title","kind":"text","style":{"x":10,"y":28,"width":80,"height":20,"z":4,"opacity":1,"color":"#0f172a","fontFamily":"Segoe UI Variable Display","fontPixelSize":88,"fontWeight":700,"letterSpacing":-0.5,"lineHeightMultiplier":1.08,"textAlign":"left","verticalAlign":"center"},"data":{"layerName":"Title","linkage":"presentationTitle","autoResize":true,"maxFontSize":120}},{"id":"body","kind":"text","style":{"x":10,"y":52,"width":80,"height":30,"z":3,"opacity":1,"color":"#334155","fontFamily":"Segoe UI Variable Display","fontPixelSize":50,"fontWeight":400,"lineHeightMultiplier":1.45,"textAlign":"left","verticalAlign":"center"},"data":{"layerName":"Body","linkage":"presentationBody","autoResize":true,"maxFontSize":68}}]}',
   1, 2,
   CAST(strftime('%s','now') AS INTEGER) * 1000,
   CAST(strftime('%s','now') AS INTEGER) * 1000),

  ('presentation', 'Midnight Focus',
   '{"version":2,"canvas":{"width":1920,"height":1080},"nodes":[{"id":"bg","kind":"container","style":{"x":0,"y":0,"width":100,"height":100,"z":0,"opacity":1,"backgroundColor":"#020617"},"data":{"layerName":"Background","fill":{"type":"gradient","gradient":{"style":"radial","colors":["#0b1a3a","#020617"],"angle":0,"animate":false}}}},{"id":"card","kind":"container","style":{"x":9,"y":12,"width":82,"height":76,"z":1,"opacity":1},"data":{"layerName":"Slide card","group":{"members":["title","body"],"gap":3,"padTop":0,"padBottom":0,"padX":0,"anchor":"center"}}},{"id":"title","kind":"text","style":{"x":9,"y":28,"width":82,"height":18,"z":3,"opacity":1,"color":"#7dd3fc","fontFamily":"Segoe UI Variable Display","fontPixelSize":64,"fontWeight":600,"letterSpacing":3,"lineHeightMultiplier":1.15,"textAlign":"center","verticalAlign":"center","textTransform":"uppercase"},"data":{"layerName":"Title","linkage":"presentationTitle","autoResize":true,"maxFontSize":84}},{"id":"body","kind":"text","style":{"x":9,"y":48,"width":82,"height":34,"z":2,"opacity":1,"color":"#f1f5f9","fontFamily":"Segoe UI Variable Display","fontPixelSize":64,"fontWeight":500,"lineHeightMultiplier":1.3,"textAlign":"center","verticalAlign":"center","textShadowColor":"#b3000000","textShadowOffsetY":2,"textShadowBlur":14},"data":{"layerName":"Body","linkage":"presentationBody","autoResize":true,"maxFontSize":92}}]}',
   1, 2,
   CAST(strftime('%s','now') AS INTEGER) * 1000,
   CAST(strftime('%s','now') AS INTEGER) * 1000);
