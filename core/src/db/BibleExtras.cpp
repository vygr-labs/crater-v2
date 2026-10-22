#include "db/BibleExtras.h"

#include "db/Connection.h"
#include "db/Statement.h"
#include "db/Transaction.h"

namespace crater::db {

void ensureBibleExtras(Connection& conn)
{
    bool hasSource = false;
    {
        auto info = conn.prepare(QStringLiteral("PRAGMA table_info(translations)"));
        while (info.step())
            if (info.columnText(1) == u"source") hasSource = true;
    }
    bool hasPending = false;
    {
        auto table = conn.prepare(QStringLiteral(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'verses_fts_pending_delete'"));
        hasPending = table.step();
    }
    // Nothing to write, so no write lock: this runs at every startup.
    if (hasSource && hasPending) return;
    Transaction tx(conn, Transaction::Begin::Immediate);
    if (!hasSource)
        conn.exec(QStringLiteral(
            "ALTER TABLE translations ADD COLUMN source TEXT NOT NULL DEFAULT 'bundled'"));
    conn.exec(QStringLiteral(
        "CREATE TABLE IF NOT EXISTS verses_fts_pending_delete ("
        "    verse_id         INTEGER PRIMARY KEY,"   // the verses_fts rowid
        "    text             TEXT NOT NULL,"
        "    book_name        TEXT NOT NULL,"
        "    translation_code TEXT NOT NULL)"));
    tx.commit();
}

}  // namespace crater::db
