-- Song collections v3.
-- User-created named groupings of songs. Membership is a proper many-to-many
-- join (a song can live in multiple collections). Favorites are unrelated —
-- they stay an is_favorite flag on songs (V001); collections are their own
-- tables. ON DELETE CASCADE on song_id mirrors song_sections so deleting a
-- song cleans up its collection membership automatically.

CREATE TABLE collections (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL,
    created_at  INTEGER NOT NULL,                -- unix epoch ms
    updated_at  INTEGER NOT NULL
);

CREATE TABLE collection_songs (
    collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
    song_id       INTEGER NOT NULL REFERENCES songs(id)       ON DELETE CASCADE,
    sort_order    INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (collection_id, song_id)
);

-- Reverse lookup: "which collections is this song in" + cascade on song delete.
CREATE INDEX idx_collection_songs_song ON collection_songs(song_id);
