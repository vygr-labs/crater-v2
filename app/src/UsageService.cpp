#include "UsageService.h"

#include "crater/Version.h"

#include <QDate>
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
constexpr int kSoonMs = 5 * 1000;
// Some booths leave Crater open for days.
constexpr int kDailyMs = 24 * 60 * 60 * 1000;
constexpr int kRequestTimeoutMs = 30 * 1000;
// Starts this close together are one sitting: a profile switch, a graphics
// fallback restart, or closing and reopening. Same gap as UpdateService.
constexpr qint64 kMinLaunchGapSecs = 10 * 60;

const QString kShare      = QStringLiteral("Usage/share");
const QString kId         = QStringLiteral("Usage/id");
const QString kDays       = QStringLiteral("Usage/days");
const QString kBatch      = QStringLiteral("Usage/batch");
const QString kLastSent   = QStringLiteral("Usage/lastSent");
const QString kLastLaunch = QStringLiteral("Usage/lastLaunch");

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

// The booth's own date, so a Sunday's numbers stay on Sunday however late
// they're sent.
QString today()
{
    return QDate::currentDate().toString(Qt::ISODate);
}

// days[today][event] += 1
void bump(QVariantMap& days, const QString& event)
{
    QVariantMap day = days.value(today()).toMap();
    day[event] = day.value(event).toInt() + 1;
    days[today()] = day;
}

QString newUuid()
{
    return QUuid::createUuid().toString(QUuid::WithoutBraces);
}

}  // namespace

UsageService::UsageService(QObject* parent)
    : QObject(parent)
{
    QSettings s = store();
    m_share      = s.value(kShare, false).toBool();
    m_id         = s.value(kId).toString();
    m_days       = s.value(kDays).toMap();
    m_batch      = s.value(kBatch).toMap();
    m_lastSent   = s.value(kLastSent).toDateTime();
    m_lastLaunch = s.value(kLastLaunch).toDateTime();
    // A switched-on store without an id (edited by hand, or half-written)
    // gets a fresh one rather than reporting under an empty id.
    if (m_share && QUuid::fromString(m_id).isNull()) {
        m_id = newUuid();
        m_batch.clear();
        saveAll();
    }
}

UsageService::~UsageService() = default;

void UsageService::saveAll()
{
    QSettings s = store();
    s.setValue(kShare, m_share);
    if (m_share) {
        s.setValue(kId, m_id);
        s.setValue(kDays, m_days);
        if (m_batch.isEmpty()) s.remove(kBatch);
        else                   s.setValue(kBatch, m_batch);
    } else {
        for (const QString& k : {kId, kDays, kBatch}) s.remove(k);
    }
    if (m_lastSent.isValid())   s.setValue(kLastSent, m_lastSent);
    else                        s.remove(kLastSent);
    if (m_lastLaunch.isValid()) s.setValue(kLastLaunch, m_lastLaunch);
    else                        s.remove(kLastLaunch);
}

void UsageService::startDaily()
{
    if (!m_daily) {
        m_daily = new QTimer(this);
        m_daily->setInterval(kDailyMs);
        connect(m_daily, &QTimer::timeout, this, [this] { send(); });
    }
    m_daily->start();
}

void UsageService::setShare(bool on)
{
    if (on == m_share) return;
    m_share = on;
    // Either way the old id and every count go. Turning it off forgets them,
    // and turning it back on starts a new, unconnected install.
    m_days.clear();
    m_batch.clear();
    m_lastSent = QDateTime();
    if (on) {
        m_id = newUuid();
        bump(m_days, QStringLiteral("launch"));   // this sitting
        m_lastLaunch = QDateTime::currentDateTimeUtc();
        startDaily();
        QTimer::singleShot(kSoonMs, this, [this] { send(); });
    } else {
        m_id.clear();
        m_lastLaunch = QDateTime();
        if (m_daily) m_daily->stop();
    }
    saveAll();
    emit shareChanged();
    emit lastSentChanged();
}

void UsageService::armStartupReport()
{
    if (!m_share) return;
    startDaily();
    const QDateTime now = QDateTime::currentDateTimeUtc();
    // A future timestamp (a clock fixed since) counts as long ago.
    const qint64 gap = m_lastLaunch.isValid() ? m_lastLaunch.secsTo(now) : -1;
    if (gap < 0 || gap >= kMinLaunchGapSecs) bump(m_days, QStringLiteral("launch"));
    m_lastLaunch = now;
    saveAll();
    QTimer::singleShot(kStartupDelayMs, this, [this] { send(); });
}

void UsageService::noteWentLive(const QVariantMap& item)
{
    if (!m_share) return;
    const QString kind = item.value(QStringLiteral("kind")).toString();
    if (kind.isEmpty()) return;   // goLive(null) blanks the screen

    // Crater re-projects the item already on screen when its theme changes
    // or a scripture layout setting flips (AppState.syncLiveTheme,
    // relayoutLiveScripture). Those aren't go-lives, and they keep the same
    // id and title. So the same item twice in a row counts once, which also
    // makes stepping into another slide of the live song one go-live.
    const QString key = kind + QLatin1Char('\n')
                      + item.value(QStringLiteral("id")).toString() + QLatin1Char('\n')
                      + item.value(QStringLiteral("title")).toString();
    if (key == m_lastLiveKey) return;
    m_lastLiveKey = key;

    bump(m_days, eventFor(kind));
    // Only the counts changed. This runs on every go-live.
    store().setValue(kDays, m_days);
}

void UsageService::send()
{
    if (!m_share || m_id.isEmpty()) return;
    if (m_inFlight) {
        // Picked up when the current one finishes (an opt-in during a
        // startup report, say).
        m_sendAgain = true;
        return;
    }

    // Freeze what's counted so far into a batch, unless an earlier batch
    // is still waiting to go. That one is resent as it was, under the same
    // report id, so the server can tell a retry from a new report.
    if (m_batch.isEmpty()) {
        m_batch = QVariantMap{
            {QStringLiteral("report"), newUuid()},
            {QStringLiteral("days"),   m_days},
        };
        m_days.clear();
        saveAll();
    }

    const QString     id     = m_id;
    const QString     report = m_batch.value(QStringLiteral("report")).toString();
    // {"2026-11-08": {"launch": 1, "live.song": 12}, ...}
    QJsonObject days;
    const QVariantMap batchDays = m_batch.value(QStringLiteral("days")).toMap();
    for (auto d = batchDays.cbegin(); d != batchDays.cend(); ++d) {
        QJsonObject ev;
        const QVariantMap counts = d.value().toMap();
        for (auto it = counts.cbegin(); it != counts.cend(); ++it)
            ev.insert(it.key(), it.value().toInt());
        days.insert(d.key(), ev);
    }

    QJsonObject body;
    body.insert(QStringLiteral("id"),        id);
    body.insert(QStringLiteral("report"),    report);
    body.insert(QStringLiteral("version"),   versionString());
    body.insert(QStringLiteral("os"),        osName());
    body.insert(QStringLiteral("osVersion"), QSysInfo::productVersion());
    body.insert(QStringLiteral("arch"),      QSysInfo::currentCpuArchitecture());
    body.insert(QStringLiteral("locale"),    QLocale::system().name());
    body.insert(QStringLiteral("days"),      days);

    QNetworkRequest req{endpoint()};
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    req.setHeader(QNetworkRequest::UserAgentHeader,
                  QStringLiteral("Crater/%1").arg(versionString()));
    req.setTransferTimeout(kRequestTimeoutMs);

    if (!m_net) m_net = new QNetworkAccessManager(this);
    m_inFlight = true;
    QNetworkReply* reply = m_net->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply, id, report] {
        reply->deleteLater();
        m_inFlight = false;

        // Switched off, or off and on, while this was in flight. setShare
        // already dropped the batch it carried.
        const bool stale = !m_share || m_id != id
                        || m_batch.value(QStringLiteral("report")).toString() != report;
        if (!stale) {
            const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            // 204 is what /api/usage answers when it has the report. Any
            // other success, like a page a redirect ended on, is not proof
            // the counts arrived, so the batch stays for another try.
            const bool ok = reply->error() == QNetworkReply::NoError && status == 204;
            // The server read it and said no. Sending the same batch again
            // gets the same answer, so it goes rather than piling up.
            const bool refused = status >= 400 && status < 500 && status != 408 && status != 429;
            if (ok || refused) {
                if (refused)
                    qInfo().noquote() << "[usage] report refused, dropped:" << status;
                m_batch.clear();
                if (ok) m_lastSent = QDateTime::currentDateTimeUtc();
                saveAll();
                if (ok) emit lastSentChanged();
            } else {
                // Kept for the next launch or the daily send.
                qInfo().noquote() << "[usage] report not sent:" << status << reply->errorString();
            }
        }

        if (m_sendAgain) {
            m_sendAgain = false;
            QTimer::singleShot(kSoonMs, this, [this] { send(); });
        }
    });
}

}  // namespace crater
