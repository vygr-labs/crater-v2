#pragma once

#include "crater/value/HeardReference.h"

#include <QObject>
#include <QString>
#include <QVariantList>
#include <QVariantMap>

#include <memory>

namespace crater {

class BibleService;
class ProjectionService;
class SettingsService;

// The narration subsystem's single QML-visible face. See docs/narration.md.
//
// Everything behind it — the microphone tap, the voice gate, the recognizer
// worker thread, and the three detectors — is private implementation detail
// held in the pimpl. Per architecture.md §4 there is one service per concern
// and one QML surface for it; per §11 there is no global event bus, so each
// signal below has exactly one publisher and one obvious consumer.
//
// The pimpl is not stylistic here, it is load-bearing. crater-core links
// Qt6::Multimedia PRIVATE precisely so no public header exposes an audio
// type, and AudioTap.h pulls in QAudioDevice. Keeping the audio stack inside
// the .cpp is what lets the app target compile against this header without
// inheriting a multimedia dependency it has no business having.
//
// ── Threading ────────────────────────────────────────────────────────────
// Capture and gating run on the main thread: QAudioSource delivers small
// buffers and the energy gate is an RMS pass over 20 ms frames, both far
// inside the <5 ms sync budget in architecture.md §3. Recognition does not —
// whisper on a 15 s utterance is seconds of work — so the recognizer is moved
// to its own QThread and reached only through queued connections.
//
// ── Arming ───────────────────────────────────────────────────────────────
// The microphone opens on arm() and on nothing else. Not on construction, not
// on app start, not on schedule load, not on go-live, and there is no setting
// that changes that (docs/narration.md §8). A church's open microphone is the
// most sensitive thing this application has ever touched and the arming rule
// is the whole reason it is safe.
class NarrationService : public QObject
{
    Q_OBJECT

    // Compiled with speech-recognition support at all. False in a default
    // build (CRATER_WITH_WHISPER is OFF), where arm() refuses and says so.
    Q_PROPERTY(bool available READ available CONSTANT)

    // A speech model exists at the configured path. Distinct from `available`
    // because the two failure modes need different remedies — one is "your
    // build can't do this", the other is "point me at a model file".
    Q_PROPERTY(bool modelReady READ modelReady NOTIFY engineStateChanged)

    // The microphone is open. This is what the console's hot indicator binds
    // to, and it must never be true without that indicator being visible.
    Q_PROPERTY(bool listening READ listening NOTIFY listeningChanged)

    // "suggest" | "stage" | "auto" — the operator's trust level, per the
    // tier x mode matrix in docs/narration.md §5. Persisted via SettingsService.
    Q_PROPERTY(QString mode READ mode WRITE setMode NOTIFY modeChanged)

    // Microphone level, 0..1, already mapped from dBFS for a meter. Emitted at
    // roughly 20 Hz so a QML binding doesn't re-evaluate per audio buffer.
    Q_PROPERTY(qreal inputLevel READ inputLevel NOTIFY inputLevelChanged)

    // The gate currently considers this speech rather than room tone. Drives
    // the "hearing you" affordance, which is how an operator distinguishes a
    // dead microphone from a preacher who simply hasn't cited anything.
    Q_PROPERTY(bool hearingSpeech READ hearingSpeech NOTIFY inputLevelChanged)

    // "unavailable" | "idle" | "loading" | "listening" | "error"
    Q_PROPERTY(QString engineState READ engineState NOTIFY engineStateChanged)

    // Human-readable detail for the current state — the error text when
    // something failed, the device name while listening, "" otherwise.
    Q_PROPERTY(QString statusMessage READ statusMessage NOTIFY engineStateChanged)

    Q_PROPERTY(QString engineName READ engineName NOTIFY engineStateChanged)

    // Undismissed suggestions, newest first. Each entry is a QVariantMap with
    // the HeardReference fields plus `action` ("queued" | "staged" | "live")
    // and a monotonic `id` for dismissal. A map rather than the gadget because
    // the queue carries what the trust gate DID with a detection, which is not
    // a property of the detection itself.
    Q_PROPERTY(QVariantList heard READ heard NOTIFY heardChanged)
    Q_PROPERTY(int heardCount READ heardCount NOTIFY heardChanged)

    // Everything heard this session and what was done with it, oldest first,
    // including detections that were suppressed as duplicates or already live.
    // A church tuning its way from Suggest toward Auto needs the evidence
    // (docs/narration.md §5); this is that evidence. Held in memory only and
    // never written to disk; cleared by the next arm() or by clearLog(), so
    // it outlives the service it describes but not the next one.
    Q_PROPERTY(QVariantList sessionLog READ sessionLog NOTIFY sessionLogChanged)

    // Utterances dropped because recognition could not keep up with speech.
    // Surfaced rather than hidden: silently falling further behind would look
    // to the operator exactly like a preacher who stopped citing scripture.
    Q_PROPERTY(int droppedUtterances READ droppedUtterances NOTIFY droppedUtterancesChanged)

    // What the microphone actually heard this session, oldest first, as
    // [{ text, atMs }].
    //
    // §8 scopes transcripts to the session and keeps them off disk; it does
    // not require hiding them, and hiding them was a mistake. Without this the
    // console only ever reports the END of the pipeline — a suggestion chip —
    // so a dead microphone, a gate that never opens, a recognizer returning
    // empty strings and a detector that declined all present identically as a
    // bar that says "Listening" and does nothing.
    //
    // Memory only, capped, and cleared by BOTH arm() and disarm().
    Q_PROPERTY(QVariantList transcript READ transcript NOTIFY transcriptChanged)

    // Utterances the voice gate closed and handed to the recognizer. Read with
    // `transcript` this localises a failure without a debugger: zero while the
    // level meter moves means the gate never opened; non-zero with an empty
    // transcript means the recognizer returned nothing.
    Q_PROPERTY(int utterancesHeard READ utterancesHeard NOTIFY utterancesHeardChanged)

    // The sentence currently being spoken, as best the recognizer can tell
    // before it is finished. Empty between utterances.
    //
    // Kept apart from `transcript` because it is a guess that is replaced
    // roughly once a second: appending each revision would bury the finished
    // text under ten near-identical drafts of the phrase in progress.
    Q_PROPERTY(QString partialText READ partialText NOTIFY partialTextChanged)

    // QAudioDevice::id() of the chosen microphone, or "" for the system
    // default. Persisted through SettingsService.
    Q_PROPERTY(QString inputDeviceId READ inputDeviceId NOTIFY inputDeviceChanged)

    // What the chosen device is actually called, resolved against the devices
    // present right now. Empty when nothing resolves — which is a different
    // state from "default", and the settings page says so rather than showing
    // a picker that looks correctly set while pointing at a missing device.
    Q_PROPERTY(QString inputDeviceName READ inputDeviceName NOTIFY inputDeviceChanged)

public:
    explicit NarrationService(BibleService*      bible,
                              ProjectionService* projection,
                              SettingsService*   settings,
                              QObject*           parent = nullptr);
    ~NarrationService() override;

    bool    available()   const;
    bool    modelReady()  const;
    bool    listening()   const;
    QString mode()        const;
    qreal   inputLevel()  const;
    bool    hearingSpeech() const;
    QString engineState() const;
    QString statusMessage() const;
    QString engineName()  const;
    QVariantList heard()      const;
    int          heardCount() const;
    QVariantList sessionLog() const;
    int          droppedUtterances() const;
    QVariantList transcript() const;
    int          utterancesHeard() const;
    QString      partialText() const;
    QString      inputDeviceId() const;
    QString      inputDeviceName() const;

    void setMode(const QString& mode);

    // Open the microphone and load the model. Explicit operator action only.
    // Returns false and sets statusMessage on refusal — no model, no input
    // device, or a build without speech support.
    Q_INVOKABLE bool arm();

    // Close the microphone, free the model, and discard the session's audio,
    // transcripts, reference context and pending queue (docs/narration.md §8).
    //
    // The session log survives, and that is deliberate: §5 wants a church
    // moving from Suggest toward Auto to be able to review what the system
    // heard and what it did, which is impossible if the log dies with the
    // click that ends the service. It holds references and short trigger
    // spans, never transcripts. arm() clears it; so does clearLog().
    Q_INVOKABLE void disarm();

    // Remove one suggestion from the queue by its `id`. The operator has
    // either acted on it or decided it was wrong; either way it stops asking.
    Q_INVOKABLE void dismiss(int id);
    Q_INVOKABLE void dismissAll();

    // Rewrite what the log says happened to one detection. The trust gate
    // records its decision the instant it makes it, but an Auto-mode
    // projection can still be cancelled during its grace period — and a log
    // claiming a verse went live when the operator stopped it is worse than
    // no log at all. `action` must be "cancelled", "superseded" or "live".
    Q_INVOKABLE void amendLog(int id, const QString& action);

    // Discard the session log. It survives disarm on purpose (see disarm()),
    // so this is the operator's way to end that.
    Q_INVOKABLE void clearLog();

    // Available microphones, as [{ id, name, isDefault, isSelected }]. The
    // settings page populates its device picker from this.
    Q_INVOKABLE QVariantList inputDevices() const;

    // Choose the microphone. "" means the system default.
    //
    // Takes effect immediately: if the service is already listening the tap is
    // reopened on the new device, because an operator who picks a different
    // microphone mid-service is telling you the current one is wrong, and
    // making them disarm and re-arm to act on that is asking them to take the
    // system down to fix it. Arming state is preserved across the swap; a
    // failure to open the new device reports the error and stops capture
    // rather than silently continuing on the old one.
    Q_INVOKABLE void setInputDevice(const QString& id);

    // Feed a transcript line straight into the detectors, bypassing audio.
    // This is how the pipeline is exercised without a microphone: the phase-2
    // tests drive it, and it is genuinely useful for an operator debugging why
    // a phrasing didn't fire. It cannot start a recording and it does not
    // require arming, because it never touches the microphone.
    Q_INVOKABLE void injectTranscript(const QString& text);

signals:
    void listeningChanged();
    void modeChanged();
    void inputLevelChanged();
    void engineStateChanged();
    void heardChanged();
    void sessionLogChanged();
    void droppedUtterancesChanged();
    void inputDeviceChanged();
    void transcriptChanged();
    void utterancesHeardChanged();
    void partialTextChanged();

    // The three trust outcomes, as separate signals rather than one signal
    // carrying a tier field. The QML handlers are genuinely different actions
    // — populate a queue, stage a preview, start a grace countdown — and
    // splitting them keeps each with one publisher and one consumer (§11).
    void referenceDetected(crater::HeardReference ref);   // queue only
    void referenceStaged(crater::HeardReference ref);     // push to preview
    void referenceAutoLive(crater::HeardReference ref);   // project after grace

    // Capture ended without disarm() being called — device unplugged, or
    // another application took the input exclusively. The operator has to be
    // told, loudly.
    void captureLost(const QString& reason);

private:
    // Second half of arm(), reached only once the model has actually loaded.
    // Split out because the microphone must not open until there is something
    // able to use what it hears.
    void startCapture();

    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

}  // namespace crater
