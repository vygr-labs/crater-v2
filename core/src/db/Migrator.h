#pragma once

#include <QString>
#include <QStringView>

namespace crater::db {

class Connection;

// Migration runner.
//
// Reads SQL migration files from Qt resources at :/migrations/<dbName>/. Files
// must be named V<NNN>__<description>.sql (e.g. V001__init.sql,
// V002__add_ccli.sql). Versions are integers; ordering is numeric, not
// lexicographic.
//
// Behavior:
//   1. Compare each file's version against PRAGMA user_version on `conn`.
//   2. If current == highest available  — no-op.
//   3. If current  > highest available  — throw (user downgraded the app;
//      refuse to operate on a future-version DB rather than corrupt it).
//   4. Otherwise, before applying anything, copy the DB to
//      `<path>.backup-pre-v<N>.sqlite` where N is the highest target version.
//   5. For each missing version (ascending), open a transaction, exec() the
//      SQL, setUserVersion(version), commit. Failure rolls back atomically.
//
// Forward-only: no down migrations. Reasons in ARCHITECTURE.md §7.
class Migrator
{
public:
    // Runs all pending migrations. `dbName` selects the resource directory:
    // dbName "bibles" -> :/migrations/bibles/V*.sql.
    static void run(Connection& conn, QStringView dbName);
};

}  // namespace crater::db
