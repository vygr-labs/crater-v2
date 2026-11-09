#pragma once

#include <QDateTime>
#include <QObject>
#include <QString>
#include <QVariantMap>

QT_BEGIN_NAMESPACE
class QNetworkAccessManager;
class QTimer;
QT_END_NAMESPACE

namespace crater {

// Anonymous usage numbers, sent to getcrater.org/api/usage only after the
// operator switches on "Share anonymous usage" in Settings > Diagnostics.
// Off by default (ARCHITECTURE.md §11: no telemetry without explicit
// opt-in), and switching it off forgets the install id and anything not yet
// sent.
//
// What one report holds, and nothing else:
//   id         a random UUID made when sharing is switched on, tied to
//              nothing on the machine
//   version    Crater's version
//   os, osVersion, arch, locale
//              from QSysInfo and QLocale
//   launches   how many times Crater opened since the last report
//   events     how many times each kind of item went live since the last
//              report ("live.song": 12, "live.scripture": 40, ...)
//
// Never song titles, verses, file names, schedules or anything typed. The
// server derives a country from the request and keeps no IP address.
//
// Counts wait in QSettings until a report succeeds, so a church that opens
// Crater once a week still reports that week's numbers on its next launch.
//
// App layer for the same reason as UpdateService: Qt6::Network.
class UsageService : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool      share    READ share    WRITE setShare NOTIFY shareChanged)
    Q_PROPERTY(QDateTime lastSent READ lastSent NOTIFY lastSentChanged)

public:
    explicit UsageService(QObject* parent = nullptr);
    ~UsageService() override;

    bool      share() const { return m_share; }
    void      setShare(bool on);
    QDateTime lastSent() const { return m_lastSent; }

    // Called once from main() after the UI is up. Counts this launch and
    // sends a report a little later, when sharing is on.
    void armStartupReport();

    // ProjectionService::wentLive, with its contentKind.
    void noteWentLive(const QString& kind);

signals:
    void shareChanged();
    void lastSentChanged();

private:
    void send();
    void save();

    bool                   m_share = false;
    QString                m_id;
    int                    m_launches = 0;
    QVariantMap            m_events;       // "live.song" -> int
    QDateTime              m_lastSent;
    bool                   m_inFlight = false;
    QNetworkAccessManager* m_net = nullptr;
    QTimer*                m_daily = nullptr;
};

}  // namespace crater
