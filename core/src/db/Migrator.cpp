#include "db/Migrator.h"

#include "db/Connection.h"
#include "db/Error.h"
#include "db/Transaction.h"

#include <QDebug>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>

#include <algorithm>
#include <optional>
#include <utility>

namespace crater::db {

namespace {

struct MigrationFile {
    qint64  version;
    QString resourcePath;   // ":/migrations/<dbName>/V001__init.sql"
    QString description;    // "init"
};

std::optional<std::pair<qint64, QString>> parseMigrationName(const QString& fileName)
{
    // V<digits>__<description>.sql
    static const QRegularExpression re(QStringLiteral("^V(\\d+)__(.+)\\.sql$"));
    const auto m = re.match(fileName);
    if (!m.hasMatch()) return std::nullopt;
    return std::pair{ m.captured(1).toLongLong(), m.captured(2) };
}

QList<MigrationFile> enumerateMigrations(QStringView dbName)
{
    QList<MigrationFile> out;
    const QString dir = QStringLiteral(":/migrations/%1").arg(dbName);

    QDirIterator it(dir,
                    QStringList{ QStringLiteral("V*.sql") },
                    QDir::Files);
    while (it.hasNext()) {
        const QString file = it.next();
        const auto parsed = parseMigrationName(QFileInfo(file).fileName());
        if (parsed) {
            out.append({ parsed->first, file, parsed->second });
        } else {
            qWarning().noquote() << "Migrator: ignoring malformed migration filename:" << file;
        }
    }

    std::sort(out.begin(), out.end(),
              [](const MigrationFile& a, const MigrationFile& b) {
                  return a.version < b.version;
              });

    // Reject duplicate versions — likely a copy-paste error in the migrations folder.
    for (int i = 1; i < out.size(); ++i) {
        if (out[i].version == out[i - 1].version) {
            throw Error(QStringLiteral(
                "Migrator(%1): duplicate migration version v%2 (%3 vs %4)")
                .arg(dbName.toString())
                .arg(out[i].version)
                .arg(out[i - 1].resourcePath, out[i].resourcePath));
        }
    }

    return out;
}

QString readResource(const QString& path)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) {
        throw Error(QStringLiteral("Migrator: could not open migration resource: %1").arg(path));
    }
    return QString::fromUtf8(f.readAll());
}

void backupIfPossible(const QString& dbPath, qint64 targetVersion)
{
    if (dbPath == QStringLiteral(":memory:")) return;
    if (!QFile::exists(dbPath)) return;  // first creation; nothing to back up

    QFileInfo info(dbPath);
    if (info.size() == 0) return;  // freshly opened empty file (Connection creates it)

    const QString backupPath = QStringLiteral("%1.backup-pre-v%2.sqlite")
                                   .arg(dbPath).arg(targetVersion);
    if (QFile::exists(backupPath)) QFile::remove(backupPath);

    if (QFile::copy(dbPath, backupPath)) {
        qInfo().noquote() << "Migrator: pre-migration backup written ->" << backupPath;
    } else {
        // Don't fail the migration on a backup failure; log loudly and proceed.
        qWarning().noquote() << "Migrator: could not back up" << dbPath
                             << "to" << backupPath << "— proceeding anyway";
    }
}

}  // namespace

void Migrator::run(Connection& conn, QStringView dbName)
{
    const auto migrations = enumerateMigrations(dbName);
    if (migrations.isEmpty()) {
        qInfo().noquote() << "Migrator(" << dbName.toString() << "): no migrations found";
        return;
    }

    const qint64 current = conn.userVersion();
    const qint64 highest = migrations.last().version;

    if (current == highest) {
        qInfo().noquote() << "Migrator(" << dbName.toString()
                          << "): up to date at v" << current;
        return;
    }
    if (current > highest) {
        throw Error(QStringLiteral(
            "Migrator(%1): DB user_version (%2) is HIGHER than the highest available "
            "migration (v%3). The user likely downgraded the app; refusing to open.")
            .arg(dbName.toString()).arg(current).arg(highest));
    }

    backupIfPossible(conn.path(), highest);

    for (const auto& mig : migrations) {
        if (mig.version <= current) continue;

        qInfo().noquote() << "Migrator(" << dbName.toString() << "): applying v"
                          << mig.version << "(" << mig.description << ")";

        const QString sql = readResource(mig.resourcePath);
        Transaction tx(conn);
        conn.exec(sql);
        conn.setUserVersion(mig.version);
        tx.commit();
    }

    qInfo().noquote() << "Migrator(" << dbName.toString() << "): migrated to v" << highest;
}

}  // namespace crater::db
