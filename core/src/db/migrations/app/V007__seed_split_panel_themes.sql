-- App schema v7 — seeds the first pair of themes from the GCCC Ikorodu
-- stream-overlay design pack: Split Panel × {scripture, song}. The other
-- three variations (Classic Bar, Wave Edge, Floating Card) follow in
-- their own migrations once these two are verified visually.
--
-- Design source: the stream-overlay handoff shared by the operator. The
-- pack is built for Glory Centre Community Church (Ikorodu); brand red
-- #E63340 + brand blue #3CB4E7 sit on the left block, deep ink #0E1116
-- on the right. Lower-third positioning is preserved — panel at y ≈ 80%
-- of the 1920×1080 canvas with height 220 px (scripture) / 260 px (song),
-- everything above the panel transparent so the canvas (or any per-node
-- media background the operator sets later) shows through.
--
-- Adaptations for Crater's v2 token model:
--   • SVG — Crater nodes don't render SVG. The original's 4-row brand-wave
--     MarkIcon in the left block is omitted in favor of the "GCCC IKORODU"
--     wordmark; operators wanting the actual logo can import the PNG into
--     the Media tab and attach it to a container in the editor. The tiny
--     corner-wave decoration is substituted with two thin colored bars
--     (red over blue), same hues, same opacity (0.35), same position.
--   • Fonts — Space Grotesk / Newsreader / Manrope are referenced by
--     family name. Operators without them installed fall through Qt's
--     application font chain to the bundled Funnel Sans. Visual quality
--     holds even on bare systems; for the exact original feel, install
--     the three families from Google Fonts.
--   • Translation label — the original surfaces translation code as a
--     separate small element below the reference. In Crater the
--     scriptureRef linkage already returns "Book Ch:V (CODE)" via the
--     AppState item builder, so the translation rides inside the ref
--     string and the dedicated small node is omitted.
--
-- tokens_version = 2 so the v1→v2 lazy migrator in ThemeService skips
-- these — they're already in the node-based shape that migrator produces.
-- is_builtin = 1 protects them from in-place edits in the editor
-- (duplicate-then-edit, per ThemeService::update's builtin guard).

INSERT INTO themes (kind, name, tokens_json, is_builtin, tokens_version, created_at, updated_at) VALUES

-- ── Split Panel — Scripture ───────────────────────────────────────────────
-- Layout (percent of 1920×1080 canvas):
--   panel:        y=79.63 (860 px), h=20.37 (220 px)
--   left block:   x=0,     w=17.71 (340 px), bg = brand red
--   right block:  x=17.71, w=82.29 (1580 px), bg = ink
--   brand label:  top-left of left block at 28 px padding, 11 px Space Grotesk
--   kind label:   bottom-of-left-block, "SCRIPTURE READING" at 10 px
--   ref:          large 36 px Space Grotesk bold, scriptureRef linkage
--   verse:        vertically centered in right block, 30 px Newsreader,
--                 width 71.86 (94% of padded right block) so it doesn't
--                 collide with the corner-wave decoration
--   wave-red/blue: 5.21% × 0.28% (100×3 px) bars at top-right of right
--                  block, at 0.35 opacity per the original
('scripture', 'Split Panel — Scripture',
 '{"version":2,"canvas":{"width":1920,"height":1080},"nodes":[{"id":"bg","kind":"container","style":{"x":0,"y":0,"width":100,"height":100,"z":0,"backgroundColor":"#0a0a0c"},"data":{}},{"id":"left-block","kind":"container","style":{"x":0,"y":79.63,"width":17.71,"height":20.37,"z":1,"backgroundColor":"#E63340"},"data":{}},{"id":"right-block","kind":"container","style":{"x":17.71,"y":79.63,"width":82.29,"height":20.37,"z":1,"backgroundColor":"#0E1116"},"data":{}},{"id":"brand-label","kind":"text","style":{"x":1.46,"y":81.85,"width":14.79,"height":3.0,"z":2,"opacity":0.85,"color":"#ffffff","fontFamily":"Space Grotesk","fontPixelSize":11,"fontWeight":600,"lineHeightMultiplier":1.25,"letterSpacing":1.76,"textAlign":"left","verticalAlign":"start","textTransform":"uppercase"},"data":{"linkage":"custom","text":"GCCC\nIkorodu","autoResize":false}},{"id":"kind-label","kind":"text","style":{"x":1.46,"y":92.96,"width":14.79,"height":0.93,"z":2,"opacity":0.7,"color":"#ffffff","fontFamily":"Space Grotesk","fontPixelSize":10,"fontWeight":600,"letterSpacing":1.6,"textAlign":"left","verticalAlign":"start","textTransform":"uppercase"},"data":{"linkage":"custom","text":"Scripture Reading","autoResize":false}},{"id":"ref","kind":"text","style":{"x":1.46,"y":94.45,"width":14.79,"height":3.33,"z":2,"color":"#ffffff","fontFamily":"Space Grotesk","fontPixelSize":36,"fontWeight":700,"lineHeightMultiplier":1.0,"letterSpacing":-0.36,"textAlign":"left","verticalAlign":"start"},"data":{"linkage":"scriptureRef","autoResize":true,"maxFontSize":36}},{"id":"wave-red","kind":"container","style":{"x":93.54,"y":81.11,"width":5.21,"height":0.28,"z":2,"opacity":0.35,"backgroundColor":"#E63340"},"data":{}},{"id":"wave-blue","kind":"container","style":{"x":93.54,"y":82.04,"width":5.21,"height":0.28,"z":2,"opacity":0.35,"backgroundColor":"#3CB4E7"},"data":{}},{"id":"verse","kind":"text","style":{"x":20.63,"y":79.63,"width":71.86,"height":20.37,"z":2,"color":"#ffffff","fontFamily":"Newsreader","fontPixelSize":30,"fontWeight":400,"lineHeightMultiplier":1.34,"letterSpacing":0,"textAlign":"left","verticalAlign":"center"},"data":{"linkage":"scriptureText","autoResize":true,"maxFontSize":44}}]}',
 1, 2,
 CAST(strftime('%s','now') AS INTEGER) * 1000,
 CAST(strftime('%s','now') AS INTEGER) * 1000),

-- ── Split Panel — Song ────────────────────────────────────────────────────
-- Same shape, panel grown to 260 px (24.07%) for songs per the original.
-- Differences from scripture:
--   • Panel y shifts to 75.93 (820 px); brand label / wave / lyric area
--     re-anchor to the new top.
--   • Bottom of left block: "WORSHIP" label + song title (22 px Space
--     Grotesk bold) instead of "SCRIPTURE READING" + ref. The title uses
--     scriptureRef linkage — the item builder returns the song's title in
--     the same field regardless of kind, so the linkage is reused.
--   • Right block content: lyric linkage (full page text, the operator's
--     current verse/chorus) at 24 px Manrope, vertically centered.
('song', 'Split Panel — Song',
 '{"version":2,"canvas":{"width":1920,"height":1080},"nodes":[{"id":"bg","kind":"container","style":{"x":0,"y":0,"width":100,"height":100,"z":0,"backgroundColor":"#0a0a0c"},"data":{}},{"id":"left-block","kind":"container","style":{"x":0,"y":75.93,"width":17.71,"height":24.07,"z":1,"backgroundColor":"#E63340"},"data":{}},{"id":"right-block","kind":"container","style":{"x":17.71,"y":75.93,"width":82.29,"height":24.07,"z":1,"backgroundColor":"#0E1116"},"data":{}},{"id":"brand-label","kind":"text","style":{"x":1.46,"y":78.15,"width":14.79,"height":3.0,"z":2,"opacity":0.85,"color":"#ffffff","fontFamily":"Space Grotesk","fontPixelSize":11,"fontWeight":600,"lineHeightMultiplier":1.25,"letterSpacing":1.76,"textAlign":"left","verticalAlign":"start","textTransform":"uppercase"},"data":{"linkage":"custom","text":"GCCC\nIkorodu","autoResize":false}},{"id":"kind-label","kind":"text","style":{"x":1.46,"y":91.48,"width":14.79,"height":0.93,"z":2,"opacity":0.7,"color":"#ffffff","fontFamily":"Space Grotesk","fontPixelSize":10,"fontWeight":600,"letterSpacing":1.6,"textAlign":"left","verticalAlign":"start","textTransform":"uppercase"},"data":{"linkage":"custom","text":"Worship","autoResize":false}},{"id":"title","kind":"text","style":{"x":1.46,"y":93.15,"width":14.79,"height":4.63,"z":2,"color":"#ffffff","fontFamily":"Space Grotesk","fontPixelSize":22,"fontWeight":700,"lineHeightMultiplier":1.15,"letterSpacing":-0.22,"textAlign":"left","verticalAlign":"start"},"data":{"linkage":"scriptureRef","autoResize":true,"maxFontSize":22}},{"id":"wave-red","kind":"container","style":{"x":93.54,"y":77.41,"width":5.21,"height":0.28,"z":2,"opacity":0.35,"backgroundColor":"#E63340"},"data":{}},{"id":"wave-blue","kind":"container","style":{"x":93.54,"y":78.34,"width":5.21,"height":0.28,"z":2,"opacity":0.35,"backgroundColor":"#3CB4E7"},"data":{}},{"id":"lyric","kind":"text","style":{"x":20.63,"y":75.93,"width":71.86,"height":24.07,"z":2,"color":"#ffffff","fontFamily":"Manrope","fontPixelSize":24,"fontWeight":500,"lineHeightMultiplier":1.22,"letterSpacing":-0.12,"textAlign":"left","verticalAlign":"center"},"data":{"linkage":"lyric","autoResize":true,"maxFontSize":36}}]}',
 1, 2,
 CAST(strftime('%s','now') AS INTEGER) * 1000,
 CAST(strftime('%s','now') AS INTEGER) * 1000);
