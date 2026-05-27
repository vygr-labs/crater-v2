#include "db/Transaction.h"

#include "db/Connection.h"
#include "db/Error.h"

#include <QDebug>

namespace crater::db {

Transaction::Transaction(Connection& c)
    : m_conn(&c)
{
    m_conn->exec(QStringLiteral("BEGIN"));
    // Record begin time so the BUSY diagnostic and the commit-hook trace
    // can report transaction duration. Done here (not on the exec("BEGIN")
    // path) because db::Transaction is the single explicit boundary for
    // multi-statement writes — auto-committed single statements aren't
    // tracked, and that's intentional.
    m_conn->markTransactionBegin();
}

Transaction::~Transaction()
{
    if (m_conn && !m_committed) {
        try {
            m_conn->exec(QStringLiteral("ROLLBACK"));
        } catch (const Error& e) {
            // Destructors must not throw. Vanishingly rare; log and swallow.
            qWarning().noquote()
                << "crater::db::Transaction rollback failed:" << e.message();
        } catch (...) {
            qWarning() << "crater::db::Transaction rollback failed: unknown exception";
        }
    }
}

void Transaction::commit()
{
    if (!m_conn || m_committed) return;
    m_conn->exec(QStringLiteral("COMMIT"));
    m_committed = true;
}

}  // namespace crater::db
