-- Bible schema v1.
-- Tables: translations, books, verses, verses_fts (FTS5).
-- See plan's Phase 2 / "Schema migrations" section for the rationale and the
-- specific improvements over Electron's denormalized scriptures table.
--
-- NOTE: connection-level pragmas (journal_mode, foreign_keys, synchronous,
-- busy_timeout, temp_store) are set in crater::db::Connection's constructor,
-- not here. Migrations are pure schema; pragmas are runtime.

CREATE TABLE translations (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    code         TEXT NOT NULL UNIQUE,            -- "KJV", "NIV", "ESV"
    name         TEXT NOT NULL,                   -- "King James Version"
    language     TEXT NOT NULL DEFAULT 'en',
    year         INTEGER,                         -- year of first publication
    description  TEXT,
    sort_order   INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE books (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    translation_id  INTEGER NOT NULL REFERENCES translations(id) ON DELETE CASCADE,
    name            TEXT NOT NULL,                -- "Genesis", "John"
    abbrev          TEXT NOT NULL,                -- "Gen", "Jn"
    testament       TEXT NOT NULL CHECK (testament IN ('OT', 'NT')),
    book_number     INTEGER NOT NULL,             -- canonical 1..66
    UNIQUE (translation_id, book_number)
);

CREATE INDEX idx_books_translation ON books(translation_id, book_number);

CREATE TABLE verses (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    translation_id  INTEGER NOT NULL REFERENCES translations(id) ON DELETE CASCADE,
    book_id         INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    chapter         INTEGER NOT NULL,
    verse           INTEGER NOT NULL,             -- always a single verse (no "1-3")
    text            TEXT NOT NULL,
    UNIQUE (translation_id, book_id, chapter, verse)
);

CREATE INDEX idx_verses_lookup ON verses(translation_id, book_id, chapter, verse);

-- Contentless FTS5 with trigram tokenizer. rowid is the same integer space as
-- verses.id; the importer populates this table directly after bulk-inserting
-- verses (no triggers, faster first-run import).
CREATE VIRTUAL TABLE verses_fts USING fts5(
    text,
    book_name UNINDEXED,
    translation_code UNINDEXED,
    content='',
    tokenize='trigram'
);
