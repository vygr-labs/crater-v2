#pragma once

namespace crater::db {

class Connection;

// Additions to the bibles schema for Bibles added from files, kept outside
// the numbered migrations on purpose. A migration would raise user_version,
// and an older Crater refuses a library newer than it knows, so a downgrade
// would stop at startup. These only add, so an older Crater reading or
// writing the library never notices them:
//
//   translations.source         'bundled' (the default, for everything an
//                               older Crater writes too) or 'file' for one
//                               BibleImporter added. Only 'file' ones can be
//                               removed: older releases shipped Bibles the
//                               current bundle no longer has (NIV, ESV), and
//                               removing one could never be undone.
//
//   verses_fts_pending_delete   verses_fts is contentless, so a row leaves it
//                               only through FTS5's 'delete' command, given
//                               the exact values it was indexed with. Removing
//                               a translation copies those here in the same
//                               transaction that deletes its verses, and the
//                               rows are cleared from the index in batches
//                               afterwards. Search can't return them meanwhile:
//                               it joins through verses, and verse ids are
//                               never reused.
//
// Safe to call on every open; it writes only what's missing. Throws
// db::Error.
void ensureBibleExtras(Connection& conn);

}  // namespace crater::db
