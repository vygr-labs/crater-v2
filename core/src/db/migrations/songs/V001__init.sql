-- Songs schema v1.
-- Tables: songs, song_sections, songs_fts (FTS5).
-- See plan's Phase 2 / "Schema migrations" section for the rationale.

CREATE TABLE songs (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    title        TEXT NOT NULL,
    author       TEXT,
    copyright    TEXT,
    ccli         TEXT,                              -- CCLI license number
    theme_id     INTEGER,                           -- soft FK to app.themes.id; nullable
    is_favorite  INTEGER NOT NULL DEFAULT 0 CHECK (is_favorite IN (0, 1)),
    created_at   INTEGER NOT NULL,                  -- unix epoch ms
    updated_at   INTEGER NOT NULL
);

CREATE INDEX idx_songs_title    ON songs(title COLLATE NOCASE);
CREATE INDEX idx_songs_favorite ON songs(is_favorite) WHERE is_favorite = 1;

CREATE TABLE song_sections (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    song_id     INTEGER NOT NULL REFERENCES songs(id) ON DELETE CASCADE,
    label       TEXT,                                -- display: "Verse 1", "Chorus"
    kind        TEXT NOT NULL CHECK (kind IN (
                    'verse', 'chorus', 'bridge', 'intro', 'outro',
                    'tag', 'prechorus', 'interlude', 'other')),
    lines_json  TEXT NOT NULL,                       -- JSON array of strings (one per line)
    sort_order  INTEGER NOT NULL
);

CREATE INDEX idx_sections_song ON song_sections(song_id, sort_order);

-- Contentless FTS5 for typo-tolerant title/author/lyrics search. Populated by
-- the importer + on every CRUD operation (SongService handles).
CREATE VIRTUAL TABLE songs_fts USING fts5(
    title, author, lyrics,
    content='',
    tokenize='trigram'
);
