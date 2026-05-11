#pragma once

#include <QList>
#include <QMediaPlayer>
#include <QObject>
#include <QString>

QT_BEGIN_NAMESPACE
class QTimer;
class QVideoFrame;
class QVideoSink;
QT_END_NAMESPACE

namespace crater {

class MediaService;

// Off-screen video thumbnail generator.
//
// Lives in the app target (not crater-core) because it depends on
// Qt6::Multimedia — ARCHITECTURE.md §1: GUI/render code stays out of
// crater-core. Drives a single QMediaPlayer + QVideoSink sequentially
// through a queue of media ids: extracts the first valid frame near the
// 1-second mark, scales it to 320×180, saves to
// `<MediaService::thumbsDir()>/<id>.jpg`, and writes the probed duration
// back to MediaService via setVideoMeta().
//
// Idempotent: ensureForAllVideos() skips ids that already have a thumb
// file, so it's safe to call at startup AND after every import.
//
// Why a single player rather than a thread pool: QMediaPlayer instances
// are heavy (~5 MB resident on Windows, OS codec handles). One in-flight
// player is enough — a 30-item library finishes in well under a minute.
class VideoThumbnailer : public QObject
{
    Q_OBJECT

    // QML re-evaluation trigger. Bind through `const _ = readyCounter` in
    // a delegate's `source:` block to force a re-call of thumbnailPathFor
    // after each frame lands.
    Q_PROPERTY(int readyCounter READ readyCounter NOTIFY readyCounterChanged)

public:
    explicit VideoThumbnailer(MediaService* media, QObject* parent = nullptr);
    ~VideoThumbnailer() override;

    int readyCounter() const { return m_readyCounter; }

    // Returns the absolute path to the thumb file if it exists on disk,
    // otherwise empty. QML binds Image.source through this so missing
    // thumbs fall back gracefully to the icon placeholder.
    Q_INVOKABLE QString thumbnailPathFor(qint64 mediaId) const;

    // Scan MediaService.allMedia, queue any video without a thumb file.
    // Cheap to call repeatedly — already-thumbed videos are skipped.
    Q_INVOKABLE void ensureForAllVideos();

signals:
    void thumbnailReady(qint64 mediaId);
    void readyCounterChanged();

private slots:
    void onMediaStatus(QMediaPlayer::MediaStatus status);
    void onVideoFrame(const QVideoFrame& frame);
    void onTimeout();
    void onPlayerError(QMediaPlayer::Error error, const QString& errorString);

private:
    void processNext();
    void finishCurrent();

    MediaService* m_media   = nullptr;
    QMediaPlayer* m_player  = nullptr;
    QVideoSink*   m_sink    = nullptr;
    QTimer*       m_timeout = nullptr;

    QList<qint64> m_queue;
    qint64        m_currentId    = 0;
    bool          m_captured     = false;
    int           m_readyCounter = 0;
};

}  // namespace crater
