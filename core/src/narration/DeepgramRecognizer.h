#pragma once

#include "narration/SpeechRecognizer.h"

#include <QElapsedTimer>
#include <QList>
#include <QString>
#include <QStringList>

class QEventLoop;
class QWebSocket;
class QTimer;

namespace crater::narration {

// Deepgram streaming backend. See docs/narration.md §7.4.
//
// The one backend that sends audio off the machine, which is why it is never
// the default and only runs with a church's own API key: the operator picks
// it in Settings > Narration and the privacy text there says where the audio
// goes. Everything downstream of the transcript (detection, the trust gate,
// the grace period) is unchanged, so a partial still can never go live.
//
// Streaming rather than per-utterance: microphone audio goes up the socket as
// it arrives, and Deepgram's endpointing decides where a sentence ends. That
// is what gets a finished transcript back a few hundred milliseconds after
// the preacher stops, instead of after a local model re-reads the audio.
//
// Threading: like WhisperRecognizer, this lives on the narration worker
// thread. The socket is created in load(), on that thread, so it never
// touches the thread that draws the projection.
class DeepgramRecognizer final : public SpeechRecognizer
{
    Q_OBJECT

public:
    explicit DeepgramRecognizer(QObject* parent = nullptr);
    ~DeepgramRecognizer() override;

    // `apiKey` takes the place of a model path. Waits for the first
    // connection, so a bad key or no internet is reported at arm() instead of
    // as silence once the service has started. Every later reconnect is
    // asynchronous.
    bool    load(const QString& apiKey, QString* error) override;
    bool    isLoaded()    const override;
    QString engineName()  const override;
    void    unload() override;
    bool    isStreaming() const override { return true; }

    // Terms Deepgram should favour. Defaults to the book names.
    void setKeyterms(const QStringList& terms) { m_keyterms = terms; }

    // One server message. Public so tests can replay recorded Results and
    // UtteranceEnd messages without a socket.
    void handleMessage(const QString& message);

public slots:
    void transcribe(QList<float> mono16k, qint64 startedAtMs) override;
    void pushAudio(QList<float> mono16k, qint64 atMs) override;

signals:
    // Bench-only timing: where in the stream the text just received ends, in
    // seconds of audio. Streaming in real time, receive time minus this is
    // how long after the words were spoken the text arrived.
    void segmentTiming(bool isFinal, double audioEndSec);

private:
    void startAttempt();
    void onConnected();
    void onSocketError();
    void onDisconnected();
    void attemptFailed();
    void scheduleRetry();
    void sendKeepAlive();
    void emitUtterance();
    QString joinedFinals(const QString& tail = {}) const;
    QString describeFailure() const;

    QWebSocket* m_ws             = nullptr;
    QTimer*     m_reconnect      = nullptr;
    QTimer*     m_connectTimeout = nullptr;
    QTimer*     m_keepAlive      = nullptr;
    QString     m_key;
    QStringList m_keyterms;

    // Set only while load() waits for the first connection. unload() arriving
    // in that window (the operator pressed Stop) ends the wait instead of
    // deleting the socket out from under it.
    QEventLoop* m_waitLoop  = nullptr;
    bool        m_cancelled = false;

    // An open() is in flight and has not yet connected or failed.
    bool    m_connecting = false;
    QString m_lastError;

    // Since the last bytes went up the socket. Deepgram closes a stream that
    // has been quiet for about ten seconds.
    QElapsedTimer m_sinceSend;

    // Session-clock time of the first sample sent on the current socket.
    // Deepgram reports offsets from the start of its stream, and a reconnect
    // starts a new one.
    qint64 m_originMs = -1;

    // Finalized pieces of the utterance in progress. Deepgram finalizes
    // stretches of speech (is_final) before it decides the speaker has
    // finished (speech_final), and only the whole utterance should reach the
    // detectors as a final transcript.
    QStringList m_finals;
    double      m_uttStartSec = -1.0;

    bool m_wantOpen = false;
    int  m_failures = 0;
};

}  // namespace crater::narration
