#include "crater/Bootstrap.h"

#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Migrator.h"

#include <QString>
#include <QStringLiteral>

namespace crater {

void runAllMigrations()
{
    // Each DB gets a scoped connection so it closes before services open
    // their own. Migrator throws on failure; we let it propagate.
    // Labels show up in the COMMIT/ROLLBACK trace + the BUSY diagnostic
    // so a migration-time write contention has a distinct identity from
    // the steady-state service connections that open later.
    {
        db::Connection conn(db::DbPaths::biblesDbPath(),
                            db::OpenMode::ReadWriteCreate,
                            QStringLiteral("Migrator-bibles"));
        db::Migrator::run(conn, QStringLiteral("bibles"));
    }
    {
        db::Connection conn(db::DbPaths::songsDbPath(),
                            db::OpenMode::ReadWriteCreate,
                            QStringLiteral("Migrator-songs"));
        db::Migrator::run(conn, QStringLiteral("songs"));
    }
    {
        db::Connection conn(db::DbPaths::appDbPath(),
                            db::OpenMode::ReadWriteCreate,
                            QStringLiteral("Migrator-app"));
        db::Migrator::run(conn, QStringLiteral("app"));
    }
}

}  // namespace crater
