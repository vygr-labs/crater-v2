#pragma once

namespace crater::db {

class Connection;

// RAII transaction guard.
//
//   crater::db::Transaction tx(conn);
//   // ... do work; throws here roll back automatically ...
//   tx.commit();
//
// If commit() is not called before the destructor runs (e.g. an exception
// unwound the stack), the destructor issues ROLLBACK. Destructor swallows
// rollback errors — destructors must not throw.
class Transaction
{
public:
    explicit Transaction(Connection& c);
    ~Transaction();

    Transaction(const Transaction&) = delete;
    Transaction& operator=(const Transaction&) = delete;
    Transaction(Transaction&&) = delete;
    Transaction& operator=(Transaction&&) = delete;

    // Commit the transaction. Subsequent calls are no-ops.
    void commit();

private:
    Connection* m_conn       = nullptr;
    bool        m_committed  = false;
};

}  // namespace crater::db
