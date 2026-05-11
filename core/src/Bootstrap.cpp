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
    {
        db::Connection conn(db::DbPaths::biblesDbPath());
        db::Migrator::run(conn, QStringLiteral("bibles"));
    }
    {
        db::Connection conn(db::DbPaths::songsDbPath());
        db::Migrator::run(conn, QStringLiteral("songs"));
    }
    {
        db::Connection conn(db::DbPaths::appDbPath());
        db::Migrator::run(conn, QStringLiteral("app"));
    }
}

}  // namespace crater
