-- App schema v1.
-- Tables: themes (+ built-in defaults), schedules, current_schedule (singleton),
-- kv (key-value app state).
-- See plan's Phase 2 / "Schema migrations" section for the rationale.

CREATE TABLE themes (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    kind         TEXT NOT NULL CHECK (kind IN ('song', 'scripture', 'presentation')),
    name         TEXT NOT NULL,
    tokens_json  TEXT NOT NULL,                       -- JSON token data (see ThemeApplier.qml)
    is_builtin   INTEGER NOT NULL DEFAULT 0 CHECK (is_builtin IN (0, 1)),
    created_at   INTEGER NOT NULL,                    -- unix epoch ms
    updated_at   INTEGER NOT NULL
);

CREATE INDEX idx_themes_kind ON themes(kind);

-- Three built-in defaults — one per content kind. tokens_json is declarative
-- data consumed by ThemeApplier.qml in the projection renderer. JSON shape:
--   { background: {color, image?}, text: {fontFamily, fontPixelSize,
--     fontWeight, color, lineHeightMultiplier, letterSpacing},
--     layout: {padding, horizontalAlignment, verticalAlignment},
--     transition: {kind, durationMs, easing} }
INSERT INTO themes (kind, name, tokens_json, is_builtin, created_at, updated_at) VALUES
  ('song', 'Classic Dark',
   '{"background":{"color":"#0a0a0d","image":null},"text":{"fontFamily":"Segoe UI Variable Display","fontPixelSize":64,"fontWeight":500,"color":"#f5f5f0","lineHeightMultiplier":1.25,"letterSpacing":0.5},"layout":{"padding":80,"horizontalAlignment":"center","verticalAlignment":"center"},"transition":{"kind":"fade","durationMs":320,"easing":"easeInOutCubic"}}',
   1,
   CAST(strftime('%s','now') AS INTEGER) * 1000,
   CAST(strftime('%s','now') AS INTEGER) * 1000),

  ('scripture', 'Classic Dark',
   '{"background":{"color":"#0a0a0d","image":null},"text":{"fontFamily":"Segoe UI Variable Display","fontPixelSize":56,"fontWeight":400,"color":"#f5f5f0","lineHeightMultiplier":1.35,"letterSpacing":0.3},"layout":{"padding":80,"horizontalAlignment":"center","verticalAlignment":"center"},"transition":{"kind":"fade","durationMs":280,"easing":"easeInOutCubic"}}',
   1,
   CAST(strftime('%s','now') AS INTEGER) * 1000,
   CAST(strftime('%s','now') AS INTEGER) * 1000),

  ('presentation', 'Stage Bold',
   '{"background":{"color":"#1a0b1f","image":null},"text":{"fontFamily":"Segoe UI Variable Display","fontPixelSize":72,"fontWeight":700,"color":"#fff8e7","lineHeightMultiplier":1.15,"letterSpacing":1.0},"layout":{"padding":96,"horizontalAlignment":"center","verticalAlignment":"center"},"transition":{"kind":"fade","durationMs":360,"easing":"easeInOutCubic"}}',
   1,
   CAST(strftime('%s','now') AS INTEGER) * 1000,
   CAST(strftime('%s','now') AS INTEGER) * 1000);

CREATE TABLE schedules (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    name          TEXT NOT NULL,
    items_json    TEXT NOT NULL,                     -- JSON array of ScheduleItem
    item_count    INTEGER NOT NULL DEFAULT 0,
    created_at    INTEGER NOT NULL,
    modified_at   INTEGER NOT NULL
);

CREATE INDEX idx_schedules_modified ON schedules(modified_at DESC);

-- Singleton row holding the in-flight "current" working schedule. Distinct from
-- saved presets in `schedules`. Auto-save writes here every ~5s; saveAs(name)
-- snapshots items_json into a new `schedules` row.
CREATE TABLE current_schedule (
    id           INTEGER PRIMARY KEY CHECK (id = 1),
    items_json   TEXT NOT NULL DEFAULT '[]',
    modified_at  INTEGER NOT NULL
);

INSERT INTO current_schedule (id, items_json, modified_at)
VALUES (1, '[]', CAST(strftime('%s','now') AS INTEGER) * 1000);

-- Misc app key-value state (default-theme-ids, fts-indexed flags, etc.).
-- WITHOUT ROWID for a tiny perf win on a small table.
CREATE TABLE kv (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
) WITHOUT ROWID;
