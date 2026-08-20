#include "UpdateService.h"

#include "crater/Checksums.h"
#include "crater/Version.h"

#include <QCoreApplication>
#include <QDebug>
#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProcess>
#include <QSettings>
#include <QStandardPaths>
#include <QTimer>

namespace crater {

namespace {

// The one place the update feed is named. A compile-time constant, so
// nothing in a downloaded payload can redirect the check itself.
//
// `/releases/latest` is also exactly the semantics we want: it skips drafts
// and pre-releases, and release.yml publishes a DRAFT. "An update exists"
// therefore means a human pressed Publish, not merely that CI went green.
const QString kReleaseApi =
    QStringLiteral("https://api.github.com/repos/vygr-labs/crater-v2/releases/latest");

const QString kReleasesPage =
    QStringLiteral("https://github.com/vygr-labs/crater-v2/releases/latest");

// Generated over every artifact by the release workflow's publish job and
// attached alongside them.
const QString kChecksumsName = QStringLiteral("SHA256SUMS.txt");

// Bounds. The installer is ~100 MB today; the cap exists so a malformed or
// hostile content-length cannot fill the operator's disk, not because the
// exact number matters.
constexpr qint64 kMaxDownloadBytes  = 512LL * 1024 * 1024;
constexpr qint64 kMaxChecksumBytes  = 64 * 1024;
constexpr qint64 kCheckIntervalSecs = 24 * 60 * 60;
constexpr int    kRequestTimeoutMs  = 30 * 1000;

// Long enough to be clear of the DB migrations, font registration and first
// QML load. Nothing about an update check is urgent, and startup on a cold
// cache is already the slowest thing Crater does.
constexpr int kStartupDelayMs = 20 * 1000;

// Hosts the updater will talk to. GitHub serves the API from api.github.com,
// links assets from github.com, and redirects the actual bytes to a
// *.githubusercontent.com object store — so the allow-list covers those and
// nothing else. Applied to the pinned URL, to every URL lifted out of the
// release payload, and to every redirect hop.
bool isTrustedUrl(const QUrl& url)
{
    if (!url.isValid()) return false;
    if (url.scheme() != QLatin1String("https")) return false;
    const QString host = url.host().toLower();
    return host == QLatin1String("api.github.com")
        || host == QLatin1String("github.com")
        || host.endsWith(QLatin1String(".githubusercontent.com"));
}

// The installer artifact release.yml attaches for this platform, matched by
// EXACT name rather than by scanning for "something .exe-shaped". The name
// is the one part of a release payload we can predict, so pinning it means
// an unexpected extra asset can never be picked up and run.
QString platformAssetName(const QString& version)
{
#if defined(Q_OS_WIN)
    return QStringLiteral("Crater-Setup-%1.exe").arg(version);
#elif defined(Q_OS_MACOS)
    return QStringLiteral("Crater-%1-macos.dmg").arg(version);
#else
    Q_UNUSED(version);
    return QString();
#endif
}

}  // namespace

UpdateService::UpdateService(QObject* parent)
    : QObject(parent)
{
    // Same organisation + application as SettingsService and OutputService,
    // so all of Crater's preferences live in one store. Keys are namespaced
    // under "Update/" so the tree stays self-documenting.
    QSettings settings{QStringLiteral("Voyager Labs"), QStringLiteral("Crater")};
    m_autoCheck      = settings.value(QStringLiteral("Update/autoCheck"), true).toBool();
    m_skippedVersion = settings.value(QStringLiteral("Update/skippedVersion")).toString();
    m_lastChecked    = settings.value(QStringLiteral("Update/lastChecked")).toDateTime();
}

UpdateService::~UpdateService()
{
    if (m_reply) {
        m_reply->disconnect(this);
        m_reply->abort();
        m_reply = nullptr;
    }
    // A partial file is left where it is rather than deleted. It is inert —
    // nothing runs an installer that has not passed verification — and the
    // next download truncates it anyway.
}

QString UpdateService::currentVersion() const
{
    return versionString();
}

QString UpdateService::installMode() const
{
#if defined(Q_OS_WIN)
    return QStringLiteral("run");
#elif defined(Q_OS_MACOS)
    return QStringLiteral("reveal");
#else
    return QStringLiteral("unsupported");
#endif
}

qreal UpdateService::downloadProgress() const
{
    if (m_total <= 0) return -1.0;
    return qBound(qreal(0.0), qreal(m_received) / qreal(m_total), qreal(1.0));
}

void UpdateService::setAutoCheck(bool on)
{
    if (m_autoCheck == on) return;
    m_autoCheck = on;
    QSettings{QStringLiteral("Voyager Labs"), QStringLiteral("Crater")}
        .setValue(QStringLiteral("Update/autoCheck"), on);
    emit autoCheckChanged();
}

// ── Checking ───────────────────────────────────────────────────────────

void UpdateService::armStartupCheck()
{
    if (!m_autoCheck) return;

    // A negative age means the stored timestamp is in the future — a clock
    // that was wrong when it was written, or has since been corrected. Treat
    // it as due rather than trusting it, or a single bad clock reading could
    // suppress every future check on that machine.
    if (m_lastChecked.isValid()) {
        const qint64 age = m_lastChecked.secsTo(QDateTime::currentDateTimeUtc());
        if (age >= 0 && age < kCheckIntervalSecs) return;
    }

    QTimer::singleShot(kStartupDelayMs, this, [this] { runCheck(false); });
}

void UpdateService::checkForUpdates()
{
    runCheck(true);
}

void UpdateService::runCheck(bool userInitiated)
{
    if (m_state == Checking || m_state == Downloading) return;

    QNetworkReply* reply = get(QUrl(kReleaseApi), /*apiJson=*/true);
    if (!reply) return;   // get() has already reported the refusal

    setState(Checking);
    connect(reply, &QNetworkReply::finished, this,
            [this, reply, userInitiated] { onCheckReply(reply, userInitiated); });
}

void UpdateService::onCheckReply(QNetworkReply* reply, bool userInitiated)
{
    reply->deleteLater();

    // Record the attempt either way. A machine that is offline every Sunday
    // should still back off to one attempt a day rather than retrying on
    // every launch.
    rememberCheckTime();

    if (reply->error() != QNetworkReply::NoError) {
        // A background check that cannot reach the network is not worth
        // showing anyone — being offline is the normal resting state of a
        // lot of church A/V machines, and a red banner every Sunday morning
        // trains the operator to ignore the one that matters.
        if (userInitiated)
            fail(m_pendingError.isEmpty()
                     ? tr("Could not reach the update server: %1").arg(reply->errorString())
                     : m_pendingError);
        else
            setState(Idle);
        return;
    }

    const QJsonObject release =
        QJsonDocument::fromJson(reply->readAll()).object();

    const QString tag = release.value(QStringLiteral("tag_name")).toString();
    if (tag.isEmpty()) {
        if (userInitiated)
            fail(tr("The update server sent a response Crater could not read."));
        else
            setState(Idle);
        return;
    }

    const QString version = tag.startsWith(QLatin1Char('v')) ? tag.mid(1) : tag;

    if (!isNewerVersion(tag, versionString())) {
        qInfo().noquote()
            << QStringLiteral("[update] up to date at %1 (latest release is %2)")
                   .arg(versionString(), tag);
        resetDownload();
        m_availableVersion.clear();
        m_releaseNotes.clear();
        m_assetUrl.clear();
        setState(UpToDate);
        return;
    }

    // Skipped — by this exact version, or by a newer one the operator has
    // already turned down. Record the check and stay quiet; the next release
    // to supersede the skip surfaces normally.
    if (!m_skippedVersion.isEmpty()
        && compareVersions(version, m_skippedVersion) <= 0) {
        m_availableVersion = version;
        m_releaseUrl       = release.value(QStringLiteral("html_url")).toString();
        setState(UpToDate);
        return;
    }

    m_availableVersion = version;
    m_releaseNotes     = release.value(QStringLiteral("body")).toString();
    m_releaseUrl       = release.value(QStringLiteral("html_url")).toString();

    m_assetName = platformAssetName(version);
    m_assetUrl.clear();
    m_assetSize = 0;
    m_checksumsUrl.clear();
    m_expectedSha256.clear();

    const QJsonArray assets = release.value(QStringLiteral("assets")).toArray();
    for (const QJsonValue& value : assets) {
        const QJsonObject asset = value.toObject();
        const QString     name  = asset.value(QStringLiteral("name")).toString();
        const QUrl        url(asset.value(QStringLiteral("browser_download_url")).toString());

        if (!isTrustedUrl(url)) continue;

        if (!m_assetName.isEmpty() && name == m_assetName) {
            m_assetUrl  = url;
            m_assetSize = qint64(asset.value(QStringLiteral("size")).toDouble());

            // GitHub reports "sha256:<hex>" on assets uploaded since 2025.
            // Kept only as a fallback: SHA256SUMS.txt is computed from the
            // artifacts inside our own release job, which is a shorter chain
            // of custody than trusting the API's own bookkeeping.
            const QString digest = asset.value(QStringLiteral("digest")).toString();
            if (digest.startsWith(QLatin1String("sha256:")))
                m_expectedSha256 = digest.mid(7).toLower();
        } else if (name == kChecksumsName) {
            m_checksumsUrl = url;
        }
    }

    // Note that a release with no artifact for this platform still counts as
    // available — it is; we simply cannot fetch it here. downloadUpdate()
    // says so plainly and the section offers the release page instead.
    qInfo().noquote()
        << QStringLiteral("[update] %1 -> %2 (%3)")
               .arg(versionString(), version,
                    m_assetUrl.isValid()
                        ? QStringLiteral("installer available")
                        : QStringLiteral("no installer for this platform"));
    setState(UpdateAvailable);
}

// ── Downloading ────────────────────────────────────────────────────────

void UpdateService::downloadUpdate()
{
    if (m_state == Downloading || m_state == Checking) return;
    if (m_availableVersion.isEmpty()) return;

    if (!m_assetUrl.isValid()) {
        fail(tr("This release has no installer for your platform. "
                "Open the release page to download it manually."));
        return;
    }
    if (m_assetSize > kMaxDownloadBytes) {
        fail(tr("The installer is unexpectedly large, so Crater will not "
                "download it. Open the release page to install it manually."));
        return;
    }

    // Prefer the release's own SHA256SUMS.txt over the API's per-asset
    // digest: it is produced from the artifacts in the release job, it
    // covers every platform's file in one fetch, and it exists on releases
    // whose assets predate the API's digest field.
    if (m_checksumsUrl.isValid()) {
        fetchChecksums();
        return;
    }
    if (!m_expectedSha256.isEmpty()) {
        startAssetDownload();
        return;
    }

    fail(tr("This release publishes no checksum, so Crater cannot verify the "
            "download. Open the release page to install it manually."));
}

void UpdateService::fetchChecksums()
{
    QNetworkReply* reply = get(m_checksumsUrl);
    if (!reply) return;

    m_reply    = reply;
    m_received = 0;
    m_total    = m_assetSize;
    setState(Downloading);
    emit progressChanged();

    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        if (m_reply == reply) m_reply = nullptr;
        reply->deleteLater();

        if (reply->error() == QNetworkReply::OperationCanceledError
            && m_pendingError.isEmpty()) {
            resetDownload();
            setState(UpdateAvailable);
            return;
        }

        if (reply->error() == QNetworkReply::NoError) {
            const QString sum =
                sha256ForName(reply->read(kMaxChecksumBytes), m_assetName);
            if (!sum.isEmpty()) m_expectedSha256 = sum;
        }

        // The per-asset digest, if the API supplied one, is still a valid
        // fallback here — a missing or unreadable SHA256SUMS.txt is not a
        // reason to give up when we already hold a digest for this file.
        if (m_expectedSha256.isEmpty()) {
            fail(tr("Could not read the checksum for this release, so the "
                    "download cannot be verified. Open the release page to "
                    "install it manually."));
            return;
        }

        startAssetDownload();
    });
}

void UpdateService::startAssetDownload()
{
    const QString root =
        QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
    const QString dirPath = root + QStringLiteral("/updates");
    if (root.isEmpty() || !QDir().mkpath(dirPath)) {
        fail(tr("Could not create a folder to download the update into."));
        return;
    }

    const QDir dir(dirPath);

    // Sweep anything left from an earlier version, so the cache never
    // accumulates installers nobody will run again.
    const QStringList existing = dir.entryList(QDir::Files);
    for (const QString& stale : existing)
        if (stale != m_assetName) QFile::remove(dir.filePath(stale));

    m_downloadPath = dir.filePath(m_assetName);

    // A verified copy from an earlier session is worth keeping: reopening
    // Crater should not re-download something the operator already has.
    if (QFileInfo::exists(m_downloadPath)) {
        QFile cached(m_downloadPath);
        bool  usable = false;
        if (cached.open(QIODevice::ReadOnly)) {
            QCryptographicHash hash(QCryptographicHash::Sha256);
            usable = hash.addData(&cached)
                     && QString::fromLatin1(hash.result().toHex()) == m_expectedSha256;
            const qint64 size = cached.size();
            cached.close();
            if (usable) {
                m_received = size;
                m_total    = size;
                emit progressChanged();
                setState(ReadyToInstall);
                return;
            }
        }
        QFile::remove(m_downloadPath);
    }

    m_file = std::make_unique<QFile>(m_downloadPath);
    if (!m_file->open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        m_file.reset();
        fail(tr("Could not write to the download folder."));
        return;
    }

    m_hash.reset();
    m_received = 0;
    m_total    = m_assetSize;

    QNetworkReply* reply = get(m_assetUrl);
    if (!reply) {
        resetDownload();
        return;
    }
    m_reply = reply;

    setState(Downloading);
    emit progressChanged();

    // Streamed to disk rather than buffered: the installer is ~100 MB and
    // QNetworkReply would otherwise hold all of it in memory before we ever
    // see it. Hashing the same chunks on the way past means verification
    // costs one pass, not a second read of the finished file.
    connect(reply, &QNetworkReply::readyRead, this, [this, reply] {
        const QByteArray chunk = reply->readAll();
        m_received += chunk.size();

        // Enforced against bytes actually received, not against the declared
        // content-length, so a server that lies about its size still stops
        // here rather than at "disk full".
        if (m_received > kMaxDownloadBytes) {
            m_pendingError = tr("The download grew past the size Crater will "
                                "accept and was stopped.");
            reply->abort();
            return;
        }

        m_hash.addData(chunk);
        if (m_file) m_file->write(chunk);
    });

    // Qt throttles this to roughly one emission per 100 ms, which is the
    // right cadence for a progress bar; m_received above stays authoritative
    // for the size guard.
    connect(reply, &QNetworkReply::downloadProgress, this,
            [this](qint64, qint64 total) {
                if (total > 0) m_total = total;
                emit progressChanged();
            });

    connect(reply, &QNetworkReply::finished, this, [this] { finishDownload(); });
}

void UpdateService::finishDownload()
{
    QNetworkReply* reply = m_reply;
    m_reply              = nullptr;
    if (!reply) return;
    reply->deleteLater();

    if (m_file) {
        m_file->close();
        m_file.reset();
    }

    if (reply->error() != QNetworkReply::NoError) {
        QFile::remove(m_downloadPath);
        m_downloadPath.clear();

        // A plain cancel is not a failure — the operator pressed Cancel, and
        // the honest thing to show is the offer they started from. A guard
        // that aborted the transfer leaves its reason in m_pendingError and
        // does surface as an error.
        if (reply->error() == QNetworkReply::OperationCanceledError
            && m_pendingError.isEmpty()) {
            resetDownload();
            setState(UpdateAvailable);
            return;
        }

        fail(m_pendingError.isEmpty()
                 ? tr("The download failed: %1").arg(reply->errorString())
                 : m_pendingError);
        return;
    }

    if (QString::fromLatin1(m_hash.result().toHex()) != m_expectedSha256) {
        // A truncated transfer and a substituted file are indistinguishable
        // from here, so both get the same treatment: delete it, and never
        // offer to run it.
        QFile::remove(m_downloadPath);
        m_downloadPath.clear();
        resetDownload();
        fail(tr("The downloaded installer did not match its checksum, so it "
                "was deleted. Try again, or install from the release page."));
        return;
    }

    m_received = m_total;
    emit progressChanged();
    setState(ReadyToInstall);
}

void UpdateService::cancelDownload()
{
    if (m_reply) m_reply->abort();   // the finished handlers do the cleanup
}

// ── Installing ─────────────────────────────────────────────────────────

void UpdateService::installUpdate()
{
    if (m_state != ReadyToInstall) return;
    if (m_downloadPath.isEmpty() || !QFileInfo::exists(m_downloadPath)) {
        fail(tr("The downloaded installer is no longer on disk."));
        return;
    }

#if defined(Q_OS_WIN)
    // /SILENT rather than /VERYSILENT: the operator still gets a progress
    // window, which is the difference between "the update is running" and
    // "nothing happened". /LAUNCH=1 is Crater's own parameter, read by
    // packaging/crater.iss, which brings the app back afterwards as the
    // logged-in user — setup itself runs elevated, and a child of an
    // elevated process would inherit that.
    const QStringList args{
        QStringLiteral("/SILENT"),
        QStringLiteral("/CLOSEAPPLICATIONS"),
        QStringLiteral("/NORESTART"),
        QStringLiteral("/LAUNCH=1"),
    };
    if (!QProcess::startDetached(m_downloadPath, args)) {
        fail(tr("Could not start the installer."));
        return;
    }

    // Quit on the next event-loop tick rather than from inside this call:
    // the installer has to replace crater.exe, and Inno's Restart Manager
    // pass has far less to do if we are already gone. The tick also lets the
    // QML that invoked this finish its own frame first.
    QTimer::singleShot(0, qApp, &QCoreApplication::quit);
#elif defined(Q_OS_MACOS)
    // Opening the .dmg mounts it and shows the volume; the operator drags
    // Crater across. See installMode() for why there is no self-replace.
    if (!QDesktopServices::openUrl(QUrl::fromLocalFile(m_downloadPath)))
        fail(tr("Could not open the downloaded disk image."));
#else
    fail(tr("Installing from inside Crater is not supported on this platform."));
#endif
}

// ── Skipping ───────────────────────────────────────────────────────────

void UpdateService::skipAvailableVersion()
{
    if (m_availableVersion.isEmpty()) return;

    m_skippedVersion = m_availableVersion;
    QSettings{QStringLiteral("Voyager Labs"), QStringLiteral("Crater")}
        .setValue(QStringLiteral("Update/skippedVersion"), m_skippedVersion);
    emit skippedVersionChanged();

    cancelDownload();
    resetDownload();

    // availableVersion deliberately survives so the section can still say
    // WHICH version was skipped and offer to undo it. The UI keys the offer
    // off `state`, not off availableVersion being set.
    setState(UpToDate);
}

void UpdateService::clearSkippedVersion()
{
    if (m_skippedVersion.isEmpty()) return;

    m_skippedVersion.clear();
    QSettings{QStringLiteral("Voyager Labs"), QStringLiteral("Crater")}
        .remove(QStringLiteral("Update/skippedVersion"));
    emit skippedVersionChanged();

    // Re-check straight away: un-skipping is only meaningful if the offer
    // comes back, and making the operator press Check again reads as a bug.
    runCheck(true);
}

void UpdateService::openReleasePage()
{
    const QUrl url = m_releaseUrl.isEmpty() ? QUrl(kReleasesPage)
                                            : QUrl(m_releaseUrl);
    if (isTrustedUrl(url)) QDesktopServices::openUrl(url);
}

// ── Plumbing ───────────────────────────────────────────────────────────

void UpdateService::setState(State s, const QString& error)
{
    if (m_state == s && m_lastError == error) return;
    m_state     = s;
    m_lastError = error;
    emit stateChanged();
}

void UpdateService::fail(const QString& error)
{
    qWarning().noquote() << "[update] failed:" << error;
    setState(Failed, error);
}

void UpdateService::resetDownload()
{
    if (m_file) {
        m_file->close();
        m_file.reset();
    }
    m_hash.reset();
    m_received = 0;
    m_total    = 0;
    emit progressChanged();
}

void UpdateService::rememberCheckTime()
{
    m_lastChecked = QDateTime::currentDateTimeUtc();
    QSettings{QStringLiteral("Voyager Labs"), QStringLiteral("Crater")}
        .setValue(QStringLiteral("Update/lastChecked"), m_lastChecked);
    emit lastCheckedChanged();
}

QNetworkAccessManager* UpdateService::net()
{
    if (!m_net) m_net = new QNetworkAccessManager(this);
    return m_net;
}

QNetworkReply* UpdateService::get(const QUrl& url, bool apiJson)
{
    m_pendingError.clear();

    if (!isTrustedUrl(url)) {
        fail(tr("Refused to contact an unexpected address."));
        return nullptr;
    }

    QNetworkRequest request{url};
    // GitHub rejects requests with no User-Agent outright.
    request.setHeader(QNetworkRequest::UserAgentHeader,
                      QStringLiteral("Crater/%1").arg(versionString()));
    if (apiJson) {
        request.setRawHeader("Accept", "application/vnd.github+json");
        request.setRawHeader("X-GitHub-Api-Version", "2022-11-28");
    }
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                         QNetworkRequest::NoLessSafeRedirectPolicy);
    request.setTransferTimeout(kRequestTimeoutMs);

    QNetworkReply* reply = net()->get(request);

    // Qt follows redirects for us, and this is where we get to veto one. An
    // asset URL legitimately hops github.com -> the object store; the hop
    // being guarded against is the one that leaves GitHub entirely.
    connect(reply, &QNetworkReply::redirected, reply,
            [this, reply](const QUrl& target) {
                if (isTrustedUrl(target)) return;
                m_pendingError = tr("The download was redirected to an "
                                    "unexpected address and was stopped.");
                reply->abort();
            });

    return reply;
}

}  // namespace crater
