#include "db/Connection.h"

#include "db/Error.h"
#include "db/Statement.h"

#include <sqlite3.h>

#include <QDebug>
#include <utility>

namespace crater::db {

namespace {

int openFlags(OpenMode mode) noexcept
{
    switch (mode) {
        case OpenMode::ReadOnly:        return SQLITE_OPEN_READONLY;
        case OpenMode::ReadWrite:       return SQLITE_OPEN_READWRITE;
        case OpenMode::ReadWriteCreate: return SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE;
    }
    return SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE;
}

}  // namespace

Connection::Connection(QStringView path, OpenMode mode)
    : m_path(path.toString())
{
    const int flags = openFlags(mode) | SQLITE_OPEN_FULLMUTEX;
    const QByteArray utf8 = m_path.toUtf8();

    const int rc = sqlite3_open_v2(utf8.constData(), &m_db, flags, nullptr);
    if (rc != SQLITE_OK) {
        // sqlite3_open_v2 leaves m_db non-null even on failure so we can read the error.
        const QString err = m_db
            ? QString::fromUtf8(sqlite3_errmsg(m_db))
            : QStringLiteral("out of memory");
        sqlite3_close(m_db);
        m_db = nullptr;
        throw Error(QStringLiteral("sqlite3_open_v2(%1) failed: %2").arg(m_path, err), rc);
    }

    // Connection-level pragmas. WAL and synchronous are DB-level (persisted on
    // the file) — setting them requires write access. Skip those when opened
    // ReadOnly; the others are per-connection and always safe.
    try {
        if (mode != OpenMode::ReadOnly) {
            exec(QStringLiteral("PRAGMA journal_mode = WAL"));
            exec(QStringLiteral("PRAGMA synchronous = NORMAL"));  // pairs well with WAL
        }
        exec(QStringLiteral("PRAGMA foreign_keys = ON"));
        exec(QStringLiteral("PRAGMA busy_timeout = 5000"));       // wait up to 5s on lock contention
        exec(QStringLiteral("PRAGMA temp_store = MEMORY"));
    } catch (...) {
        sqlite3_close(m_db);
        m_db = nullptr;
        throw;
    }
}

Connection::~Connection()
{
    if (m_db) {
        // sqlite3_close_v2 is safe even with outstanding prepared statements
        // (it defers cleanup), unlike sqlite3_close which would error.
        sqlite3_close_v2(m_db);
        m_db = nullptr;
    }
}

Connection::Connection(Connection&& other) noexcept
    : m_db(std::exchange(other.m_db, nullptr))
    , m_path(std::move(other.m_path))
{}

Connection& Connection::operator=(Connection&& other) noexcept
{
    if (this != &other) {
        if (m_db) sqlite3_close_v2(m_db);
        m_db   = std::exchange(other.m_db, nullptr);
        m_path = std::move(other.m_path);
    }
    return *this;
}

Statement Connection::prepare(QStringView sql)
{
    const QByteArray utf8 = sql.toString().toUtf8();
    sqlite3_stmt* stmt = nullptr;
    // SQLITE_PREPARE_PERSISTENT hints the planner that this statement will be
    // reused (services cache prepared statements as members).
    const int rc = sqlite3_prepare_v3(m_db,
                                      utf8.constData(),
                                      utf8.size(),
                                      SQLITE_PREPARE_PERSISTENT,
                                      &stmt,
                                      nullptr);
    if (rc != SQLITE_OK) {
        const QString err = QString::fromUtf8(sqlite3_errmsg(m_db));
        throw Error(QStringLiteral("prepare failed (%1): %2\nSQL: %3")
                    .arg(rc).arg(err, sql.toString()),
                    rc);
    }
    return Statement(stmt, m_db);
}

void Connection::exec(QStringView sql)
{
    const QByteArray utf8 = sql.toString().toUtf8();
    char* errMsg = nullptr;
    const int rc = sqlite3_exec(m_db, utf8.constData(), nullptr, nullptr, &errMsg);
    if (rc != SQLITE_OK) {
        QString err = errMsg
            ? QString::fromUtf8(errMsg)
            : QString::fromUtf8(sqlite3_errmsg(m_db));
        sqlite3_free(errMsg);
        throw Error(QStringLiteral("exec failed (%1): %2\nSQL: %3")
                    .arg(rc).arg(err, sql.toString()),
                    rc);
    }
}

qint64 Connection::lastInsertRowId() const noexcept
{
    return sqlite3_last_insert_rowid(m_db);
}

int Connection::changes() const noexcept
{
    return sqlite3_changes(m_db);
}

qint64 Connection::userVersion() const
{
    sqlite3_stmt* stmt = nullptr;
    const int rc = sqlite3_prepare_v2(m_db, "PRAGMA user_version", -1, &stmt, nullptr);
    if (rc != SQLITE_OK) {
        throw Error(QStringLiteral("PRAGMA user_version prepare failed: %1")
                    .arg(QString::fromUtf8(sqlite3_errmsg(m_db))), rc);
    }
    qint64 v = 0;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        v = sqlite3_column_int64(stmt, 0);
    }
    sqlite3_finalize(stmt);
    return v;
}

void Connection::setUserVersion(qint64 v)
{
    // PRAGMA does not accept bound parameters; format directly.
    exec(QStringLiteral("PRAGMA user_version = %1").arg(v));
}

}  // namespace crater::db
