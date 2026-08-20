#pragma once

#include <QCryptographicHash>
#include <QDateTime>
#include <QObject>
#include <QString>
#include <QUrl>

#include <memory>

QT_BEGIN_NAMESPACE
class QFile;
class QNetworkAccessManager;
class QNetworkReply;
QT_END_NAMESPACE

namespace crater {

// In-app updates: asks GitHub whether a newer Crater has been published,
// downloads the platform's installer, verifies its SHA-256, and hands it to
// the OS. See docs/auto-update.md for the whole design.
//
// Layer placement: the app target, not crater-core — same reason as
// LogReportService and NdiService. It needs QNetworkAccessManager
// (Qt6::Network, linked by the app) and QProcess to launch an installer,
// neither of which crater-core is allowed to pull in. The one piece that IS
// engine-shaped, version ordering, lives in crater-core as
// crater::compareVersions so the test suite can cover it headlessly.
//
// Three properties of the design are deliberate and load-bearing:
//
//   1. NOTHING INSTALLS ITSELF. The service checks in the background and
//      (only on request) downloads in the background, but the step that
//      closes Crater and runs an installer happens on an explicit operator
//      press, never on a timer. Crater drives a live projection in front of
//      a room; an updater that restarts the app mid-service is worse than
//      one that never runs at all.
//
//   2. THE SOURCE IS PINNED. The release feed URL is a compile-time
//      constant, and every URL taken from the response — including each
//      redirect hop — is checked against a host allow-list before a byte is
//      read. A release payload cannot redirect us somewhere else.
//
//   3. NO CHECKSUM, NO INSTALL. The download is verified against the
//      release's SHA256SUMS.txt (or the asset's own API-reported digest).
//      When a release publishes neither, the service refuses and sends the
//      operator to the release page rather than silently trusting the
//      bytes. Crater ships unsigned today, so this hash chain plus TLS is
//      the whole of the integrity story — degrading it quietly would make
//      the feature a code-execution vector rather than a convenience.
class UpdateService : public QObject
{
    Q_OBJECT

    Q_PROPERTY(State   state            READ state     NOTIFY stateChanged)
    Q_PROPERTY(QString lastError        READ lastError NOTIFY stateChanged)
    Q_PROPERTY(bool    busy             READ busy      NOTIFY stateChanged)

    // The build's own version, straight from CMake via crater::versionString().
    Q_PROPERTY(QString currentVersion   READ currentVersion   CONSTANT)

    // Populated once a check finds something newer; empty otherwise.
    Q_PROPERTY(QString availableVersion READ availableVersion NOTIFY stateChanged)
    Q_PROPERTY(QString releaseNotes     READ releaseNotes     NOTIFY stateChanged)
    Q_PROPERTY(QString releaseUrl       READ releaseUrl       NOTIFY stateChanged)
    Q_PROPERTY(qint64  downloadSize     READ downloadSize     NOTIFY stateChanged)

    Q_PROPERTY(qint64  receivedBytes    READ receivedBytes    NOTIFY progressChanged)
    Q_PROPERTY(qint64  totalBytes       READ totalBytes       NOTIFY progressChanged)
    // 0.0 - 1.0, or -1 when the server sent no content length.
    Q_PROPERTY(qreal   downloadProgress READ downloadProgress NOTIFY progressChanged)

    Q_PROPERTY(QDateTime lastChecked    READ lastChecked      NOTIFY lastCheckedChanged)

    // The version the operator chose to sit out. A check still runs and
    // still records lastChecked, but a match here reports UpToDate so the
    // UI stays quiet until the NEXT release supersedes it.
    Q_PROPERTY(QString skippedVersion   READ skippedVersion   NOTIFY skippedVersionChanged)

    // Check automatically, at most once a day, a short delay after launch.
    // Owned here rather than in SettingsService because it is the updater's
    // own policy knob and nothing else reads it; the Settings dialog binds
    // straight to this property the same way it binds to
    // BrowserCastService.listening.
    Q_PROPERTY(bool    autoCheck        READ autoCheck WRITE setAutoCheck NOTIFY autoCheckChanged)

    // How installUpdate() behaves on this platform, so the QML can label the
    // button honestly instead of promising a restart it cannot deliver:
    //   "run"         Windows — close Crater, run the installer, relaunch.
    //   "reveal"      macOS — open the .dmg and let the operator drag it
    //                 across. A running .app cannot replace itself without a
    //                 separate helper binary, and shipping one to save a drag
    //                 is not a trade worth making.
    //   "unsupported" no installer artifact is published for this platform.
    Q_PROPERTY(QString installMode      READ installMode      CONSTANT)

public:
    enum State {
        Idle,             // nothing attempted yet this session
        Checking,         // a release check is in flight
        UpToDate,         // the last check found nothing newer
        UpdateAvailable,  // a newer release exists; nothing downloaded yet
        Downloading,      // fetching the installer
        ReadyToInstall,   // downloaded AND checksum-verified
        Failed,           // see lastError
    };
    Q_ENUM(State)

    explicit UpdateService(QObject* parent = nullptr);
    ~UpdateService() override;

    State     state() const { return m_state; }
    QString   lastError() const { return m_lastError; }
    bool      busy() const { return m_state == Checking || m_state == Downloading; }
    QString   currentVersion() const;
    QString   availableVersion() const { return m_availableVersion; }
    QString   releaseNotes() const { return m_releaseNotes; }
    QString   releaseUrl() const { return m_releaseUrl; }
    qint64    downloadSize() const { return m_assetSize; }
    qint64    receivedBytes() const { return m_received; }
    qint64    totalBytes() const { return m_total; }
    qreal     downloadProgress() const;
    QDateTime lastChecked() const { return m_lastChecked; }
    QString   skippedVersion() const { return m_skippedVersion; }
    bool      autoCheck() const { return m_autoCheck; }
    void      setAutoCheck(bool on);
    QString   installMode() const;

    // Arms the once-a-day background check, honouring autoCheck and the
    // stored last-check time. Called from main.cpp once the UI is up; the
    // request itself is delayed so it never competes with startup I/O.
    // Cheap and safe to call when nothing is due — it just returns.
    void armStartupCheck();

    // Operator-initiated check. Runs regardless of autoCheck or how recently
    // the last one ran, and surfaces errors — the background check fails
    // silently, because an offline church hall should not raise a banner.
    Q_INVOKABLE void checkForUpdates();

    // Fetches + verifies the installer the last check found. No-op unless
    // the state is UpdateAvailable or Failed.
    Q_INVOKABLE void downloadUpdate();
    Q_INVOKABLE void cancelDownload();

    // Runs the verified installer (see installMode). On Windows this quits
    // Crater, so callers must confirm with the operator first.
    Q_INVOKABLE void installUpdate();

    Q_INVOKABLE void skipAvailableVersion();
    Q_INVOKABLE void clearSkippedVersion();
    Q_INVOKABLE void openReleasePage();

signals:
    void stateChanged();
    void progressChanged();
    void lastCheckedChanged();
    void skippedVersionChanged();
    void autoCheckChanged();

private:
    void runCheck(bool userInitiated);
    void onCheckReply(QNetworkReply* reply, bool userInitiated);
    void fetchChecksums();
    void startAssetDownload();
    void finishDownload();

    void setState(State s, const QString& error = QString());
    void fail(const QString& error);
    void resetDownload();
    void rememberCheckTime();

    QNetworkAccessManager* net();
    // `apiJson` adds the GitHub REST headers. Off for asset downloads,
    // which go through plain github.com URLs where they mean nothing.
    QNetworkReply*         get(const QUrl& url, bool apiJson = false);

    QString m_availableVersion;
    QString m_releaseNotes;
    QString m_releaseUrl;

    // The asset chosen for THIS platform, resolved during the check.
    QString m_assetName;
    QUrl    m_assetUrl;
    qint64  m_assetSize = 0;
    QUrl    m_checksumsUrl;
    QString m_expectedSha256;   // lowercase hex; empty means "not known yet"

    State   m_state = Idle;
    QString m_lastError;

    // Why a guard aborted the transfer, stashed before calling abort() so
    // the finished handler can tell "the operator pressed Cancel" (silent,
    // back to the offer) apart from "we stopped this on purpose" (an error
    // the operator needs to read).
    QString m_pendingError;

    qint64  m_received = 0;
    qint64  m_total    = 0;

    QDateTime m_lastChecked;
    QString   m_skippedVersion;
    bool      m_autoCheck = true;

    QString                m_downloadPath;
    std::unique_ptr<QFile> m_file;
    QCryptographicHash     m_hash{QCryptographicHash::Sha256};

    QNetworkAccessManager* m_net   = nullptr;
    QNetworkReply*         m_reply = nullptr;
};

}  // namespace crater
