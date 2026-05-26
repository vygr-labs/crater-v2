-- App schema v8 — user-imported fonts.
--
-- Crater historically only registered fonts from QRC (Funnel Sans, Lucide).
-- Theme bundles (.craterheme v2) can ship font files — see
-- ARCHITECTURE.md §10 — so we now have a place for fonts the operator
-- installed via a bundle import.
--
-- Files live at AppDataLocation/fonts/<hash>.<ext> (content-addressed),
-- mirroring the layout we use for bundled media. The `family` column is
-- the canonical family name that QFontDatabase exposed when the file was
-- first registered — themes reference it via style.fontFamily exactly as
-- they would for a system-installed font.
CREATE TABLE user_fonts (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    hash      TEXT    NOT NULL UNIQUE,     -- sha256 of file bytes (lowercase hex)
    family    TEXT    NOT NULL,            -- first family from applicationFontFamilies()
    path      TEXT    NOT NULL UNIQUE,     -- managed AppData path
    added_at  INTEGER NOT NULL             -- unix epoch ms
);

-- Lookups by family are common during theme export (resolve family ->
-- file path for bundling). Hash lookups happen during bundle import
-- (skip re-adding a font we already have).
CREATE INDEX idx_user_fonts_family ON user_fonts(family);
