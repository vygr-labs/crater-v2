#include "db/Migrator.h"

#include "crater/Version.h"

#include "db/Connection.h"
#include "db/Error.h"
#include "db/Statement.h"
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
    bool    readableByOlder = false;   // carries the marker line
};

const QString kReadableMarker = QStringLiteral("-- @readable-by-older-versions");

std::optional<std::pair<qint64, QString>> parseMigrationName(const QString& fileName)
{
    // V<digits>__<description>.sql
    static const QRegularExpression re(QStringLiteral("^V(\\d+)__(.+)\\.sql$"));
    const auto m = re.match(fileName);
    if (!m.hasMatch()) return std::nullopt;
    return std::pair{ m.captured(1).toLongLong(), m.captured(2) };
}

QString readResource(const QString& path);

bool hasReadableMarker(const QString& sql)
{
    for (QStringView line : QStringView(sql).split(u'\n')) {
        if (line.trimmed() == kReadableMarker) return true;
    }
    return false;
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
            out.append({ parsed->first, file, parsed->second,
                         hasReadableMarker(readResource(file)) });
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

// The oldest schema version that can read a DB at `version`: the newest
// migration up to it that older builds can't read.
qint64 oldestReader(const QList<MigrationFile>& migrations, qint64 version)
{
    qint64 oldest = 0;
    for (const auto& mig : migrations) {
        if (mig.version > version) break;
        if (!mig.readableByOlder) oldest = mig.version;
    }
    return oldest;
}

// crater_schema holds what an older build needs to judge this DB. It is
// written by the Migrator, not a migration, so every build that knows about
// it can read it whatever the DB's version.
std::optional<QString> readSchemaValue(Connection& conn, QStringView key)
{
    auto exists = conn.prepare(
        u"SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'crater_schema'");
    if (!exists.step()) return std::nullopt;
    exists.reset();

    auto sel = conn.prepare(u"SELECT value FROM crater_schema WHERE key = ?");
    sel.bind(1, key);
    if (!sel.step()) return std::nullopt;
    return sel.columnText(0);
}

void recordSchemaInfo(Connection& conn, qint64 oldestReaderVersion, bool migrated)
{
    const QString oldest  = QString::number(oldestReaderVersion);
    const auto    current = readSchemaValue(conn, u"oldest_reader_version");
    const auto    writer  = readSchemaValue(conn, u"written_by");
    // The writer is whoever last migrated the DB. A DB from before this
    // table existed gets this build, which knows its whole schema.
    const bool writeWriter = migrated || !writer;
    if (current == oldest && !writeWriter) return;

    Transaction tx(conn);
    conn.exec(u"CREATE TABLE IF NOT EXISTS crater_schema ("
              u"key TEXT PRIMARY KEY, value TEXT NOT NULL)");
    auto put = conn.prepare(u"INSERT OR REPLACE INTO crater_schema (key, value) VALUES (?, ?)");
    put.bind(1, u"oldest_reader_version").bind(2, oldest).step();
    if (writeWriter) {
        put.reset();
        put.bind(1, u"written_by").bind(2, versionString()).step();
    }
    tx.commit();
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
        recordSchemaInfo(conn, oldestReader(migrations, highest), false);
        qInfo().noquote() << "Migrator(" << dbName.toString()
                          << "): up to date at v" << current;
        return;
    }
    if (current > highest) {
        // A DB from before crater_schema existed records nothing, so only
        // its own version is known to read it.
        const qint64 oldest = readSchemaValue(conn, u"oldest_reader_version")
                                  .value_or(QString::number(current)).toLongLong();
        const QString writtenBy = readSchemaValue(conn, u"written_by").value_or(QString());
        if (oldest > 0 && oldest <= highest) {
            qInfo().noquote() << "Migrator(" << dbName.toString() << "): DB is at v"
                              << current << "from Crater" << writtenBy
                              << "but readable from v" << oldest
                              << "; opening it unchanged";
            return;
        }
        throw NewerSchemaError(QStringLiteral(
            "Migrator(%1): DB user_version (%2) is HIGHER than the highest available "
            "migration (v%3) and needs v%4 to read. It was upgraded by Crater %5; "
            "refusing to open.")
            .arg(dbName.toString()).arg(current).arg(highest).arg(oldest)
            .arg(writtenBy.isEmpty() ? QStringLiteral("(unknown)") : writtenBy),
            writtenBy);
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

    recordSchemaInfo(conn, oldestReader(migrations, highest), true);
    qInfo().noquote() << "Migrator(" << dbName.toString() << "): migrated to v" << highest;
}

}  // namespace crater::db
