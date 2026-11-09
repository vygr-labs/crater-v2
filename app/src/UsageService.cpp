#include "UsageService.h"

#include "crater/Version.h"

#include <QDebug>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocale>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QSettings>
#include <QSysInfo>
#include <QTimer>
#include <QUrl>
#include <QUuid>

namespace crater {

namespace {

// CRATER_USAGE_URL points a test build at a local copy of the website.
QUrl endpoint()
{
    const QByteArray env = qgetenv("CRATER_USAGE_URL");
    return QUrl(env.isEmpty() ? QStringLiteral("https://getcrater.org/api/usage")
                              : QString::fromUtf8(env));
}

// After the update check (20 s), well clear of startup.
constexpr int kStartupDelayMs = 45 * 1000;
// Soon after the switch goes on, so the operator isn't left wondering.
constexpr int kAfterOptInMs = 5 * 1000;
// Some booths leave Crater open for days.
constexpr int kDailyMs = 24 * 60 * 60 * 1000;
constexpr int kRequestTimeoutMs = 30 * 1000;

// The kinds the website keeps. Anything else is counted as "other", so a
// new kind of item never sends its own name before the server knows it.
QString eventFor(const QString& kind)
{
    static const QStringList known = {
        QStringLiteral("song"),  QStringLiteral("scripture"), QStringLiteral("image"),
        QStringLiteral("video"), QStringLiteral("pdf"),       QStringLiteral("presentation"),
    };
    return QStringLiteral("live.") + (known.contains(kind) ? kind : QStringLiteral("other"));
}

QString osName()
{
#if defined(Q_OS_WIN)
    return QStringLiteral("windows");
#elif defined(Q_OS_MACOS)
    return QStringLiteral("macos");
#else
    return QStringLiteral("linux");
#endif
}

QSettings store()
{
    // The same store as UpdateService and SettingsService.
    return QSettings{QStringLiteral("Voyager Labs"), QStringLiteral("Crater")};
}

}  // namespace

UsageService::UsageService(QObject* parent)
    : QObject(parent)
{
    QSettings s = store();
    m_share    = s.value(QStringLiteral("Usage/share"), false).toBool();
    m_id       = s.value(QStringLiteral("Usage/id")).toString();
    m_launches = s.value(QStringLiteral("Usage/launches"), 0).toInt();
    m_events   = s.value(QStringLiteral("Usage/events")).toMap();
    m_lastSent = s.value(QStringLiteral("Usage/lastSent")).toDateTime();
    // A switched-on store without an id (edited by hand, or half-written)
    // gets a fresh one rather than reporting under an empty id.
    if (m_share && QUuid::fromString(m_id).isNull()) {
        m_id = QUuid::createUuid().toString(QUuid::WithoutBraces);
        save();
    }
}

UsageService::~UsageService() = default;

void UsageService::save()
{
    QSettings s = store();
    s.setValue(QStringLiteral("Usage/share"), m_share);
    if (m_share) {
        s.setValue(QStringLiteral("Usage/id"), m_id);
        s.setValue(QStringLiteral("Usage/launches"), m_launches);
        s.setValue(QStringLiteral("Usage/events"), m_events);
    } else {
        s.remove(QStringLiteral("Usage/id"));
        s.remove(QStringLiteral("Usage/launches"));
        s.remove(QStringLiteral("Usage/events"));
    }
    if (m_lastSent.isValid()) s.setValue(QStringLiteral("Usage/lastSent"), m_lastSent);
    else                      s.remove(QStringLiteral("Usage/lastSent"));
}

void UsageService::setShare(bool on)
{
    if (on == m_share) return;
    m_share = on;
    if (on) {
        // A new id each time it's switched on, so turning it off and on
        // again starts a new, unconnected install on the server.
        m_id = QUuid::createUuid().toString(QUuid::WithoutBraces);
        m_launches = 1;   // this session
        m_events.clear();
        QTimer::singleShot(kAfterOptInMs, this, [this] { send(); });
    } else {
        // Off forgets everything not yet sent, and the id with it.
        m_id.clear();
        m_launches = 0;
        m_events.clear();
        m_lastSent = QDateTime();
        emit lastSentChanged();
    }
    save();
    emit shareChanged();
}

void UsageService::armStartupReport()
{
    if (!m_daily) {
        m_daily = new QTimer(this);
        m_daily->setInterval(kDailyMs);
        connect(m_daily, &QTimer::timeout, this, [this] { send(); });
        m_daily->start();
    }
    if (!m_share) return;
    ++m_launches;
    save();
    QTimer::singleShot(kStartupDelayMs, this, [this] { send(); });
}

void UsageService::noteWentLive(const QString& kind)
{
    if (!m_share) return;
    const QString key = eventFor(kind);
    m_events[key] = m_events.value(key).toInt() + 1;
    save();
}

void UsageService::send()
{
    if (!m_share || m_inFlight || m_id.isEmpty()) return;

    // What this report carries, so counts that arrive while it's in flight
    // stay for the next one.
    const QString     id       = m_id;
    const int         launches = m_launches;
    const QVariantMap events   = m_events;

    QJsonObject ev;
    for (auto it = events.cbegin(); it != events.cend(); ++it)
        ev.insert(it.key(), it.value().toInt());

    QJsonObject body;
    body.insert(QStringLiteral("id"),        id);
    body.insert(QStringLiteral("version"),   versionString());
    body.insert(QStringLiteral("os"),        osName());
    body.insert(QStringLiteral("osVersion"), QSysInfo::productVersion());
    body.insert(QStringLiteral("arch"),      QSysInfo::currentCpuArchitecture());
    body.insert(QStringLiteral("locale"),    QLocale::system().name());
    body.insert(QStringLiteral("launches"),  launches);
    body.insert(QStringLiteral("events"),    ev);

    QNetworkRequest req{endpoint()};
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    req.setHeader(QNetworkRequest::UserAgentHeader,
                  QStringLiteral("Crater/%1").arg(versionString()));
    req.setTransferTimeout(kRequestTimeoutMs);

    if (!m_net) m_net = new QNetworkAccessManager(this);
    m_inFlight = true;
    QNetworkReply* reply = m_net->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply, id, launches, events] {
        reply->deleteLater();
        m_inFlight = false;
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (reply->error() != QNetworkReply::NoError || status < 200 || status >= 300) {
            // Kept for the next launch. Nothing to tell the operator.
            qInfo().noquote() << "[usage] report not sent:" << status << reply->errorString();
            return;
        }
        // Switched off (or off and on) while the report was in flight: the
        // counts it carried are gone already.
        if (!m_share || m_id != id) return;
        m_launches = qMax(0, m_launches - launches);
        for (auto it = events.cbegin(); it != events.cend(); ++it) {
            const int left = m_events.value(it.key()).toInt() - it.value().toInt();
            if (left > 0) m_events[it.key()] = left;
            else          m_events.remove(it.key());
        }
        m_lastSent = QDateTime::currentDateTimeUtc();
        save();
        emit lastSentChanged();
    });
}

}  // namespace crater
