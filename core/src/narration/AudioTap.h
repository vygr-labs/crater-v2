#pragma once

#include "narration/AudioRing.h"

#include <QAudioDevice>
#include <QAudioFormat>
#include <QObject>
#include <QString>

#include <memory>

QT_BEGIN_NAMESPACE
class QAudioSource;
class QIODevice;
QT_END_NAMESPACE

namespace crater::narration {

// Microphone capture, normalized to the 16 kHz mono float stream that both
// VoiceGate and whisper.cpp require.
//
// Note this is capture, not playback. docs/TODO.md defers NDI audio because
// QAudioOutput exposes no sample callback, and that limitation does not apply
// here: QAudioSource hands us a QIODevice we pull PCM from directly, so no
// new platform infrastructure is needed.
//
// Devices rarely offer 16 kHz mono natively, so this class owns the format
// negotiation, channel downmix, and decimation. Everything downstream gets to
// assume 16 kHz mono float and nothing else.
//
// docs/narration.md §8 governs the lifecycle: capture starts on an explicit
// operator action and never on app start, samples land only in a fixed-size
// ring, and nothing is written to disk at any point.
class AudioTap : public QObject
{
    Q_OBJECT

public:
    // Ring capacity. Thirty seconds is far more than the pipeline needs (the
    // longest utterance VoiceGate emits is 15 s) and it caps by construction
    // how much of the room can exist in memory at once.
    static constexpr int kRingSeconds = 30;
    static constexpr int kTargetRate  = 16000;

    explicit AudioTap(QObject* parent = nullptr);
    ~AudioTap() override;

    // Open the system default input. Returns false and fills `error` if there
    // is no input device or the device refuses every format we can consume.
    bool start(QString* error);
    bool start(const QAudioDevice& device, QString* error);

    // Close the device and clear the ring — no audio outlives a session.
    void stop();

    bool isRunning() const;

    // Pull decimated 16 kHz mono frames. Safe to call from the recognizer
    // thread; the ring is mutex-guarded.
    int read(float* dst, int maxFrames) { return m_ring.read(dst, maxFrames); }
    int available() const { return m_ring.available(); }

    // Most recent frame energy in dBFS, for the hot-mic indicator. -100 is
    // digital silence.
    float levelDb() const { return m_levelDb; }

    QString deviceName()       const { return m_deviceName; }
    int     nativeSampleRate() const { return m_sourceFormat.sampleRate(); }
    qint64  overruns()         const { return m_ring.overruns(); }

signals:
    // Frames landed in the ring. The consumer decides how much to drain.
    void audioReady();

    // Throttled to roughly 20 Hz so a QML binding on the level meter doesn't
    // re-evaluate on every 10 ms buffer.
    void levelChanged();

    // Capture ended on its own — device unplugged, exclusive-mode grab by
    // another app. The operator has to be told, because a silently dead mic
    // looks exactly like a preacher who hasn't cited anything yet.
    void stopped(const QString& reason);

private:
    void onReadyRead();
    void appendConverted(const char* bytes, qint64 byteCount);

    std::unique_ptr<QAudioSource> m_source;
    QIODevice*                    m_io = nullptr;   // owned by m_source
    QAudioFormat                  m_sourceFormat;
    QString                       m_deviceName;

    AudioRing m_ring;

    // Box-filter decimation state, carried across device buffers. Averaging
    // the input frames that span each output frame gives cheap anti-aliasing;
    // point-sampling 48 kHz down to 16 kHz would fold everything above 8 kHz
    // back into the band the recognizer actually reads.
    int   m_phase = 0;
    float m_acc   = 0.0f;
    int   m_accN  = 0;

    float  m_levelDb        = -100.0f;
    qint64 m_lastLevelEmit  = 0;
    QList<float> m_scratch;   // reused per callback, never reallocated steadily
};

}  // namespace crater::narration
