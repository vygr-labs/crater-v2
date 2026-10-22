-- Bibles schema v3: where each translation came from, and search index rows
-- waiting to be cleared.
--
-- source is 'bundled' for every translation installed before this: the
-- first-run and upgrade imports, and Bibles merged in from older profiles,
-- which were copies of bundled ones. BibleImporter writes 'file' for one the
-- operator added. Only 'file' translations can be removed. A bundled one may
-- have been dropped from the current bundle (older releases shipped NIV, ESV
-- and others), so removing it could never be undone.
ALTER TABLE translations ADD COLUMN source TEXT NOT NULL DEFAULT 'bundled';

-- verses_fts is contentless, so a row can only leave it through FTS5's
-- 'delete' command, given the exact values it was indexed with. Removing a
-- translation copies those values here in the same transaction that deletes
-- its verses, then clears them from the index in short batches. Whatever a
-- quit interrupts is picked up at the next launch. Until then search can't
-- return the rows: it joins through verses, and verse ids are never reused.
CREATE TABLE verses_fts_pending_delete (
    verse_id         INTEGER PRIMARY KEY,   -- the verses_fts rowid
    text             TEXT NOT NULL,
    book_name        TEXT NOT NULL,
    translation_code TEXT NOT NULL
);
