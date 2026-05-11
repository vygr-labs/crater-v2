#pragma once

#include <QString>
#include <QStringView>
#include <QtGlobal>

struct sqlite3;

namespace crater::db {

class Statement;

enum class OpenMode {
    ReadOnly,
    ReadWrite,
    ReadWriteCreate,
};

// RAII wrapper around a single sqlite3 connection.
//
// One connection is owned by exactly one thread (per ARCHITECTURE.md §3); we still
// open it with SQLITE_OPEN_FULLMUTEX as a safety net. Connections are non-copyable
// but movable so services can hold them by value.
class Connection
{
public:
    explicit Connection(QStringView path, OpenMode mode = OpenMode::ReadWriteCreate);
    ~Connection();

    Connection(const Connection&) = delete;
    Connection& operator=(const Connection&) = delete;
    Connection(Connection&& other) noexcept;
    Connection& operator=(Connection&& other) noexcept;

    // Prepares a statement; throws crater::db::Error on failure.
    Statement prepare(QStringView sql);

    // Executes one or more SQL statements (no bindings, no results). Used for
    // DDL, PRAGMAs, and multi-statement migration files.
    void exec(QStringView sql);

    qint64 lastInsertRowId() const noexcept;
    int    changes() const noexcept;

    // PRAGMA user_version helpers (used by Migrator).
    qint64 userVersion() const;
    void   setUserVersion(qint64 v);

    const QString& path() const noexcept { return m_path; }

    // Internal escape hatch — used only by Statement to fetch error messages.
    sqlite3* raw() noexcept { return m_db; }

private:
    sqlite3* m_db = nullptr;
    QString  m_path;
};

}  // namespace crater::db
