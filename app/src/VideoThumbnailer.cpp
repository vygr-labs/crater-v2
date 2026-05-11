#include "VideoThumbnailer.h"

#include "crater/MediaService.h"
#include "crater/value/MediaItem.h"

#include <QDebug>
#include <QDir>
#include <QFile>
#include <QImage>
#include <QMediaPlayer>
#include <QTimer>
#include <QUrl>
#include <QVideoFrame>
#include <QVideoSink>

namespace crater {

namespace {

// Per-item budget. Most codecs decode the first frame in < 200 ms; some
// hang indefinitely on broken containers (corrupt MKV index, exotic codec
// without a system handler). Give up after this and move on rather than
// stalling the whole queue.
constexpr int kPerItemTimeoutMs = 6000;

// Thumb dimensions — 16:9, large enough for the widest grid cell
// (cellWidth ~320 at 4 columns) at near-native crispness.
constexpr int kThumbW = 320;
constexpr int kThumbH = 180;

}  // namespace

VideoThumbnailer::VideoThumbnailer(MediaService* media, QObject* parent)
    : QObject(parent)
    , m_media(media)
{
    m_player  = new QMediaPlayer(this);
    m_sink    = new QVideoSink(this);
    m_timeout = new QTimer(this);

    m_player->setVideoSink(m_sink);
    // No QAudioOutput — we only want frames, not audio. Skipping this saves
    // an audio bus open per item and avoids a brief blip on the operator's
    // default output device during extraction.

    m_timeout->setSingleShot(true);
    m_timeout->setInterval(kPerItemTimeoutMs);

    connect(m_player,  &QMediaPlayer::mediaStatusChanged,
            this,      &VideoThumbnailer::onMediaStatus);
    connect(m_sink,    &QVideoSink::videoFrameChanged,
            this,      &VideoThumbnailer::onVideoFrame);
    connect(m_player,  &QMediaPlayer::errorOccurred,
            this,      &VideoThumbnailer::onPlayerError);
    connect(m_timeout, &QTimer::timeout,
            this,      &VideoThumbnailer::onTimeout);

    if (m_media) {
        QDir().mkpath(m_media->thumbsDir());
    }
}

VideoThumbnailer::~VideoThumbnailer() = default;

QString VideoThumbnailer::thumbnailPathFor(qint64 mediaId) const
{
    if (!m_media || mediaId <= 0) return {};
    const QString path = QDir(m_media->thumbsDir())
                             .filePath(QStringLiteral("%1.jpg").arg(mediaId));
    return QFile::exists(path) ? path : QString{};
}

void VideoThumbnailer::ensureForAllVideos()
{
    if (!m_media) return;
    const auto items = m_media->allMedia();
    const QDir   dir = QDir(m_media->thumbsDir());
    for (const MediaItem& m : items) {
        if (m.type != QStringLiteral("video")) continue;
        if (m.id == m_currentId)                continue;
        if (m_queue.contains(m.id))             continue;
        if (QFile::exists(dir.filePath(QStringLiteral("%1.jpg").arg(m.id))))
            continue;
        m_queue.append(m.id);
    }
    if (m_currentId == 0) processNext();
}

void VideoThumbnailer::processNext()
{
    if (m_queue.isEmpty()) {
        m_currentId = 0;
        return;
    }
    m_currentId = m_queue.takeFirst();
    m_captured  = false;

    const MediaItem item = m_media ? m_media->byId(m_currentId) : MediaItem{};
    if (item.id == 0 || item.type != QStringLiteral("video") || item.path.isEmpty()) {
        finishCurrent();
        return;
    }

    m_player->stop();
    m_player->setSource(QUrl::fromLocalFile(item.path));
    m_timeout->start();
    // play() is deferred until mediaStatusChanged() reaches LoadedMedia, so
    // a setPosition() is honored — issuing it before the codec is ready is
    // a documented no-op on some backends.
}

void VideoThumbnailer::onMediaStatus(QMediaPlayer::MediaStatus status)
{
    if (m_currentId == 0) return;

    if (status == QMediaPlayer::LoadedMedia
        || status == QMediaPlayer::BufferedMedia) {
        // Seek 1 s in to skip studio idents / fade-from-black. Tiny clips
        // get a 100 ms seek, sub-200 ms clips get the very first frame.
        const qint64 dur  = m_player->duration();
        const qint64 seek = (dur > 1100) ? 1000
                          : (dur >  200) ?  100
                                         :    0;
        m_player->setPosition(seek);
        m_player->play();
    } else if (status == QMediaPlayer::InvalidMedia
            || status == QMediaPlayer::NoMedia) {
        qWarning().noquote() << "VideoThumbnailer: invalid media for id"
                             << m_currentId;
        finishCurrent();
    }
}

void VideoThumbnailer::onVideoFrame(const QVideoFrame& frame)
{
    if (m_currentId == 0 || m_captured) return;
    if (!frame.isValid()) return;

    QImage img = frame.toImage();
    if (img.isNull()) return;

    // Scale to fill, then center-crop to 16:9 so every tile has the same
    // aspect regardless of the source (portrait phone clips, 4:3 archive
    // footage, etc.).
    const QImage scaled = img.scaled(kThumbW, kThumbH,
                                     Qt::KeepAspectRatioByExpanding,
                                     Qt::SmoothTransformation);
    const int sx = qMax(0, (scaled.width()  - kThumbW) / 2);
    const int sy = qMax(0, (scaled.height() - kThumbH) / 2);
    const QImage cropped = scaled.copy(sx, sy, kThumbW, kThumbH);

    const QString out = QDir(m_media->thumbsDir())
                            .filePath(QStringLiteral("%1.jpg").arg(m_currentId));
    if (!cropped.save(out, "JPG", /*quality=*/80)) {
        qWarning().noquote() << "VideoThumbnailer: failed to save" << out;
        finishCurrent();
        return;
    }

    m_captured = true;

    const qint64 duration = m_player->duration();
    if (m_media) m_media->setVideoMeta(m_currentId, duration);

    emit thumbnailReady(m_currentId);
    ++m_readyCounter;
    emit readyCounterChanged();

    finishCurrent();
}

void VideoThumbnailer::onTimeout()
{
    if (m_currentId == 0) return;
    qWarning().noquote() << "VideoThumbnailer: timeout extracting frame for id"
                         << m_currentId << "— moving on";
    finishCurrent();
}

void VideoThumbnailer::onPlayerError(QMediaPlayer::Error error,
                                     const QString& errorString)
{
    if (m_currentId == 0 || error == QMediaPlayer::NoError) return;
    qWarning().noquote() << "VideoThumbnailer: player error for id"
                         << m_currentId << "—" << errorString;
    finishCurrent();
}

void VideoThumbnailer::finishCurrent()
{
    m_timeout->stop();
    m_player->stop();
    m_player->setSource(QUrl{});
    m_currentId = 0;
    m_captured  = false;
    // Defer to the next event-loop tick so we don't recurse inside a player
    // signal — some backends call back synchronously into the slot stack.
    QTimer::singleShot(0, this, [this]() { processNext(); });
}

}  // namespace crater
