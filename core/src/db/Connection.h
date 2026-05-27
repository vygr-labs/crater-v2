#pragma once

#include <QString>
#include <QStringView>
#include <QtGlobal>

#include <atomic>

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
//
// `label` is a human-readable identifier used by the SQLITE_BUSY diagnostic and
// the COMMIT/ROLLBACK trace lines. Each service passes its own name when
// constructing its Connection ("ThemeService", "MediaService", etc.). Empty
// label falls back to the DB path in the diagnostic — fine for transient
// importer connections, but persistent service connections should always
// supply one so the BUSY trace can identify the lock holder by service name.
class Connection
{
public:
    explicit Connection(QStringView path,
                        OpenMode    mode  = OpenMode::ReadWriteCreate,
                        QStringView label = {});
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

    const QString& path()  const noexcept { return m_path; }
    const QString& label() const noexcept { return m_label; }

    // True when this connection is currently inside a transaction
    // (sqlite3_get_autocommit() == 0). Used by the SQLITE_BUSY diagnostic
    // to identify in-process lock holders.
    bool inTransaction() const noexcept;

    // Wall-clock millisecond timestamp of this connection's most recent
    // BEGIN. 0 when the connection has never started a transaction OR has
    // committed/rolled back its most recent one (cleared by the
    // commit/rollback hooks installed in the constructor).
    qint64 transactionStartedMs() const noexcept { return m_txnStartedMs.load(); }

    // Called by db::Transaction's constructor immediately after issuing
    // BEGIN. Records the start time for duration reporting in the BUSY
    // diagnostic. Exposed publicly so Transaction is the single place
    // that knows we just opened a write transaction — Statement::step
    // and exec() paths don't need to track this themselves because the
    // diagnostic only cares about *intentional* transactions, not the
    // micro-locks SQLite acquires inside single auto-committed statements.
    void markTransactionBegin() noexcept;

    // Internal escape hatch — used only by Statement to fetch error messages.
    sqlite3* raw() noexcept { return m_db; }

private:
    sqlite3* m_db = nullptr;
    QString  m_path;
    QString  m_label;
    std::atomic<qint64> m_txnStartedMs{0};

    // Friend access to the commit/rollback hook trampolines so they can
    // reset m_txnStartedMs without going through a public mutator.
    friend int  craterDbConnectionCommitHook  (void* userData);
    friend void craterDbConnectionRollbackHook(void* userData);
};

// Process-wide snapshot of every live Connection's transaction state.
// Returns a comma-separated string like:
//   "ThemeService(in-txn,3247ms), MediaService(idle), ScheduleService(idle)"
// Emitted as part of the SQLITE_BUSY diagnostic so the log identifies
// which service is holding the writer lock at failure time. Thread-safe.
QString dumpConnectionStates();

}  // namespace crater::db
