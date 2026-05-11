#pragma once

#include <QString>
#include <stdexcept>
#include <utility>

namespace crater::db {

class Error : public std::runtime_error
{
public:
    explicit Error(QString msg, int sqliteCode = 0)
        : std::runtime_error(msg.toStdString())
        , m_msg(std::move(msg))
        , m_code(sqliteCode)
    {}

    const QString& message() const noexcept { return m_msg; }
    int sqliteCode() const noexcept { return m_code; }

private:
    QString m_msg;
    int     m_code;
};

}  // namespace crater::db
