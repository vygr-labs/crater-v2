-- App schema v8 — refresh the two Split Panel preset themes seeded by V007
-- so they match the design source files in stream-overlay/project/
-- (overlays.jsx + styles.css) rather than the description V007 was built
-- from. The Split Panel is variation 4 of the GCCC Ikorodu stream-overlay
-- pack; this migration leaves the other three variations (Classic Bar,
-- Wave Edge, Floating Card) for a future migration.
--
-- ── Implementation: UPDATE, not DELETE+INSERT ────────────────────────────
-- Themes are referenced from SettingsService by integer id
-- (themeIdForPrimary/Ndi/Stage). DELETE+INSERT would give the new themes
-- fresh ids and silently break any operator's "default Split Panel for
-- primary output" setting — they would render LiveContent.qml's noThemeText
-- fallback ("Default scripture theme has not been set") until they re-pick
-- the theme. UPDATE-in-place preserves the ids, so the refresh is invisible
-- to operators' settings: they just see the redesigned layout on next render.
--
-- ── Changes from V007 ────────────────────────────────────────────────────
-- Scripture theme:
--   • verse.data.maxFontSize: 44 → 30
--     V007 let the verse grow up to 44 px when room permitted; the design
--     fixes the verse at 30 px (overlays.jsx:413, scripture-body inline
--     fontSize:30). Capping maxFontSize at 30 keeps short references like
--     John 3:16 from rendering noticeably larger than the designer intended.
--     autoResize still kicks in for long verses (Psalm 119 etc), shrinking
--     below 30 px so the text fits the right block without clipping.
--
-- Song theme:
--   • lyric.style.fontPixelSize : 24 → 28
--   • lyric.style.fontWeight    : 500 → 600
--   • lyric.style.letterSpacing : -0.12 → -0.14
--   • lyric.data.maxFontSize    : 36 → 28
--     The design renders song lyrics in two treatments: 28 px / weight 600
--     for the current line, and 20 px / weight 500 for past/future lines
--     (overlays.jsx:417-426). V007 picked 24 px / weight 500 as a
--     compromise. But Crater's lyric linkage returns the operator's
--     CURRENT stanza only — there is no "non-current line" inside that
--     view. So the audience is always looking at current-line content and
--     it should render at the current-line treatment: 28 px, weight 600,
--     letter-spacing -0.005em (= -0.14 px at 28 px from styles.css's
--     .song-lyric class).
--
-- Unchanged from V007 (these were already faithful to the design and
-- listed here for review reference, not as edits):
--   • Layout: panel y/height, left/right block split at 340 px = 17.71%
--   • Colors: brand red #E63340, brand blue #3CB4E7, ink #0E1116, bg #0a0a0c
--   • Padding: 28 px horizontal / 24 px vertical on the left block
--   • Brand label "GCCC\nIkorodu" 11 px Space Grotesk weight 600, .16em uppercase
--   • Kind labels "Scripture Reading" / "Worship" 10 px, .16em uppercase
--   • Reference 36 px Space Grotesk weight 700 with scriptureRef linkage
--   • Title 22 px Space Grotesk weight 700 with scriptureRef linkage
--   • Wave decoration as two flat bars (Crater has no SVG node type)
--   • MarkIcon omitted (no SVG; operator can import the PNG via Media tab)
--   • Translation merged into the reference string ("John 3:16 (ESV)") since
--     Crater has no translation-only text linkage. The design's separate
--     small translation label below the ref is omitted; the ref stays
--     anchored at the bottom of the left block to fill the space the
--     translation would have occupied.
--
-- Operators who customised these themes have copies with is_builtin = 0
-- and a different name (duplicate-then-edit, per ThemeService::update's
-- builtin guard). The WHERE clauses below filter on is_builtin = 1 + the
-- exact V007 names, so user duplicates are untouched.

UPDATE themes SET
    tokens_json = '{"version":2,"canvas":{"width":1920,"height":1080},"nodes":[{"id":"bg","kind":"container","style":{"x":0,"y":0,"width":100,"height":100,"z":0,"backgroundColor":"#0a0a0c"},"data":{}},{"id":"left-block","kind":"container","style":{"x":0,"y":79.63,"width":17.71,"height":20.37,"z":1,"backgroundColor":"#E63340"},"data":{}},{"id":"right-block","kind":"container","style":{"x":17.71,"y":79.63,"width":82.29,"height":20.37,"z":1,"backgroundColor":"#0E1116"},"data":{}},{"id":"brand-label","kind":"text","style":{"x":1.46,"y":81.85,"width":14.79,"height":3.0,"z":2,"opacity":0.85,"color":"#ffffff","fontFamily":"Space Grotesk","fontPixelSize":11,"fontWeight":600,"lineHeightMultiplier":1.25,"letterSpacing":1.76,"textAlign":"left","verticalAlign":"start","textTransform":"uppercase"},"data":{"linkage":"custom","text":"GCCC\nIkorodu","autoResize":false}},{"id":"kind-label","kind":"text","style":{"x":1.46,"y":92.96,"width":14.79,"height":0.93,"z":2,"opacity":0.7,"color":"#ffffff","fontFamily":"Space Grotesk","fontPixelSize":10,"fontWeight":600,"letterSpacing":1.6,"textAlign":"left","verticalAlign":"start","textTransform":"uppercase"},"data":{"linkage":"custom","text":"Scripture Reading","autoResize":false}},{"id":"ref","kind":"text","style":{"x":1.46,"y":94.45,"width":14.79,"height":3.33,"z":2,"color":"#ffffff","fontFamily":"Space Grotesk","fontPixelSize":36,"fontWeight":700,"lineHeightMultiplier":1.0,"letterSpacing":-0.36,"textAlign":"left","verticalAlign":"start"},"data":{"linkage":"scriptureRef","autoResize":true,"maxFontSize":36}},{"id":"wave-red","kind":"container","style":{"x":93.54,"y":81.11,"width":5.21,"height":0.28,"z":2,"opacity":0.35,"backgroundColor":"#E63340"},"data":{}},{"id":"wave-blue","kind":"container","style":{"x":93.54,"y":82.04,"width":5.21,"height":0.28,"z":2,"opacity":0.35,"backgroundColor":"#3CB4E7"},"data":{}},{"id":"verse","kind":"text","style":{"x":20.63,"y":79.63,"width":71.86,"height":20.37,"z":2,"color":"#ffffff","fontFamily":"Newsreader","fontPixelSize":30,"fontWeight":400,"lineHeightMultiplier":1.34,"letterSpacing":0,"textAlign":"left","verticalAlign":"center"},"data":{"linkage":"scriptureText","autoResize":true,"maxFontSize":30}}]}',
    updated_at = CAST(strftime('%s','now') AS INTEGER) * 1000
WHERE is_builtin = 1
  AND kind = 'scripture'
  AND name = 'Split Panel — Scripture';

UPDATE themes SET
    tokens_json = '{"version":2,"canvas":{"width":1920,"height":1080},"nodes":[{"id":"bg","kind":"container","style":{"x":0,"y":0,"width":100,"height":100,"z":0,"backgroundColor":"#0a0a0c"},"data":{}},{"id":"left-block","kind":"container","style":{"x":0,"y":75.93,"width":17.71,"height":24.07,"z":1,"backgroundColor":"#E63340"},"data":{}},{"id":"right-block","kind":"container","style":{"x":17.71,"y":75.93,"width":82.29,"height":24.07,"z":1,"backgroundColor":"#0E1116"},"data":{}},{"id":"brand-label","kind":"text","style":{"x":1.46,"y":78.15,"width":14.79,"height":3.0,"z":2,"opacity":0.85,"color":"#ffffff","fontFamily":"Space Grotesk","fontPixelSize":11,"fontWeight":600,"lineHeightMultiplier":1.25,"letterSpacing":1.76,"textAlign":"left","verticalAlign":"start","textTransform":"uppercase"},"data":{"linkage":"custom","text":"GCCC\nIkorodu","autoResize":false}},{"id":"kind-label","kind":"text","style":{"x":1.46,"y":91.48,"width":14.79,"height":0.93,"z":2,"opacity":0.7,"color":"#ffffff","fontFamily":"Space Grotesk","fontPixelSize":10,"fontWeight":600,"letterSpacing":1.6,"textAlign":"left","verticalAlign":"start","textTransform":"uppercase"},"data":{"linkage":"custom","text":"Worship","autoResize":false}},{"id":"title","kind":"text","style":{"x":1.46,"y":93.15,"width":14.79,"height":4.63,"z":2,"color":"#ffffff","fontFamily":"Space Grotesk","fontPixelSize":22,"fontWeight":700,"lineHeightMultiplier":1.15,"letterSpacing":-0.22,"textAlign":"left","verticalAlign":"start"},"data":{"linkage":"scriptureRef","autoResize":true,"maxFontSize":22}},{"id":"wave-red","kind":"container","style":{"x":93.54,"y":77.41,"width":5.21,"height":0.28,"z":2,"opacity":0.35,"backgroundColor":"#E63340"},"data":{}},{"id":"wave-blue","kind":"container","style":{"x":93.54,"y":78.34,"width":5.21,"height":0.28,"z":2,"opacity":0.35,"backgroundColor":"#3CB4E7"},"data":{}},{"id":"lyric","kind":"text","style":{"x":20.63,"y":75.93,"width":71.86,"height":24.07,"z":2,"color":"#ffffff","fontFamily":"Manrope","fontPixelSize":28,"fontWeight":600,"lineHeightMultiplier":1.22,"letterSpacing":-0.14,"textAlign":"left","verticalAlign":"center"},"data":{"linkage":"lyric","autoResize":true,"maxFontSize":28}}]}',
    updated_at = CAST(strftime('%s','now') AS INTEGER) * 1000
WHERE is_builtin = 1
  AND kind = 'song'
  AND name = 'Split Panel — Song';
