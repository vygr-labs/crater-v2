-- Removes the v1 built-in themes seeded by V001 ahead of a redesigned set
-- of defaults that will ship in a later migration. After this runs, the
-- themes table has no is_builtin = 1 rows; user-created themes
-- (is_builtin = 0) are untouched.
--
-- The kv entries `default_<kind>_theme_id` (set via ThemeService::
-- setDefaultFor) may reference one of the about-to-be-deleted built-ins.
-- Those entries are cleared first, while the referenced ids still
-- resolve — user-chosen defaults that point at custom themes stay intact
-- because the subquery only matches is_builtin = 1.

DELETE FROM kv
 WHERE key IN ('default_song_theme_id',
               'default_scripture_theme_id',
               'default_presentation_theme_id')
   AND CAST(value AS INTEGER) IN (SELECT id FROM themes WHERE is_builtin = 1);

DELETE FROM themes WHERE is_builtin = 1;
