#include "db/Connection.h"

#include "db/Error.h"
#include "db/Statement.h"

#include <sqlite3.h>

#include <QDateTime>
#include <QDebug>
#include <QStringList>

#include <algorithm>
#include <mutex>
#include <utility>
#include <vector>

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

// Process-wide registry of live Connection objects. Mutated only on
// Connection construction / destruction / move; iterated by the SQLITE_BUSY
// diagnostic when it dumps lock-holder state. A std::mutex is sufficient —
// the registry is small (~5-10 entries on a running app), and the dump
// path is rare (only fires on BUSY).
std::mutex             g_registryMutex;
std::vector<Connection*> g_registry;

void registerConnection(Connection* c)
{
    std::lock_guard<std::mutex> lock(g_registryMutex);
    g_registry.push_back(c);
}

void unregisterConnection(Connection* c)
{
    std::lock_guard<std::mutex> lock(g_registryMutex);
    g_registry.erase(std::remove(g_registry.begin(), g_registry.end(), c),
                     g_registry.end());
}

// Returns the connection's display name for diagnostic output —
// service-supplied label if present, else the DB filename basename
// (importer / migrator connections that don't supply a label still
// produce something readable in the trace).
QString displayName(const Connection* c)
{
    if (!c) return QStringLiteral("(null)");
    if (!c->label().isEmpty()) return c->label();
    const QString& p = c->path();
    const int slash = qMax(p.lastIndexOf('/'), p.lastIndexOf('\\'));
    return slash >= 0 ? p.mid(slash + 1) : p;
}

}  // namespace

// ── Commit / rollback hook trampolines ────────────────────────────────────
// SQLite calls these from inside its own COMMIT / ROLLBACK code paths,
// passing back the `this` pointer we registered at hook install time. We
// emit a one-line log per transaction completion (with duration when known)
// and clear the BEGIN timestamp so subsequent transactions on the same
// connection start fresh.
//
// Defined at namespace scope (not `static`) so they can be declared as
// friends in Connection.h without exposing m_txnStartedMs publicly.

int craterDbConnectionCommitHook(void* userData)
{
    auto* self = static_cast<Connection*>(userData);
    if (!self) return 0;
    const qint64 began = self->m_txnStartedMs.load();
    const QString name = displayName(self);
    if (began > 0) {
        const qint64 dur = QDateTime::currentMSecsSinceEpoch() - began;
        qInfo().noquote() << QStringLiteral("[%1] COMMIT (%2 ms)").arg(name).arg(dur);
    } else {
        // Auto-commit single-statement write — not a tracked transaction.
        // We still log so the trace covers every write end-to-end; the
        // "(auto)" suffix disambiguates from BEGIN-COMMIT cycles.
        qInfo().noquote() << QStringLiteral("[%1] COMMIT (auto)").arg(name);
    }
    self->m_txnStartedMs.store(0);
    return 0;  // 0 = allow commit; non-zero would abort
}

void craterDbConnectionRollbackHook(void* userData)
{
    auto* self = static_cast<Connection*>(userData);
    if (!self) return;
    const QString name = displayName(self);
    const qint64 began = self->m_txnStartedMs.load();
    if (began > 0) {
        const qint64 dur = QDateTime::currentMSecsSinceEpoch() - began;
        qWarning().noquote()
            << QStringLiteral("[%1] ROLLBACK (%2 ms)").arg(name).arg(dur);
    } else {
        qWarning().noquote() << QStringLiteral("[%1] ROLLBACK").arg(name);
    }
    self->m_txnStartedMs.store(0);
}

// ── Connection ───────────────────────────────────────────────────────────

Connection::Connection(QStringView path, OpenMode mode, QStringView label)
    : m_path(path.toString())
    , m_label(label.toString())
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

    // Install per-connection commit/rollback hooks so every transaction
    // boundary lands in the log with this connection's label. Hooks receive
    // `this` as the userData pointer; trampolines route into the trace
    // emitters above.
    sqlite3_commit_hook  (m_db, &craterDbConnectionCommitHook,   this);
    sqlite3_rollback_hook(m_db, &craterDbConnectionRollbackHook, this);

    registerConnection(this);
}

Connection::~Connection()
{
    if (m_db) {
        // Diagnostic-on-destruction: if this connection dies mid-transaction,
        // log it loudly. That's almost certainly a missing tx.commit() or an
        // exception escape — exactly the bug class the BUSY hunt is looking
        // for, caught at a different layer.
        if (sqlite3_get_autocommit(m_db) == 0) {
            qWarning().noquote()
                << QStringLiteral("[%1] connection destroyed mid-transaction "
                                  "— rolling back implicitly").arg(displayName(this));
        }
        unregisterConnection(this);
        // sqlite3_close_v2 is safe even with outstanding prepared statements
        // (it defers cleanup), unlike sqlite3_close which would error.
        sqlite3_close_v2(m_db);
        m_db = nullptr;
    }
}

Connection::Connection(Connection&& other) noexcept
    : m_db(std::exchange(other.m_db, nullptr))
    , m_path(std::move(other.m_path))
    , m_label(std::move(other.m_label))
    , m_txnStartedMs(other.m_txnStartedMs.exchange(0))
{
    if (m_db) {
        // Re-point the hooks at our new `this`; the moved-from object is
        // about to be dropped from the registry.
        sqlite3_commit_hook  (m_db, &craterDbConnectionCommitHook,   this);
        sqlite3_rollback_hook(m_db, &craterDbConnectionRollbackHook, this);
        unregisterConnection(&other);
        registerConnection(this);
    }
}

Connection& Connection::operator=(Connection&& other) noexcept
{
    if (this != &other) {
        if (m_db) {
            unregisterConnection(this);
            sqlite3_close_v2(m_db);
        }
        m_db   = std::exchange(other.m_db, nullptr);
        m_path = std::move(other.m_path);
        m_label = std::move(other.m_label);
        m_txnStartedMs.store(other.m_txnStartedMs.exchange(0));
        if (m_db) {
            sqlite3_commit_hook  (m_db, &craterDbConnectionCommitHook,   this);
            sqlite3_rollback_hook(m_db, &craterDbConnectionRollbackHook, this);
            unregisterConnection(&other);
            registerConnection(this);
        }
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

bool Connection::inTransaction() const noexcept
{
    // sqlite3_get_autocommit returns non-zero when autocommit is ON
    // (no transaction). Inverted result is "we're inside one."
    return m_db && sqlite3_get_autocommit(m_db) == 0;
}

void Connection::markTransactionBegin() noexcept
{
    m_txnStartedMs.store(QDateTime::currentMSecsSinceEpoch());
}

// ── Process-wide diagnostic ──────────────────────────────────────────────

QString dumpConnectionStates()
{
    std::lock_guard<std::mutex> lock(g_registryMutex);
    if (g_registry.empty()) return QStringLiteral("(no connections)");

    QStringList parts;
    parts.reserve(static_cast<int>(g_registry.size()));
    const qint64 now = QDateTime::currentMSecsSinceEpoch();

    for (auto* c : g_registry) {
        if (!c) continue;
        const QString name = displayName(c);
        if (c->inTransaction()) {
            const qint64 began = c->transactionStartedMs();
            if (began > 0) {
                parts << QStringLiteral("%1(in-txn,%2ms)").arg(name).arg(now - began);
            } else {
                // In a transaction but markTransactionBegin wasn't called —
                // implicit transaction from a multi-step write, or
                // SQLite's internal state. Still flag it.
                parts << QStringLiteral("%1(in-txn,untracked)").arg(name);
            }
        } else {
            parts << QStringLiteral("%1(idle)").arg(name);
        }
    }
    return parts.join(QStringLiteral(", "));
}

}  // namespace crater::db
