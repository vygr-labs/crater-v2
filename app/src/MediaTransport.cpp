#include "MediaTransport.h"

#include "MediaPlaybackService.h"

#include <QMediaPlayer>

#include <utility>

namespace crater {

MediaTransport::MediaTransport(QObject* parent)
    : QObject(parent)
{
    MediaPlaybackService* svc = MediaPlaybackService::instance();
    if (!svc) return;

    // The player for a URL comes and goes with its subscribers (Preview
    // re-selecting, a transition releasing the outgoing layer). Re-resolve
    // whenever OUR url gains or loses its player.
    connect(svc, &MediaPlaybackService::sourceAdded, this,
            [this](const QString& url) { if (url == m_source) rebind(); });
    connect(svc, &MediaPlaybackService::sourceRemoved, this,
            [this](const QString& url) { if (url == m_source) rebind(); });
    connect(svc, &MediaPlaybackService::loopChanged, this,
            [this](const QString& url) { if (url == m_source) emit stateChanged(); });
}

MediaTransport::~MediaTransport()
{
    dropPlayerConnections();
}

void MediaTransport::setSource(const QString& url)
{
    if (m_source == url) return;
    m_source = url;
    emit sourceChanged();
    rebind();
}

void MediaTransport::dropPlayerConnections()
{
    for (const QMetaObject::Connection& c : std::as_const(m_playerConns))
        QObject::disconnect(c);
    m_playerConns.clear();
}

void MediaTransport::rebind()
{
    MediaPlaybackService* svc = MediaPlaybackService::instance();
    QMediaPlayer* next = (svc && !m_source.isEmpty()) ? svc->playerFor(m_source)
                                                      : nullptr;
    if (next != m_player.data()) {
        dropPlayerConnections();
        m_player = next;
        if (next) {
            // positionChanged ticks many times a second while playing; it gets
            // its own notify so the seek bar repaints without re-evaluating
            // every other binding on the bar.
            m_playerConns << connect(next, &QMediaPlayer::positionChanged,
                                     this, &MediaTransport::positionChanged);
            m_playerConns << connect(next, &QMediaPlayer::durationChanged,
                                     this, &MediaTransport::stateChanged);
            m_playerConns << connect(next, &QMediaPlayer::playbackStateChanged,
                                     this, &MediaTransport::stateChanged);
            m_playerConns << connect(next, &QMediaPlayer::mediaStatusChanged,
                                     this, &MediaTransport::stateChanged);
            m_playerConns << connect(next, &QMediaPlayer::seekableChanged,
                                     this, &MediaTransport::stateChanged);
        }
    }
    emit stateChanged();
    emit positionChanged();
}

bool MediaTransport::available() const
{
    return !m_player.isNull();
}

bool MediaTransport::playing() const
{
    return m_player && m_player->playbackState() == QMediaPlayer::PlayingState;
}

bool MediaTransport::atEnd() const
{
    return m_player && m_player->mediaStatus() == QMediaPlayer::EndOfMedia;
}

bool MediaTransport::seekable() const
{
    return m_player && m_player->isSeekable();
}

bool MediaTransport::loop() const
{
    MediaPlaybackService* svc = MediaPlaybackService::instance();
    return svc && m_player && svc->loopFor(m_source);
}

void MediaTransport::setLoop(bool loop)
{
    cue();
    if (MediaPlaybackService* svc = MediaPlaybackService::instance())
        svc->setLoopFor(m_source, loop);
}

void MediaTransport::cue()
{
    if (!m_marksCue) return;
    if (MediaPlaybackService* svc = MediaPlaybackService::instance())
        svc->markCued(m_source);
}

qint64 MediaTransport::position() const
{
    return m_player ? m_player->position() : 0;
}

qint64 MediaTransport::duration() const
{
    return m_player ? m_player->duration() : 0;
}

void MediaTransport::play()
{
    cue();
    if (auto* svc = MediaPlaybackService::instance()) svc->play(m_source);
}

void MediaTransport::pause()
{
    cue();
    if (auto* svc = MediaPlaybackService::instance()) svc->pause(m_source);
}

void MediaTransport::togglePlay()
{
    cue();
    if (auto* svc = MediaPlaybackService::instance()) svc->togglePlay(m_source);
}

void MediaTransport::stop()
{
    cue();
    if (auto* svc = MediaPlaybackService::instance()) svc->stop(m_source);
}

void MediaTransport::restart()
{
    cue();
    if (auto* svc = MediaPlaybackService::instance()) svc->restart(m_source);
}

void MediaTransport::seek(qint64 positionMs)
{
    cue();
    if (auto* svc = MediaPlaybackService::instance()) svc->seek(m_source, positionMs);
}

void MediaTransport::skip(qint64 deltaMs)
{
    cue();
    if (auto* svc = MediaPlaybackService::instance()) svc->skip(m_source, deltaMs);
}

}  // namespace crater
