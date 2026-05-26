#pragma once

#include <QObject>
#include <QString>

QT_BEGIN_NAMESPACE
class QNetworkAccessManager;
QT_END_NAMESPACE

namespace crater {

// Uploads the app's diagnostic log to the Voyager Labs endpoint so a user on
// any machine can hand the developers a repro trace with one click — no
// hunting through AppData, no manual email attachment.
//
// User-initiated ONLY. There is no automatic or background upload; the
// "Send logs" button in the Diagnostics settings section is the sole trigger
// (ARCHITECTURE.md §11 — no telemetry without explicit opt-in).
//
// Layer placement: the app target, not crater-core. It needs
// QNetworkAccessManager (Qt6::Network — linked by the app, not by core) and
// is wired to the crater.log file main.cpp owns. This mirrors NdiService and
// BrowserCastService, which sit app-side for the same kind of reason.
class LogReportService : public QObject
{
    Q_OBJECT
    Q_PROPERTY(Status  status       READ status       NOTIFY statusChanged)
    Q_PROPERTY(QString lastError    READ lastError    NOTIFY statusChanged)
    // True when a log file actually exists to send. Lets the UI disable the
    // button rather than offer an upload that is guaranteed to fail.
    Q_PROPERTY(bool    logAvailable READ logAvailable CONSTANT)

public:
    enum Status {
        Idle,       // nothing attempted yet this session
        Sending,    // an upload is in flight
        Sent,       // the last upload succeeded
        Failed,     // the last upload failed — see lastError
    };
    Q_ENUM(Status)

    // `logPath` is the crater.log file main.cpp logs to (the return value of
    // initLogging()), so the service reports exactly the file the user is
    // complaining about — in both the dev (repo/personal/) and installed
    // (AppData) layouts.
    explicit LogReportService(QString logPath, QObject* parent = nullptr);
    ~LogReportService() override;

    Status  status() const { return m_status; }
    QString lastError() const { return m_lastError; }
    bool    logAvailable() const;

    // Reads the tail of the log, packages it as JSON, and POSTs it to the
    // endpoint. `note` is optional free text the user can attach. Returns
    // immediately; the outcome arrives asynchronously via statusChanged().
    Q_INVOKABLE void sendLogs(const QString& note);

signals:
    void statusChanged();

private:
    void setStatus(Status s, const QString& error = QString());

    QString                m_logPath;
    Status                 m_status = Idle;
    QString                m_lastError;
    QNetworkAccessManager* m_net = nullptr;
};

}  // namespace crater
