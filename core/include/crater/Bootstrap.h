#pragma once

#include <QString>

#include <stdexcept>

namespace crater {

// Thrown by runAllMigrations() when a database was upgraded by a newer
// Crater and this build can't safely read it. Every other failure is a
// crater::db::Error.
class NewerDataError : public std::runtime_error
{
public:
    NewerDataError(const QString& message, QString writtenBy)
        : std::runtime_error(message.toStdString())
        , m_writtenBy(std::move(writtenBy))
    {}

    // The Crater version that upgraded the data, or empty if unknown.
    const QString& writtenBy() const noexcept { return m_writtenBy; }

private:
    QString m_writtenBy;
};

// Runs all DB migrations for bibles.sqlite, songs.sqlite, app.sqlite. Creates
// any missing DB files via Connection's ReadWriteCreate mode. Idempotent —
// safe to call on every app start.
//
// Throws NewerDataError when the data is from a newer Crater, and
// crater::db::Error on any other failure (caller should log + abort).
//
// This is the public entry point for main.cpp so it doesn't need to include
// the private db/ headers.
void runAllMigrations();

}  // namespace crater
