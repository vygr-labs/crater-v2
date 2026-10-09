#pragma once

#include "db/Error.h"

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
//   3. If current  > highest available, the DB was upgraded by a newer
//      Crater. Open it untouched when every migration this build doesn't
//      know is marked readable by older versions (see below), otherwise
//      throw NewerSchemaError rather than risk corrupting it.
//   4. Otherwise, before applying anything, copy the DB to
//      `<path>.backup-pre-v<N>.sqlite` where N is the highest target version.
//   5. For each missing version (ascending), open a transaction, exec() the
//      SQL, setUserVersion(version), commit. Failure rolls back atomically.
//
// Forward-only: no down migrations. Reasons in ARCHITECTURE.md §7.
//
// Compatibility with older versions. A migration whose file contains the line
//
//     -- @readable-by-older-versions
//
// only adds things an older Crater ignores, such as new rows or a new table
// nothing old reads. After migrating, each DB records in its crater_schema
// table the oldest schema version that can still read it (the newest
// migration WITHOUT that marker) and the app version that migrated it. An
// older build reads both when it finds a DB newer than itself: it opens the
// DB if it knows that oldest version, and otherwise names the version to
// install. Only mark a migration when an older build really can keep using
// the DB, including writing to it.

// The DB was upgraded by a newer Crater and this build can't safely read it.
class NewerSchemaError : public Error
{
public:
    NewerSchemaError(QString msg, QString writtenBy)
        : Error(std::move(msg))
        , m_writtenBy(std::move(writtenBy))
    {}

    // The Crater version that last migrated the DB, or empty if unknown
    // (the DB was migrated before versions were recorded).
    const QString& writtenBy() const noexcept { return m_writtenBy; }

private:
    QString m_writtenBy;
};

class Migrator
{
public:
    // Runs all pending migrations. `dbName` selects the resource directory:
    // dbName "bibles" -> :/migrations/bibles/V*.sql.
    static void run(Connection& conn, QStringView dbName);
};

}  // namespace crater::db
