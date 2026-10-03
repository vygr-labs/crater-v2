#include "MediaPlaybackService.h"

#include <QAudioOutput>
#include <QDebug>
#include <QMediaPlayer>
#include <QtAudio>
#include <QUrl>
#include <QVideoFrame>
#include <QVideoSink>

#include <utility>

namespace crater {

namespace {
MediaPlaybackService* g_instance = nullptr;

// Slider position (perceptual) -> QAudioOutput gain (linear). A linear slider
// feels like it does nothing for its top half and everything in its last few
// pixels; the logarithmic mapping spreads loudness evenly across the travel.
float linearGain(double perceptual)
{
    return QtAudio::convertVolume(static_cast<float>(perceptual),
                                  QtAudio::LogarithmicVolumeScale,
                                  QtAudio::LinearVolumeScale);
}
}  // namespace

MediaPlaybackService::MediaPlaybackService(QObject* parent)
    : QObject(parent)
{
    g_instance = this;
}

MediaPlaybackService::~MediaPlaybackService()
{
    if (g_instance == this) g_instance = nullptr;
    // QObject parent cleanup destroys players/sinks automatically; the
    // qDeleteAll here just frees the heap Entry structs themselves.
    qDeleteAll(m_byUrl);
}

MediaPlaybackService* MediaPlaybackService::instance()
{
    return g_instance;
}

int MediaPlaybackService::acquire(QString sourceUrl, bool wantsAudio, bool loop)
{
    if (sourceUrl.isEmpty()) return -1;

    Entry* e = m_byUrl.value(sourceUrl, nullptr);
    if (!e) {
        // First subscriber for this URL — spin up the decoder.
        e         = new Entry;
        e->url    = sourceUrl;
        e->player = new QMediaPlayer(this);
        e->sink   = new QVideoSink(this);
        e->audio  = new QAudioOutput(this);
        e->loop   = loop;

        e->audio->setMuted(true);        // recomputeAudio sets the real value
        e->audio->setVolume(linearGain(m_volume));

        e->player->setVideoSink(e->sink);
        e->player->setAudioOutput(e->audio);
        e->player->setLoops(loop ? QMediaPlayer::Infinite : 1);

        // Relay: every frame produced by the primary sink is broadcast to
        // each attached output sink. We capture by URL (not by Entry*) so
        // a stale pointer can't be dereferenced — the URL lookup gates
        // each delivery against the live map. Cheap: O(1) hash lookup
        // plus a tiny linear scan over outputs.
        const QString urlCopy = sourceUrl;
        connect(e->sink, &QVideoSink::videoFrameChanged, this,
                [this, urlCopy](const QVideoFrame& f) {
                    const auto it = m_byUrl.constFind(urlCopy);
                    if (it == m_byUrl.constEnd()) return;
                    broadcastFrame(*it.value(), f);
                });

        e->player->setSource(QUrl(sourceUrl));
        e->player->play();

        m_byUrl.insert(sourceUrl, e);
        emit sourceAdded(sourceUrl);
    } else if (!e->loopPinned) {
        // Existing decoder, new subscriber with a different loop preference —
        // last-writer-wins (see header). Update the shared player in place.
        // Skipped once the operator pinned loop from a transport.
        applyLoop(*e, loop);
    }

    const int token = m_nextToken++;
    e->subs.append({ token, wantsAudio });
    m_tokenToUrl.insert(token, sourceUrl);
    recomputeAudio(*e);
    return token;
}

void MediaPlaybackService::setLoop(int token, bool loop)
{
    Entry* e = entryForToken(token);
    if (!e || e->loopPinned) return;
    applyLoop(*e, loop);
}

void MediaPlaybackService::applyLoop(Entry& e, bool loop)
{
    if (e.loop == loop) return;
    e.loop = loop;
    e.player->setLoops(loop ? QMediaPlayer::Infinite : 1);
    emit loopChanged(e.url);
}

// ── Transport ───────────────────────────────────────────────────────────

bool MediaPlaybackService::hasSource(const QString& url) const
{
    return m_byUrl.contains(url);
}

QMediaPlayer* MediaPlaybackService::playerFor(const QString& url) const
{
    const Entry* e = m_byUrl.value(url, nullptr);
    return e ? e->player : nullptr;
}

bool MediaPlaybackService::loopFor(const QString& url) const
{
    const Entry* e = m_byUrl.value(url, nullptr);
    return e ? e->loop : false;
}

void MediaPlaybackService::play(const QString& url)
{
    QMediaPlayer* p = playerFor(url);
    if (!p) return;
    // A play-once clip that ran out sits at EndOfMedia holding its last
    // frame. Play from there means "play it again", so rewind first rather
    // than relying on backend-specific restart-at-end behaviour.
    if (p->mediaStatus() == QMediaPlayer::EndOfMedia) p->setPosition(0);
    p->play();
}

void MediaPlaybackService::pause(const QString& url)
{
    if (QMediaPlayer* p = playerFor(url)) p->pause();
}

void MediaPlaybackService::togglePlay(const QString& url)
{
    QMediaPlayer* p = playerFor(url);
    if (!p) return;
    if (p->playbackState() == QMediaPlayer::PlayingState) p->pause();
    else                                                    play(url);
}

void MediaPlaybackService::stop(const QString& url)
{
    QMediaPlayer* p = playerFor(url);
    if (!p) return;
    // pause + rewind, NOT QMediaPlayer::stop(): stop() releases the decoded
    // frame and every attached output (the audience screen included) would
    // go black. Paused at 0 keeps the opening frame up, ready to roll.
    p->pause();
    p->setPosition(0);
}

void MediaPlaybackService::restart(const QString& url)
{
    QMediaPlayer* p = playerFor(url);
    if (!p) return;
    p->setPosition(0);
    p->play();
}

void MediaPlaybackService::seek(const QString& url, qint64 positionMs)
{
    QMediaPlayer* p = playerFor(url);
    if (!p || !p->isSeekable()) return;
    const qint64 dur = p->duration();
    qint64 target = qMax<qint64>(0, positionMs);
    if (dur > 0) target = qMin(target, dur);
    // A finished play-once clip is in StoppedState. Seeking a stopped player
    // moves the position without presenting a frame, so the screen would keep
    // showing the end. Dropping into Paused first makes the seek paint.
    if (p->playbackState() == QMediaPlayer::StoppedState) p->pause();
    p->setPosition(target);
}

void MediaPlaybackService::skip(const QString& url, qint64 deltaMs)
{
    QMediaPlayer* p = playerFor(url);
    if (!p) return;
    seek(url, p->position() + deltaMs);
}

void MediaPlaybackService::setLoopFor(const QString& url, bool loop)
{
    Entry* e = m_byUrl.value(url, nullptr);
    if (!e) return;
    e->loopPinned = true;
    applyLoop(*e, loop);
    // Turning loop on after a play-once clip already ended: the player won't
    // notice the new loop count until it plays again, so start it over.
    if (loop && e->player->mediaStatus() == QMediaPlayer::EndOfMedia) {
        e->player->setPosition(0);
        e->player->play();
    }
}

void MediaPlaybackService::cueFromStart(const QString& url, bool loop)
{
    Entry* e = m_byUrl.value(url, nullptr);
    if (!e) return;
    // A clip that was already decoding before this go-live (the Preview
    // monitor shares the player, so a previewed clip has usually been rolling
    // muted for a while, or has even run out) must still open on its first
    // frame for the audience.
    e->loopPinned = false;
    applyLoop(*e, loop);
    e->player->setPosition(0);
    e->player->play();
}

void MediaPlaybackService::setVolume(double v)
{
    const double clamped = qBound(0.0, v, 1.0);
    if (qFuzzyCompare(1.0 + m_volume, 1.0 + clamped)) return;
    m_volume = clamped;
    for (Entry* e : std::as_const(m_byUrl)) recomputeAudio(*e);
    emit volumeChanged();
}

void MediaPlaybackService::setMuted(bool m)
{
    if (m_muted == m) return;
    m_muted = m;
    for (Entry* e : std::as_const(m_byUrl)) recomputeAudio(*e);
    emit mutedChanged();
}

void MediaPlaybackService::setWantsAudio(int token, bool wantsAudio)
{
    Entry* e = entryForToken(token);
    if (!e) return;
    for (Subscriber& s : e->subs) {
        if (s.token == token) {
            if (s.wantsAudio == wantsAudio) return;
            s.wantsAudio = wantsAudio;
            recomputeAudio(*e);
            return;
        }
    }
}

void MediaPlaybackService::release(int token)
{
    const QString url = m_tokenToUrl.value(token);
    if (url.isEmpty()) return;
    Entry* e = m_byUrl.value(url, nullptr);
    if (!e) return;

    for (int i = 0; i < e->subs.size(); ++i) {
        if (e->subs[i].token == token) {
            e->subs.removeAt(i);
            break;
        }
    }
    m_tokenToUrl.remove(token);

    if (e->subs.isEmpty()) {
        destroyEntry(url);
    } else {
        recomputeAudio(*e);
    }
}

void MediaPlaybackService::attachOutput(int token, QVideoSink* outSink)
{
    if (!outSink) return;
    Entry* target = entryForToken(token);
    if (!target) return;

    // If this sink is already attached to a *different* entry, move it.
    // (Same-entry re-attach is a no-op — guards against extra signals
    // during QML token rebinding.)
    Entry* prior = entryForOutput(outSink);
    if (prior == target) return;
    if (prior) {
        prior->outputs.removeAll(QPointer<QVideoSink>(outSink));
    }

    target->outputs.append(QPointer<QVideoSink>(outSink));

    // Push the current frame immediately so the new output paints right
    // away rather than waiting for the next decoded frame (~16-33 ms
    // latency otherwise — visible flash on attach).
    const QVideoFrame current = target->sink->videoFrame();
    if (current.isValid()) outSink->setVideoFrame(current);
}

void MediaPlaybackService::detachOutput(QVideoSink* outSink)
{
    if (!outSink) return;
    QPointer<QVideoSink> needle(outSink);
    for (auto* e : m_byUrl) {
        if (e->outputs.removeAll(needle) > 0) return;
    }
}

MediaPlaybackService::Entry*
MediaPlaybackService::entryForToken(int token) const
{
    const QString url = m_tokenToUrl.value(token);
    if (url.isEmpty()) return nullptr;
    return m_byUrl.value(url, nullptr);
}

MediaPlaybackService::Entry*
MediaPlaybackService::entryForOutput(QVideoSink* outSink) const
{
    if (!outSink) return nullptr;
    QPointer<QVideoSink> needle(outSink);
    for (auto* e : m_byUrl) {
        if (e->outputs.contains(needle)) return e;
    }
    return nullptr;
}

void MediaPlaybackService::recomputeAudio(Entry& e)
{
    bool wantAny = false;
    for (const Subscriber& s : e.subs) {
        if (s.wantsAudio) { wantAny = true; break; }
    }
    e.audio->setMuted(!wantAny || m_muted);
    e.audio->setVolume(linearGain(m_volume));
}

void MediaPlaybackService::broadcastFrame(Entry& e, const QVideoFrame& frame)
{
    // Walk a copy so a removeAll triggered by a destroyed-during-broadcast
    // sink doesn't invalidate the iterator. Cheap — QList copy is shallow.
    const auto outs = e.outputs;
    for (const QPointer<QVideoSink>& out : outs) {
        if (out) out->setVideoFrame(frame);
    }
}

void MediaPlaybackService::destroyEntry(const QString& url)
{
    Entry* e = m_byUrl.take(url);
    if (!e) return;
    // Already out of the map, so a MediaTransport re-resolving on this signal
    // sees "no player" and lets go of its connections before the delete.
    emit sourceRemoved(url);
    e->player->stop();
    // Children of `this` — explicit delete unparents them. Doing it here
    // (rather than waiting for service teardown) is what gives us
    // immediate GC at refcount 0.
    delete e->player;
    delete e->sink;
    delete e->audio;
    delete e;
}

}  // namespace crater
