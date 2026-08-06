#pragma once

#include <QObject>
#include <QString>

namespace crater::narration {

// Abstract speech-to-text backend. See docs/narration.md §7.1.
//
// There is exactly one real implementation to begin with (whisper.cpp), and
// this interface is still worth having: "fully offline" is a decision this
// domain revisits, and a Vosk or cloud backend has to be a new file rather
// than a refactor of NarrationService. It also lets the phase-2 UI and the
// phase-3/4 matchers be developed against NullRecognizer with no model on
// disk at all.
//
// Threading: implementations are expected to live on a worker thread with an
// event loop. `transcribe()` is a slot, so callers reach it with a queued
// connection or QMetaObject::invokeMethod and never block the UI thread.
// Results come back as queued signal emissions.
class SpeechRecognizer : public QObject
{
    Q_OBJECT

public:
    explicit SpeechRecognizer(QObject* parent = nullptr) : QObject(parent) {}
    ~SpeechRecognizer() override = default;

    // Load a model from disk. Returns false and fills `error` on failure.
    // Blocking, and slow (hundreds of ms to seconds) — call it on the worker
    // thread, not during app startup.
    virtual bool load(const QString& modelPath, QString* error) = 0;

    virtual bool    isLoaded()   const = 0;
    virtual QString engineName() const = 0;

    // Free the model and release its memory. Narration is opt-in and its
    // memory budget only applies while armed (docs/narration.md §9), so
    // disarming has to actually give the memory back.
    virtual void unload() = 0;

public slots:
    // Transcribe one complete utterance of 16 kHz mono float samples, as
    // segmented by VoiceGate. Emits transcribed() or failed() when done.
    //
    // Takes the samples by value: this crosses a thread boundary, and Qt's
    // queued connections copy the argument anyway. A 15 s utterance is 960 kB,
    // which is cheap next to the inference that follows it.
    virtual void transcribe(QList<float> mono16k, qint64 startedAtMs) = 0;

signals:
    // A finished utterance. `startedAtMs` echoes back what was passed to
    // transcribe() so downstream stages can timestamp against the session
    // clock. Named transcribed() rather than final() because `final` is a
    // C++ contextual keyword and reads badly in a moc'd signal list.
    void transcribed(const QString& text, qint64 startedAtMs);

    // Best-effort in-progress hypothesis, if the backend produces one.
    // Detection may run on these to shave latency, but nothing may go live
    // off a partial — see the grace period in docs/narration.md §5.
    void partial(const QString& text, qint64 startedAtMs);

    void failed(const QString& message);
};

// Does nothing, successfully. Lets the whole narration stack build, run, and
// be UI-tested with no model present and whisper compiled out.
class NullRecognizer final : public SpeechRecognizer
{
    Q_OBJECT

public:
    using SpeechRecognizer::SpeechRecognizer;

    bool load(const QString&, QString*) override { return true; }
    bool isLoaded() const override { return true; }
    QString engineName() const override { return QStringLiteral("null"); }
    void unload() override {}

public slots:
    void transcribe(QList<float>, qint64 startedAtMs) override
    {
        emit transcribed(QString(), startedAtMs);
    }
};

}  // namespace crater::narration
