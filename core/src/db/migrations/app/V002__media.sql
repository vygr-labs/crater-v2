-- App schema v2 — media library.
--
-- Each row is one image or video the operator has imported via MediaService.
-- Paths point at the managed copy under AppDataLocation/media/, not the
-- original file (per ARCHITECTURE.md §5.1). `type` is the magic-byte-sniffed
-- classification ("image" | "video"), not the file extension.
CREATE TABLE media (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    path         TEXT    NOT NULL UNIQUE,                      -- managed AppData path
    title        TEXT    NOT NULL,
    type         TEXT    NOT NULL CHECK (type IN ('image', 'video')),
    is_favorite  INTEGER NOT NULL DEFAULT 0 CHECK (is_favorite IN (0, 1)),
    added_at     INTEGER NOT NULL                              -- unix epoch ms
);

CREATE INDEX idx_media_type      ON media(type);
CREATE INDEX idx_media_added_at  ON media(added_at DESC);
CREATE INDEX idx_media_favorite  ON media(is_favorite) WHERE is_favorite = 1;
