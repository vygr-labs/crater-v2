-- App schema v5 — PDF media support.
--
-- Crater's media library originally constrained `type` to the magic-byte-
-- sniffed image/video pair. PDFs are a new third class — paged rasters with
-- vector source data. Conceptually they sit between image (single frame,
-- static) and video (multi-frame, time-based): a PDF is multi-frame and
-- static, advanced by the operator's arrow keys exactly like song verses.
--
-- Two changes:
--   1. Widen the type CHECK to include 'pdf' so MediaService can INSERT
--      PDF rows after the magic-byte sniffer (looking for '%PDF-') matches.
--   2. Add a page_count column. For images this stays 1 (the default); for
--      videos it stays 1 (videos use duration_ms instead); for PDFs it
--      carries the QPdfDocument::pageCount() value computed at import time.
--      Stored on the row so the schedule's page model can be built without
--      reopening the document on every render.
--
-- SQLite CHECK constraints cannot be ALTERed in place — we recreate the
-- table with the new constraint, copy rows over, and swap names. The
-- copy is wrapped in a transaction by the migration runner; no special
-- handling required here.

CREATE TABLE media_new (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    path         TEXT    NOT NULL UNIQUE,
    title        TEXT    NOT NULL,
    type         TEXT    NOT NULL CHECK (type IN ('image', 'video', 'pdf')),
    is_favorite  INTEGER NOT NULL DEFAULT 0 CHECK (is_favorite IN (0, 1)),
    added_at     INTEGER NOT NULL,
    duration_ms  INTEGER NOT NULL DEFAULT 0,
    page_count   INTEGER NOT NULL DEFAULT 1
);

INSERT INTO media_new (id, path, title, type, is_favorite, added_at, duration_ms, page_count)
SELECT id, path, title, type, is_favorite, added_at, duration_ms, 1
FROM media;

DROP TABLE media;
ALTER TABLE media_new RENAME TO media;

CREATE INDEX idx_media_type      ON media(type);
CREATE INDEX idx_media_added_at  ON media(added_at DESC);
CREATE INDEX idx_media_favorite  ON media(is_favorite) WHERE is_favorite = 1;
