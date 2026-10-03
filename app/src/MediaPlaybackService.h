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
// Transport (play / pause / seek / loop):
//   Because every surface showing a URL — the audience ProjectionScene, the
//   NDI scene, the Live and Preview mini-monitors — renders from the SAME
//   player, transport commands are keyed by source URL and act on that one
//   player. Pausing the live clip therefore freezes the projection, NDI and
//   the console monitors together, and a seek lands on all of them on the
//   same frame. QML reads per-URL state through a MediaTransport object
//   (MediaTransport.h); the commands below are also callable directly, which
//   is how Main.qml's keyboard shortcuts reach the live clip.
//
//   Loop: subscribers pass the item's saved loop flag on acquire (last writer
//   wins). Once the operator flips loop from a transport, the entry is
//   "pinned" and later subscriber preferences no longer overwrite it, so a
//   Preview re-selecting the same file can't silently undo the toggle. A
//   fresh go-live (cueFromStart) clears the pin and re-seeds the saved flag.
//
//   Volume / mute are global (one audience bus): `volume` is persisted
//   through SettingsService.mediaVolume (main.cpp syncs it), `muted` is a
//   session-only master mute. Both apply on top of the per-subscriber
//   wantsAudio OR, so they never make a muted surface audible.
//
// Safety: output sinks are tracked via QPointer so a VideoOutput
// destroyed without an explicit detach (e.g. window teardown) auto-
// invalidates rather than leaving a dangling pointer in the broadcast
// list.
class MediaPlaybackService : public QObject
{
    Q_OBJECT

    // Perceptual 0..1 (slider position). Mapped to a linear gain internally.
    Q_PROPERTY(double volume READ volume WRITE setVolume NOTIFY volumeChanged)
    // Session-only master mute for foreground video audio.
    Q_PROPERTY(bool   muted  READ muted  WRITE setMuted  NOTIFY mutedChanged)

public:
    explicit MediaPlaybackService(QObject* parent = nullptr);
    ~MediaPlaybackService() override;

    // The one instance main() constructs. MediaTransport (a QML-creatable
    // type, so it can't take constructor arguments) finds the service here.
    static MediaPlaybackService* instance();

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

    // ── Transport, keyed by source URL ("file:///<path>", the same string
    //    subscribers acquire with). Every call is a no-op for a URL with no
    //    live player, so callers never need to check first.
    Q_INVOKABLE bool hasSource(const QString& url) const;
    Q_INVOKABLE void play(const QString& url);
    Q_INVOKABLE void pause(const QString& url);
    Q_INVOKABLE void togglePlay(const QString& url);
    // Back to the first frame, paused (the frame stays on screen rather than
    // going black, which is what QMediaPlayer::stop() would do).
    Q_INVOKABLE void stop(const QString& url);
    Q_INVOKABLE void restart(const QString& url);
    Q_INVOKABLE void seek(const QString& url, qint64 positionMs);
    Q_INVOKABLE void skip(const QString& url, qint64 deltaMs);
    // Operator loop toggle. Pins the entry's loop flag (see header comment).
    Q_INVOKABLE void setLoopFor(const QString& url, bool loop);
    // Go-live cue: rewind, play, and reset loop to the item's saved flag. A
    // URL with no player yet is fine: its first acquire starts at 0 anyway.
    Q_INVOKABLE void cueFromStart(const QString& url, bool loop);

    double volume() const { return m_volume; }
    void   setVolume(double v);
    bool   muted() const  { return m_muted; }
    void   setMuted(bool m);

    // C++-only accessors for MediaTransport.
    QMediaPlayer* playerFor(const QString& url) const;
    bool          loopFor(const QString& url) const;

signals:
    // An Entry (player) for `url` came into / went out of existence.
    void sourceAdded(const QString& url);
    void sourceRemoved(const QString& url);
    void loopChanged(const QString& url);
    void volumeChanged();
    void mutedChanged();

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
        bool                          loopPinned = false; // operator override
    };

    Entry* entryForToken(int token) const;
    Entry* entryForOutput(QVideoSink* outSink) const;
    void   recomputeAudio(Entry& e);
    void   applyLoop(Entry& e, bool loop);
    void   broadcastFrame(Entry& e, const QVideoFrame& frame);
    void   destroyEntry(const QString& url);

    QHash<QString, Entry*> m_byUrl;
    QHash<int, QString>    m_tokenToUrl;
    int                    m_nextToken = 1;
    double                 m_volume = 1.0;
    bool                   m_muted  = false;
};

}  // namespace crater
