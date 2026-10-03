#pragma once

#include <QList>
#include <QMetaObject>
#include <QObject>
#include <QPointer>
#include <QString>

QT_BEGIN_NAMESPACE
class QMediaPlayer;
QT_END_NAMESPACE

namespace crater {

// QML-facing view of one shared player in MediaPlaybackService.
//
// MediaPlaybackService keeps one QMediaPlayer per source URL and hands frames
// to every surface showing that URL. It does not expose the player itself to
// QML (there are N of them, created and destroyed as subscribers come and go),
// so a transport bar instantiates one of these, sets `source` to the URL it
// wants to drive, and binds to the state below. The object follows the URL,
// not a particular player: when the last subscriber releases and a new one
// re-acquires, it re-attaches to the fresh player on its own.
//
//   MediaTransport {
//       id: transport
//       source: "file:///" + item.mediaPath
//   }
//   IconButton { iconName: transport.playing ? "pause" : "play"
//                onClicked: transport.togglePlay() }
//
// Commands forward to MediaPlaybackService's URL-keyed transport, so they
// carry the same semantics (stop keeps the first frame up, play at the end of
// a play-once clip starts over, a loop toggle pins the entry).
class MediaTransport : public QObject
{
    Q_OBJECT

    // "file:///<path>", exactly as MediaMonitor acquires it. Empty = inert.
    Q_PROPERTY(QString source    READ source    WRITE setSource NOTIFY sourceChanged)
    // True while a player exists for `source` (someone is showing it).
    Q_PROPERTY(bool    available READ available NOTIFY stateChanged)
    Q_PROPERTY(bool    playing   READ playing   NOTIFY stateChanged)
    // A play-once clip ran to its end and is holding the last frame.
    Q_PROPERTY(bool    atEnd     READ atEnd     NOTIFY stateChanged)
    Q_PROPERTY(bool    seekable  READ seekable  NOTIFY stateChanged)
    Q_PROPERTY(bool    loop      READ loop      WRITE setLoop   NOTIFY stateChanged)
    // Milliseconds. qint64 surfaces as a plain JS number in QML.
    Q_PROPERTY(qint64  position  READ position  NOTIFY positionChanged)
    Q_PROPERTY(qint64  duration  READ duration  NOTIFY stateChanged)
    // Preview's bar sets this: every command it sends also marks the clip as
    // cued, so going live keeps the spot the operator picked
    // (MediaPlaybackService::markCued).
    Q_PROPERTY(bool    marksCue  MEMBER m_marksCue NOTIFY marksCueChanged)

public:
    explicit MediaTransport(QObject* parent = nullptr);
    ~MediaTransport() override;

    QString source() const { return m_source; }
    void    setSource(const QString& url);

    bool   available() const;
    bool   playing() const;
    bool   atEnd() const;
    bool   seekable() const;
    bool   loop() const;
    void   setLoop(bool loop);
    qint64 position() const;
    qint64 duration() const;

    Q_INVOKABLE void play();
    Q_INVOKABLE void pause();
    Q_INVOKABLE void togglePlay();
    Q_INVOKABLE void stop();
    Q_INVOKABLE void restart();
    Q_INVOKABLE void seek(qint64 positionMs);
    Q_INVOKABLE void skip(qint64 deltaMs);

signals:
    void sourceChanged();
    void stateChanged();
    void positionChanged();
    void marksCueChanged();

private:
    void rebind();
    void cue();
    void dropPlayerConnections();

    QString                         m_source;
    QPointer<QMediaPlayer>          m_player;
    QList<QMetaObject::Connection>  m_playerConns;
    bool                            m_marksCue = false;
};

}  // namespace crater
