#include "crater/Bootstrap.h"

#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Error.h"
#include "db/Migrator.h"
#include "profile/ProfileArchive.h"

#include <QDebug>

#include <QString>
#include <QStringLiteral>

namespace crater {

namespace {

void migrate(QStringView path, QStringView dbName, const QString& label)
{
    db::Connection conn(path, db::OpenMode::ReadWriteCreate, label);
    try {
        db::Migrator::run(conn, dbName);
    } catch (const db::NewerSchemaError& e) {
        throw NewerDataError(e.message(), e.writtenBy());
    }
}

}  // namespace

void runAllMigrations()
{
    // Each DB gets a scoped connection so it closes before services open
    // their own. Migrator throws on failure; we let it propagate.
    // Labels show up in the COMMIT/ROLLBACK trace + the BUSY diagnostic
    // so a migration-time write contention has a distinct identity from
    // the steady-state service connections that open later.
    migrate(db::DbPaths::biblesDbPath(), u"bibles", QStringLiteral("Migrator-bibles"));
    migrate(db::DbPaths::songsDbPath(), u"songs", QStringLiteral("Migrator-songs"));
    migrate(db::DbPaths::appDbPath(), u"app", QStringLiteral("Migrator-app"));

    // One shared Bible library. Profiles made before it kept their own
    // bibles.sqlite; fold any translation only a profile has into the shared
    // one. A no-op once every profile has been merged. A failure here must
    // not stop startup: the shared library still works without the extras.
    try {
        profile::consolidateProfileBibles();
    } catch (const db::Error& e) {
        qWarning().noquote() << "Shared Bibles: consolidation failed:" << e.message();
    }
}

}  // namespace crater
