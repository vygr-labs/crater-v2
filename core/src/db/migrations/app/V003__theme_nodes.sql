-- App schema v3 — theme tokens migrate from a single-text/single-background
-- token shape to a node-based canvas (containers + texts positioned by
-- percent). The column itself doesn't change; only the JSON inside.
--
-- The actual JSON rewrite runs in C++ (ThemeService::Impl::migrateRowsToV2),
-- gated by the per-row tokens_version flag this migration adds. Done this
-- way (not pure SQL) because building the node JSON needs the same
-- parser/serializer the runtime uses; duplicating that in SQL string concat
-- would be brittle.

ALTER TABLE themes ADD COLUMN tokens_version INTEGER NOT NULL DEFAULT 1;
