#include "db/Statement.h"

#include "db/Error.h"

#include <sqlite3.h>

#include <utility>

namespace crater::db {

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
    const int rc = sqlite3_step(m_stmt);
    if (rc == SQLITE_ROW)  return true;
    if (rc == SQLITE_DONE) return false;

    const QString err = m_owner
        ? QString::fromUtf8(sqlite3_errmsg(m_owner))
        : QStringLiteral("(no connection)");
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
