#include "db/BibleExtras.h"

#include "db/Connection.h"
#include "db/Statement.h"
#include "db/Transaction.h"

namespace crater::db {

namespace {

bool hasSourceColumn(Connection& conn)
{
    auto info = conn.prepare(QStringLiteral("PRAGMA table_info(translations)"));
    while (info.step())
        if (info.columnText(1) == u"source") return true;
    return false;
}

bool hasPendingTable(Connection& conn)
{
    auto table = conn.prepare(QStringLiteral(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'verses_fts_pending_delete'"));
    return table.step();
}

}  // namespace

void ensureBibleExtras(Connection& conn)
{
    // Nothing to write, so no write lock: this runs at every startup.
    if (hasSourceColumn(conn) && hasPendingTable(conn)) return;
    Transaction tx(conn, Transaction::Begin::Immediate);
    // Asked again under the lock: another Crater starting at the same moment
    // may have added the column first, and adding it twice fails.
    if (!hasSourceColumn(conn))
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
