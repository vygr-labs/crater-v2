#include "MediaPlaybackService.h"

#include <QAudioOutput>
#include <QDebug>
#include <QMediaPlayer>
#include <QUrl>
#include <QVideoFrame>
#include <QVideoSink>

namespace crater {

MediaPlaybackService::MediaPlaybackService(QObject* parent)
    : QObject(parent)
{}

MediaPlaybackService::~MediaPlaybackService()
{
    // QObject parent cleanup destroys players/sinks automatically; the
    // qDeleteAll here just frees the heap Entry structs themselves.
    qDeleteAll(m_byUrl);
}

int MediaPlaybackService::acquire(QString sourceUrl, bool wantsAudio)
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

        e->audio->setMuted(true);        // recomputeAudio sets the real value
        e->audio->setVolume(1.0);

        e->player->setVideoSink(e->sink);
        e->player->setAudioOutput(e->audio);
        e->player->setLoops(QMediaPlayer::Infinite);

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
    }

    const int token = m_nextToken++;
    e->subs.append({ token, wantsAudio });
    m_tokenToUrl.insert(token, sourceUrl);
    recomputeAudio(*e);
    return token;
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
    e.audio->setMuted(!wantAny);
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
