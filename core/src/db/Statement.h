#pragma once

#include <QByteArray>
#include <QString>
#include <QStringView>
#include <QtGlobal>

struct sqlite3;
struct sqlite3_stmt;

namespace crater::db {

class Connection;

// RAII wrapper around sqlite3_stmt*.
//
// Created via Connection::prepare(); cannot be constructed directly.
// Bindings are 1-indexed (SQLite convention), columns are 0-indexed.
//
// Typical use:
//   auto stmt = conn.prepare(u"SELECT title FROM songs WHERE id = ?");
//   stmt.bind(1, songId);
//   while (stmt.step()) {
//       const auto title = stmt.columnText(0);
//   }
//
// WAL INVARIANT — reset single-row reads. A `while (step())` loop runs to
// SQLITE_DONE and releases the statement's read transaction. A single-row
// read does NOT:
//   stmt.reset(); stmt.bind(1, id);
//   if (stmt.step()) value = stmt.columnText(0);
//   stmt.reset();   // <-- REQUIRED
// Without that trailing reset(), the statement stays in the SQLITE_ROW state,
// holding an implicit read transaction open. Under WAL that pins the
// connection to a fixed snapshot, so the NEXT write on this connection fails
// with SQLITE_BUSY_SNAPSHOT (surfaced as SQLITE_BUSY 5 unless extended result
// codes are on) and keeps failing until the connection is torn down — i.e.
// until the app restarts. Reset-before-use is not enough; reset after too.
class Statement
{
public:
    Statement() = default;
    ~Statement();

    Statement(const Statement&) = delete;
    Statement& operator=(const Statement&) = delete;
    Statement(Statement&& other) noexcept;
    Statement& operator=(Statement&& other) noexcept;

    // Bind parameters (1-indexed). All throw crater::db::Error on failure.
    Statement& bind(int idx, qint64 v);
    Statement& bind(int idx, int v) { return bind(idx, static_cast<qint64>(v)); }
    Statement& bind(int idx, double v);
    Statement& bind(int idx, QStringView v);
    Statement& bind(int idx, const QByteArray& v);
    Statement& bindNull(int idx);

    // Execute one step. Returns true if a row is available, false on SQLITE_DONE.
    // Throws on any other result code.
    bool step();

    // Reset the statement for reuse. `clearBindings = true` also unbinds parameters.
    void reset(bool clearBindings = false);

    // Column accessors (0-indexed). Cheap — call only when needed.
    qint64     columnInt64(int idx) const noexcept;
    int        columnInt(int idx) const noexcept { return static_cast<int>(columnInt64(idx)); }
    double     columnDouble(int idx) const noexcept;
    QString    columnText(int idx) const;
    QByteArray columnBlob(int idx) const;
    bool       columnIsNull(int idx) const noexcept;

    int columnCount() const noexcept;

    bool isValid() const noexcept { return m_stmt != nullptr; }

private:
    friend class Connection;
    Statement(sqlite3_stmt* stmt, sqlite3* owner);

    [[noreturn]] void throwBind(int idx, int rc) const;

    sqlite3_stmt* m_stmt  = nullptr;
    sqlite3*      m_owner = nullptr;  // for error message extraction
};

}  // namespace crater::db
