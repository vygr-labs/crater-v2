#pragma once

#include <QHash>
#include <QList>
#include <QObject>
#include <QPointer>
#include <QString>

QT_BEGIN_NAMESPACE
class QAudioOutput;
class QMediaPlayer;
class QVideoFrame;
class QVideoSink;
QT_END_NAMESPACE

namespace crater {

// Refcounted shared video-playback service.
//
// The Preview and Live mini-monitors both render media items, and when
// they happen to point at the same source URL — the common case once the
// operator has gone live — naïvely each instantiates its own QMediaPlayer
// decoding the same file. That doubles CPU/GPU/memory for no UX gain.
//
// This service holds one QMediaPlayer + QVideoSink per active source URL.
// Subscribers register their own VideoOutput-owned sink as an "output";
// the service relays each decoded frame from the primary sink into every
// registered output. QVideoFrame is implicitly shared, so the broadcast
// is a pointer copy — one decode feeds N presents.
//
// Why this shape (not VideoOutput.videoSink binding): in Qt 6 the
// VideoOutput's videoSink is read-only — it creates its own internally.
// Pushing frames into it via QVideoSink::setVideoFrame is the supported
// way to drive a VideoOutput from an external source.
//
// Lifecycle:
//   • acquire(url, wantsAudio) returns an opaque positive token. First
//     subscriber for a URL spins up the player + sink + audio bus.
//   • attachOutput(token, outSink) registers an output to receive frames.
//     If outSink is already attached elsewhere, it's moved (a single sink
//     never feeds frames from two players simultaneously).
//   • detachOutput(outSink) unregisters. No token needed — the service
//     searches across entries (n_entries ≤ a handful, cheap).
//   • setWantsAudio(token, b) updates the subscriber's audio preference.
//     The shared player's AudioOutput is unmuted iff at least one
//     subscriber currently wants audio.
//   • release(token) drops the subscription. When the last subscriber of
//     a URL releases, the player + sink are destroyed immediately — no
//     grace period (per the chosen GC policy).
//
// Safety: output sinks are tracked via QPointer so a VideoOutput
// destroyed without an explicit detach (e.g. window teardown) auto-
// invalidates rather than leaving a dangling pointer in the broadcast
// list.
class MediaPlaybackService : public QObject
{
    Q_OBJECT

public:
    explicit MediaPlaybackService(QObject* parent = nullptr);
    ~MediaPlaybackService() override;

    // `loop` sets whether the shared player restarts at end (true, the
    // historical always-loop behavior) or plays once and holds the last frame
    // (false). It's a property of the per-URL Entry, so when two subscribers
    // of the SAME file disagree, the most recent acquire/setLoop wins — a rare
    // collision (a file used simultaneously as a foreground media item and a
    // theme-video background). Theme backgrounds always pass true.
    Q_INVOKABLE int  acquire(QString sourceUrl, bool wantsAudio, bool loop = true);
    Q_INVOKABLE void setWantsAudio(int token, bool wantsAudio);
    Q_INVOKABLE void setLoop(int token, bool loop);
    Q_INVOKABLE void release(int token);

    Q_INVOKABLE void attachOutput(int token, QVideoSink* outSink);
    Q_INVOKABLE void detachOutput(QVideoSink* outSink);

private:
    struct Subscriber {
        int  token;
        bool wantsAudio;
    };
    struct Entry {
        QString                       url;
        QMediaPlayer*                 player = nullptr;
        QVideoSink*                   sink   = nullptr;
        QAudioOutput*                 audio  = nullptr;
        QList<Subscriber>             subs;
        QList<QPointer<QVideoSink>>   outputs;
        bool                          loop   = true;   // last-writer-wins per URL
    };

    Entry* entryForToken(int token) const;
    Entry* entryForOutput(QVideoSink* outSink) const;
    void   recomputeAudio(Entry& e);
    void   broadcastFrame(Entry& e, const QVideoFrame& frame);
    void   destroyEntry(const QString& url);

    QHash<QString, Entry*> m_byUrl;
    QHash<int, QString>    m_tokenToUrl;
    int                    m_nextToken = 1;
};

}  // namespace crater
