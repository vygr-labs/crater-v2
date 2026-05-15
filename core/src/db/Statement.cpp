#include "db/Statement.h"

#include "db/Error.h"

#include <sqlite3.h>

#include <QCoreApplication>
#include <QDebug>
#include <QFileInfo>

#include <atomic>
#include <utility>

namespace crater::db {

namespace {

// Process-wide count of in-flight Statement::step() calls. Bumped on entry,
// decremented on exit. Used only by the SQLITE_BUSY diagnostic below — if
// step() fails with BUSY and this counter is == 1 at that moment, the lock
// holder is OUTSIDE this process (another Crater instance, antivirus, sync
// tool). If > 1, an in-process worker thread is mid-step on a different
// connection. That two-way split is the cheapest signal for narrowing the
// hunt for a writer that takes more than the configured busy_timeout.
std::atomic<int> g_activeSteps{0};

}  // namespace

Statement::Statement(sqlite3_stmt* stmt, sqlite3* owner)
    : m_stmt(stmt), m_owner(owner)
{}

Statement::~Statement()
{
    if (m_stmt) {
        sqlite3_finalize(m_stmt);
        m_stmt = nullptr;
    }
}

Statement::Statement(Statement&& other) noexcept
    : m_stmt(std::exchange(other.m_stmt, nullptr))
    , m_owner(std::exchange(other.m_owner, nullptr))
{}

Statement& Statement::operator=(Statement&& other) noexcept
{
    if (this != &other) {
        if (m_stmt) sqlite3_finalize(m_stmt);
        m_stmt  = std::exchange(other.m_stmt, nullptr);
        m_owner = std::exchange(other.m_owner, nullptr);
    }
    return *this;
}

void Statement::throwBind(int idx, int rc) const
{
    const QString err = m_owner
        ? QString::fromUtf8(sqlite3_errmsg(m_owner))
        : QStringLiteral("(no connection)");
    throw Error(QStringLiteral("bind(%1) failed (%2): %3").arg(idx).arg(rc).arg(err), rc);
}

Statement& Statement::bind(int idx, qint64 v)
{
    const int rc = sqlite3_bind_int64(m_stmt, idx, v);
    if (rc != SQLITE_OK) throwBind(idx, rc);
    return *this;
}

Statement& Statement::bind(int idx, double v)
{
    const int rc = sqlite3_bind_double(m_stmt, idx, v);
    if (rc != SQLITE_OK) throwBind(idx, rc);
    return *this;
}

Statement& Statement::bind(int idx, QStringView v)
{
    const QByteArray utf8 = v.toString().toUtf8();
    // SQLITE_TRANSIENT: sqlite copies the string immediately, so utf8's lifetime
    // ending here is safe. Costs one allocation per bind — acceptable.
    const int rc = sqlite3_bind_text(m_stmt, idx, utf8.constData(), utf8.size(), SQLITE_TRANSIENT);
    if (rc != SQLITE_OK) throwBind(idx, rc);
    return *this;
}

Statement& Statement::bind(int idx, const QByteArray& v)
{
    const int rc = sqlite3_bind_blob(m_stmt, idx, v.constData(), v.size(), SQLITE_TRANSIENT);
    if (rc != SQLITE_OK) throwBind(idx, rc);
    return *this;
}

Statement& Statement::bindNull(int idx)
{
    const int rc = sqlite3_bind_null(m_stmt, idx);
    if (rc != SQLITE_OK) throwBind(idx, rc);
    return *this;
}

bool Statement::step()
{
    // RAII counter bump — see g_activeSteps comment for rationale. We use a
    // local struct rather than QScopeGuard to keep the dependency surface in
    // this TU minimal (no QtCore guard helper).
    struct ActiveGuard {
        ActiveGuard()  { g_activeSteps.fetch_add(1, std::memory_order_acq_rel); }
        ~ActiveGuard() { g_activeSteps.fetch_sub(1, std::memory_order_acq_rel); }
    } activeGuard;

    const int rc = sqlite3_step(m_stmt);
    if (rc == SQLITE_ROW)  return true;
    if (rc == SQLITE_DONE) return false;

    const QString err = m_owner
        ? QString::fromUtf8(sqlite3_errmsg(m_owner))
        : QStringLiteral("(no connection)");

    // BUSY-specific diagnostic. Reaches this branch only after SQLite's
    // internal busy_handler exhausted PRAGMA busy_timeout (5 s as of the
    // current Connection.cpp). The single line below captures the four
    // facts that disambiguate the lock holder:
    //   • pid           — to compare against running Crater processes
    //   • concurrent    — in-process step()s active right now (minus self)
    //   • wal           — WAL file size; a huge WAL suggests checkpoint
    //                     contention rather than a held writer
    //   • sql           — the statement that gave up
    // If concurrent == 0 at BUSY time, the holder is outside this process.
    if (rc == SQLITE_BUSY && m_owner) {
        const char* dbName = sqlite3_db_filename(m_owner, "main");
        const QString dbPath = dbName ? QString::fromUtf8(dbName) : QString();
        const QString walPath = dbPath.isEmpty() ? QString()
                                                 : dbPath + QStringLiteral("-wal");
        const qint64 walSize = walPath.isEmpty() ? -1 : QFileInfo(walPath).size();
        const char* sqlText = sqlite3_sql(m_stmt);
        const int concurrent = g_activeSteps.load(std::memory_order_acquire) - 1;

        qWarning().noquote()
            << "SQLITE_BUSY diagnostic:"
            << "pid=" << QCoreApplication::applicationPid()
            << "concurrent=" << concurrent
            << "wal=" << walSize
            << "db=" << dbPath
            << "sql=" << (sqlText ? QString::fromUtf8(sqlText) : QStringLiteral("(no sql)"));
    }

    throw Error(QStringLiteral("step failed (%1): %2").arg(rc).arg(err), rc);
}

void Statement::reset(bool clearBindings)
{
    sqlite3_reset(m_stmt);
    if (clearBindings) sqlite3_clear_bindings(m_stmt);
}

qint64 Statement::columnInt64(int idx) const noexcept
{
    return sqlite3_column_int64(m_stmt, idx);
}

double Statement::columnDouble(int idx) const noexcept
{
    return sqlite3_column_double(m_stmt, idx);
}

QString Statement::columnText(int idx) const
{
    const unsigned char* p = sqlite3_column_text(m_stmt, idx);
    if (!p) return {};
    const int n = sqlite3_column_bytes(m_stmt, idx);
    return QString::fromUtf8(reinterpret_cast<const char*>(p), n);
}

QByteArray Statement::columnBlob(int idx) const
{
    const void* p = sqlite3_column_blob(m_stmt, idx);
    if (!p) return {};
    const int n = sqlite3_column_bytes(m_stmt, idx);
    return QByteArray(reinterpret_cast<const char*>(p), n);
}

bool Statement::columnIsNull(int idx) const noexcept
{
    return sqlite3_column_type(m_stmt, idx) == SQLITE_NULL;
}

int Statement::columnCount() const noexcept
{
    return sqlite3_column_count(m_stmt);
}

}  // namespace crater::db
