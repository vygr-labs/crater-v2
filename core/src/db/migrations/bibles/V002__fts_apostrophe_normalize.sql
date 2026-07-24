-- Bibles schema v2 — re-index verses_fts with apostrophe-normalised verse
-- text so search stops depending on exact apostrophe placement.
--
-- Search quality: the FTS5 trigram tokenizer treats an apostrophe as an
-- ordinary character. With the raw text indexed, `"God i's love"` (a stray
-- quote) produces the impossible trigram "i's" and — because query terms are
-- AND-ed — zeroes the whole search; likewise "gods" would never match a verse
-- reading "God's". Starting in this commit the query strips apostrophes
-- (crater::db::buildFtsQuery), so the index must match.
--
-- Unlike songs (whose lyrics need C++ DSL flattening), verse text is plain, so
-- the whole re-index runs here in SQL — no service-side rebuild hook needed.
-- The strip is replace(replace(v.text,'''',''),char(8217),'') = drop ASCII
-- apostrophe (U+0027) + curly right-quote (U+2019), identical to the wrap in
-- BibleService::rebuildFtsIndex and the ElectronDataImporter.
--
-- 'delete-all', not plain DELETE: verses_fts is contentless (content=''), so
-- DELETE is rejected; 'delete-all' is the only clear. The FTS rowid is
-- verses.id, so the rebuild re-joins books/translations for the UNINDEXED
-- book_name / translation_code columns exactly as the importer did.
INSERT INTO verses_fts(verses_fts) VALUES('delete-all');

INSERT INTO verses_fts (rowid, text, book_name, translation_code)
SELECT v.id,
       replace(replace(v.text, '''', ''), char(8217), ''),
       b.name, t.code
FROM verses v
JOIN books        b ON b.id = v.book_id
JOIN translations t ON t.id = v.translation_id;
