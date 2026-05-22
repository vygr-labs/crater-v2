#include "LogReportService.h"

#include <QCoreApplication>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QSysInfo>
#include <QUrl>

#include <utility>

namespace crater {

namespace {

// The voyagerlabs.tech serverless endpoint and its shared token. The token
// is NOT a real credential — it only keeps the public URL from being a
// trivial drive-by spam target — so shipping it inside the binary is
// acceptable. If it is ever abused, rotate it here AND in the Vercel
// project's CRATER_LOG_TOKEN env var (the two must match) and ship an update.
const QString kEndpoint =
    QStringLiteral("https://voyagerlabs.tech/api/crater-logs");
const QString kToken =
    QStringLiteral("OOvPA0wW07wyeMmy66oOX_AYUL4xL0qg");

// Upload at most the last 2 MB of the log. crater.log is append-only across
// every session, so the tail is the most recent — and most relevant —
// activity; capping it keeps the request small and well under both the
// endpoint's limit and Vercel's request-body cap.
constexpr qint64 kMaxTailBytes = 2 * 1024 * 1024;

}  // namespace

LogReportService::LogReportService(QString logPath, QObject* parent)
    : QObject(parent)
    , m_logPath(std::move(logPath))
{
}

LogReportService::~LogReportService() = default;

bool LogReportService::logAvailable() const
{
    const QFileInfo fi(m_logPath);
    return fi.exists() && fi.size() > 0;
}

void LogReportService::setStatus(Status s, const QString& error)
{
    if (m_status == s && m_lastError == error) return;
    m_status    = s;
    m_lastError = error;
    emit statusChanged();
}

void LogReportService::sendLogs(const QString& note)
{
    if (m_status == Sending) return;   // an upload is already in flight

    // ── Read the tail of the log ─────────────────────────────────────────
    QFile f(m_logPath);
    if (!f.open(QIODevice::ReadOnly)) {
        setStatus(Failed, tr("No log file was found to send."));
        return;
    }
    const qint64 size = f.size();
    if (size > kMaxTailBytes) {
        // Seek into the tail, then drop the (probably partial) first line so
        // the upload starts on a clean log entry.
        f.seek(size - kMaxTailBytes);
        f.readLine();
    }
    const QByteArray logData = f.readAll();
    f.close();
    if (logData.isEmpty()) {
        setStatus(Failed, tr("The log file is empty."));
        return;
    }

    // ── Build the JSON payload /api/crater-logs expects ──────────────────
    QJsonObject file;
    file[QStringLiteral("name")]       = QStringLiteral("crater.log");
    file[QStringLiteral("contentB64")] =
        QString::fromLatin1(logData.toBase64());

    QJsonObject body;
    body[QStringLiteral("token")]   = kToken;
    body[QStringLiteral("version")] = QCoreApplication::applicationVersion();
    body[QStringLiteral("os")]      = QSysInfo::prettyProductName();
    body[QStringLiteral("note")]    = note.trimmed();
    body[QStringLiteral("files")]   = QJsonArray{ file };

    // ── POST it ──────────────────────────────────────────────────────────
    if (!m_net) m_net = new QNetworkAccessManager(this);

    QNetworkRequest req{ QUrl(kEndpoint) };
    req.setHeader(QNetworkRequest::ContentTypeHeader,
                  QStringLiteral("application/json"));

    setStatus(Sending);
    QNetworkReply* reply =
        m_net->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));

    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        if (reply->error() == QNetworkReply::NoError) {
            setStatus(Sent);
            return;
        }
        // On an HTTP error the body still carries the route's { error: ... }
        // JSON — surface that when present, otherwise the transport error.
        QString msg;
        const QJsonObject obj =
            QJsonDocument::fromJson(reply->readAll()).object();
        if (obj.contains(QStringLiteral("error")))
            msg = obj.value(QStringLiteral("error")).toString();
        if (msg.isEmpty())
            msg = reply->errorString();
        setStatus(Failed, msg);
    });
}

}  // namespace crater
