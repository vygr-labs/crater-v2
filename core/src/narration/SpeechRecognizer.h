#pragma once

#include <QObject>
#include <QString>

#include <atomic>

namespace crater::narration {

// Abstract speech-to-text backend. See docs/narration.md §7.1.
//
// Two real implementations: whisper.cpp on this machine, and Deepgram's
// streaming API (§7.4), which the operator opts into with their own key. A
// third backend is a new file rather than a refactor of NarrationService. It also lets the phase-2 UI and the
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

    // Optional second, faster model used only by transcribeInterim().
    //
    // The two passes want opposite things. A finished utterance is the answer
    // an operator acts on and has to be right. An in-progress hypothesis is
    // superseded a second later and can never project, so its only real
    // failure mode is arriving too late to be a hypothesis at all. Running the
    // accurate model on both makes the fast path as slow as the careful one
    // for no benefit.
    //
    // Optional in the strict sense: a backend that declines simply uses its
    // one model for both passes, and callers must treat failure as a
    // degradation rather than an error. Never required for correctness.
    virtual bool loadDraft(const QString& modelPath, QString* error)
    {
        Q_UNUSED(modelPath);
        if (error) *error = QStringLiteral("This backend has no separate draft model.");
        return false;
    }

    virtual bool    isLoaded()   const = 0;
    virtual QString engineName() const = 0;

    // Free the model and release its memory. Narration is opt-in and its
    // memory budget only applies while armed (docs/narration.md §9), so
    // disarming has to actually give the memory back.
    virtual void unload() = 0;

    // A streaming backend takes the microphone's audio continuously through
    // pushAudio() and decides for itself where an utterance ends, emitting
    // partial() and transcribed() as it goes. NarrationService then skips
    // VoiceGate segmentation and the interim cadence entirely, because both
    // exist only to approximate what a streaming engine does natively.
    virtual bool isStreaming() const { return false; }

    // Safe from any thread. Asks a long call already running on the worker,
    // such as a whisper decode, to give up early. Used on disarm, so the
    // thread can be joined without waiting out an utterance nobody needs.
    // Once set it stays set: the recognizer is on its way out.
    void requestAbort() { m_abort.store(true, std::memory_order_relaxed); }

protected:
    bool abortRequested() const { return m_abort.load(std::memory_order_relaxed); }

public slots:
    // Transcribe one complete utterance of 16 kHz mono float samples, as
    // segmented by VoiceGate. Emits transcribed() or failed() when done.
    //
    // Takes the samples by value: this crosses a thread boundary, and Qt's
    // queued connections copy the argument anyway. A 15 s utterance is 960 kB,
    // which is cheap next to the inference that follows it.
    virtual void transcribe(QList<float> mono16k, qint64 startedAtMs) = 0;

    // Transcribe an utterance that is still being spoken, and emit partial().
    //
    // The whole reason this exists: VoiceGate only closes an utterance after a
    // pause, and its backstop is 15 seconds, so a preacher in full flow gets
    // no suggestions at all until they stop. Re-running recognition over the
    // audio so far is what turns the feature from "after the fact" into
    // "while you speak".
    //
    // A backend with no in-progress hypothesis is a valid backend — it just
    // never shortens the latency.
    //
    // It must still answer. Callers throttle interim work against the same
    // in-flight budget as real utterances, so a backend that silently declines
    // would leak a slot on every pass and stall the pipeline within a minute.
    // Emitting an empty partial() is how a backend says "nothing from me".
    virtual void transcribeInterim(QList<float> mono16k, qint64 startedAtMs)
    {
        Q_UNUSED(mono16k);
        emit partial(QString(), startedAtMs);
    }

    // Streaming backends only (isStreaming()). `atMs` is the session-clock
    // time of the chunk's first sample, so results can be timestamped against
    // the same clock the utterance path uses.
    virtual void pushAudio(QList<float> mono16k, qint64 atMs)
    {
        Q_UNUSED(mono16k);
        Q_UNUSED(atMs);
    }

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

    // One utterance could not be transcribed. The engine is still usable.
    void failed(const QString& message);

    // The engine is gone for the rest of the session, for example a streaming
    // connection that could not be restored. Nothing the microphone hears can
    // be used after this, so the service stops listening rather than leave a
    // live microphone indicator over a dead pipeline.
    void lost(const QString& message);

    // Streaming backends only. The connection dropped and is being retried
    // (false, with what to tell the operator), or it came back (true).
    void connectionChanged(bool connected, const QString& message);

private:
    std::atomic<bool> m_abort{ false };
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
