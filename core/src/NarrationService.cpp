#include "crater/NarrationService.h"

#include "crater/BibleService.h"
#include "crater/ProjectionService.h"
#include "crater/SettingsService.h"

#include "narration/AudioTap.h"
#include "narration/AllusionIndex.h"
#include "narration/AllusionMatcher.h"
#include "narration/CitationDetector.h"
#include "narration/OnnxEmbedder.h"
#include "narration/QuotationMatcher.h"
#include "narration/SpeechRecognizer.h"
#include "narration/TrustGate.h"
#include "narration/VoiceGate.h"
#include "narration/WhisperRecognizer.h"

#include "db/DbPaths.h"

#include <QAudioDevice>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QLoggingCategory>
#include <QMediaDevices>
#include <QThread>

#include <algorithm>
#include <cmath>

namespace {
// Diagnostics for a subsystem whose failures are all silent from the outside:
// a microphone that is open but deaf, a gate that never opens, a recognizer
// that returns empty strings, and a detector that rejects everything all look
// identical to an operator watching a bar that says "Listening".
//
// Lifecycle only at Info. Transcript TEXT is Debug and therefore off unless
// someone deliberately turns it on, because stderr is routinely redirected to
// a file and docs/narration.md §8 promises transcripts are never written to
// disk. Enable with:
//   QT_LOGGING_RULES="crater.narration.debug=true"
//
// The explicit QtInfoMsg floor is the part that matters. The two-argument
// Q_LOGGING_CATEGORY defaults to QtDebugMsg, which would leave the transcript
// line below switched ON for everyone — and stderr is redirected to a file
// often enough that this would quietly turn "never written to disk" into a
// promise the code breaks by default.
Q_LOGGING_CATEGORY(lcNarration, "crater.narration", QtInfoMsg)
}  // namespace
#include <cstring>
#include <utility>

namespace crater {

namespace {

using narration::VoiceGate;

// Audio kept ahead of the moment the gate latches. The gate needs
// minSpeechMs of sustained energy before it declares speech, so by the time
// it says "speech started" the opening syllable is already behind us. Without
// a pre-roll, "Turn to John three sixteen" reaches the recognizer as "urn to
// John three sixteen" — and the intent cue that gates the whole citation
// (docs/narration.md §4.3) is exactly what gets clipped.
constexpr int kPrerollMs = 400;

// Utterances allowed in the recognizer's queue at once. Past this we drop
// rather than queue.
//
// The reasoning is about what "late" means during a sermon. If recognition
// falls behind real time, queueing means the backlog grows without bound and
// a verse eventually lands on the projector forty seconds after the preacher
// moved on — worse than not firing at all, because the congregation sees it
// and the pastor has to work around it. Dropping keeps the system honest and
// current, and droppedUtterances makes the shortfall visible instead of
// letting it read as "the preacher stopped citing scripture".
constexpr int kMaxInFlight = 2;

constexpr int    kQueueCap        = 24;
constexpr int    kLogCap          = 500;
// Long enough to scroll back through a sermon's worth of recent speech,
// short enough that it is obviously a window rather than a recording.
constexpr int    kTranscriptCap   = 200;

// ── Live suggestions while the speaker is still talking ─────────────────
//
// VoiceGate only closes an utterance after `hangoverMs` of silence, with a
// 15 s backstop. That is right for accuracy — whisper reads a whole phrase
// far better than a fragment — and wrong for the operator, who watches a
// preacher say "turn with me to John three sixteen" and gets nothing until
// the sentence ends. So the utterance-so-far is re-transcribed on a cadence
// and detection runs on the result.
//
// 900 ms. This was 1200 while interim passes ran on the operator's full
// model, where anything shorter only queued work that was stale before it
// started. With a draft model answering them (see draftModelPath) a pass
// completes in well under a second, so the cadence is no longer what limits
// how current the hypothesis is. The in-flight reservation below still stops
// this from piling up if the machine is slower than expected.
constexpr int    kInterimMs       = 900;

// Don't bother with an interim pass over less audio than this. Under a second
// of speech carries at most a word or two, and a one-word hypothesis is where
// spurious matches come from.
constexpr int    kInterimMinMs    = 900;

// How much of the utterance an interim pass re-reads.
//
// Five seconds, down from ten. The window matters less than it looks like it
// should — whisper pads its input to thirty seconds before the encoder runs,
// so halving the audio does not halve the cost (WhisperRecognizer's
// audioCtxFor is what actually converts a shorter window into a cheaper
// pass). What the shorter window does buy is a hypothesis about the phrase
// being spoken now rather than one diluted by ten seconds of everything
// before it, and five seconds still comfortably spans "turn with me to the
// gospel of John, chapter three, verse sixteen".
constexpr int    kInterimWindowMs = 5000;
constexpr qint64 kDedupeWindowMs  = 20 * 1000;
constexpr int    kDrainChunk      = 4096;

// dBFS mapped onto a 0..1 meter. -60 is the floor of a quiet sanctuary and
// 0 is digital clip, so the useful speech range sits around 0.3-0.8.
qreal meterFromDb(float db)
{
    constexpr float kFloorDb = -60.0f;
    if (db <= kFloorDb) return 0.0;
    if (db >= 0.0f)     return 1.0;
    return qreal((db - kFloorDb) / -kFloorDb);
}

QVariantMap toMap(const HeardReference& r)
{
    QVariantMap m;
    m.insert(QStringLiteral("reference"),  r.reference);
    m.insert(QStringLiteral("book"),       r.book);
    m.insert(QStringLiteral("chapter"),    r.chapter);
    m.insert(QStringLiteral("verseStart"), r.verseStart);
    m.insert(QStringLiteral("verseEnd"),   r.verseEnd);
    m.insert(QStringLiteral("tier"),       r.tier);
    m.insert(QStringLiteral("kind"),       r.kind);
    m.insert(QStringLiteral("heardText"),  r.heardText);
    m.insert(QStringLiteral("atMs"),       r.atMs);
    m.insert(QStringLiteral("id"),         r.id);
    return m;
}

}  // namespace

// Runs the quotation pass on its own thread, over its own database
// connection.
//
// Measured on a real 285 MB library of fourteen translations, one FTS5
// trigram AND costs between 1 and 48 ms depending on how common the phrase's
// words are, and the matcher issues several per utterance. On the UI thread
// that is up to a tenth of a second of frozen console every time the preacher
// finishes a sentence — six dropped frames while the operator is scrolling a
// song list. architecture.md §3 draws the sync/async line at 5 ms and this is
// an order of magnitude past it.
//
// The connection is deliberately not shared with the main thread's
// BibleService. SQLite is built here with SQLITE_THREADSAFE=2 (one connection
// per thread), and prepared statements are not protected even under
// FULLMUTEX, so reaching into the UI thread's statement cache from here would
// be a data race. Two read-only connections to the same file is precisely the
// case SQLite is designed for, and the second one costs a file handle.
//
// No Q_OBJECT: it inherits QObject only for thread affinity, and every call
// crosses the boundary as a lambda, which keeps custom-type metatype
// registration out of the picture entirely.
class DetectionWorker : public QObject
{
public:
    // Everything the detectors need that is slow: the FTS connection, the
    // embedding session, and the vector index. All built lazily HERE rather
    // than in the constructor, so each belongs to the thread that uses it.
    void init(const QString& embedModelPath, const QString& indexPath)
    {
        m_bible = std::make_unique<BibleService>();
        m_quotation.setSearch([this](const QString& q) {
            return m_bible->search(q, QString());
        });

        if (embedModelPath.isEmpty() || indexPath.isEmpty()) return;

        auto embedder = std::make_unique<narration::OnnxEmbedder>();
        QString err;
        if (!embedder->load(embedModelPath, &err)) {
            qWarning().noquote() << "narration: semantic search unavailable —" << err;
            return;
        }
        // The index records which model built it and the load refuses a
        // mismatch, so a stale index cannot be searched with a new model's
        // queries. That failure would return confident, arbitrary verses.
        if (!m_index.load(indexPath, embedder->modelId(), &err)) {
            qWarning().noquote() << "narration: allusion index not loaded —" << err;
            return;
        }

        m_embedder = std::move(embedder);
        m_allusion.setIndex(&m_index);
        m_allusion.setEmbedder([this](const QString& t) { return m_embedder->embedOne(t); });

        qInfo().noquote() << QStringLiteral("narration: allusion index %1 verses (%2)")
                                 .arg(m_index.count()).arg(m_index.modelId());
    }

    // Called only on the worker thread. Both slow paths in one hop: an
    // embedding is ~47 ms and an FTS pass up to ~63 ms, and neither belongs
    // on the thread drawing the operator's console.
    QList<HeardReference> match(const QString& text, qint64 atMs)
    {
        QList<HeardReference> out = m_quotation.match(text, atMs);
        if (m_allusion.isReady())
            out.append(m_allusion.match(text, atMs));
        return out;
    }

    bool hasAllusion() const { return m_allusion.isReady(); }

private:
    std::unique_ptr<BibleService>           m_bible;
    std::unique_ptr<narration::OnnxEmbedder> m_embedder;
    narration::QuotationMatcher             m_quotation;
    narration::AllusionIndex                m_index;
    narration::AllusionMatcher              m_allusion;
};

// ─────────────────────────────────────────────────────────────────────────

struct NarrationService::Impl
{
    NarrationService*  q          = nullptr;
    BibleService*      bible      = nullptr;
    ProjectionService* projection = nullptr;
    SettingsService*   settings   = nullptr;

    narration::AudioTap*        tap        = nullptr;   // child of q while armed
    narration::VoiceGate        gate;
    narration::CitationDetector citation;
    narration::QuotationMatcher quotation;

    // Note there is no main-thread allusion matcher. A query embedding is
    // ~47 ms and the model is 127 MB; both belong on the worker beside the
    // FTS connection, and a second copy on this thread would double the
    // memory for a path that would still be too slow to run here.

    QThread*                     worker     = nullptr;
    narration::SpeechRecognizer* recognizer = nullptr;

    // Quotation runs off-thread while armed (see QuotationWorker). Both are
    // null when disarmed; injectTranscript falls back to the synchronous
    // matcher above, which is correct for a one-shot from a modal dialog.
    QThread*         quoteThread = nullptr;
    DetectionWorker* quoteWorker = nullptr;

    bool    listening = false;
    QString state     = QStringLiteral("idle");
    QString status;
    QString engineLabel;
    qreal   level  = 0.0;
    bool    speech = false;

    // Rolling capture buffer. While the gate is closed this holds only the
    // pre-roll tail; while it is open it accumulates the whole utterance.
    QList<float> pending;
    bool         speechOpen = false;

    int inFlight   = 0;
    int dropped    = 0;
    // Utterances the voice gate closed and handed to the recognizer. Zero
    // while the meter moves means the gate never opened; non-zero with an
    // empty transcript means the recognizer produced nothing. Those are
    // different faults with different fixes, and this is what tells them
    // apart from the outside.
    int utterances = 0;
    // Session-clock position of the last interim pass, so they run on a
    // cadence rather than once per device buffer.
    qint64 lastInterimMs = -kInterimMs;
    // The in-progress hypothesis, shown live and replaced by each new one.
    // Never appended to the transcript: it is a guess, and a strip filling
    // with ten near-identical guesses per phrase is worse than no strip.
    QString partialText;
    // Bumped on every arm/disarm. Work posted to the recognizer thread carries
    // the generation it was issued under, so a result arriving after the
    // operator disarmed is discarded instead of reviving a dead session.
    int generation = 0;

    QVariantList queue;        // newest first
    QVariantList log;          // oldest first
    QVariantList transcript;   // oldest first, memory only, cleared on arm+disarm
    int          nextId = 1;

    struct Recent { QString reference; qint64 atMs; };
    QList<Recent> recent;

    int prerollSamples() const { return (narration::AudioTap::kTargetRate * kPrerollMs) / 1000; }
    int maxUtteranceSamples() const
    {
        return (narration::AudioTap::kTargetRate * gate.config().maxUtteranceMs) / 1000;
    }

    QString modelPath() const
    {
        return settings ? settings->narrationModelPath() : QString();
    }

    // The configured microphone, resolved against what is plugged in now.
    //
    // A saved id that no longer matches anything falls back to the system
    // default rather than returning null. The operator's chosen microphone
    // being unplugged is a reason to use another one, not a reason to have no
    // sound during a service — and the settings page shows which device is
    // actually in use, so the fallback is visible rather than silent.
    QAudioDevice resolveInputDevice() const
    {
        const QString wanted = settings ? settings->narrationInputDeviceId() : QString();
        if (!wanted.isEmpty()) {
            const auto devices = QMediaDevices::audioInputs();
            for (const QAudioDevice& d : devices)
                if (QString::fromUtf8(d.id()) == wanted) return d;
        }
        return QMediaDevices::defaultAudioInput();
    }

    // The embedding model and the vector index are discovered rather than
    // configured. Both are downloaded together and live beside the speech
    // model, and an operator who has already pointed Crater at one folder
    // should not have to point it at the same folder twice more.
    QStringList assetDirs() const
    {
        QStringList dirs;
        if (!modelPath().isEmpty())
            dirs << QFileInfo(modelPath()).absolutePath();
        dirs << QDir(db::DbPaths::dataDir()).filePath(QStringLiteral("models"));
        dirs.removeDuplicates();
        return dirs;
    }

    QString findAsset(const QStringList& names) const
    {
        for (const QString& d : assetDirs())
            for (const QString& n : names) {
                const QString p = QDir(d).filePath(n);
                if (QFile::exists(p)) return p;
            }
        return QString();
    }

    QString embedModelPath() const
    {
        return findAsset({ QStringLiteral("bge-small-en-v1.5.onnx") });
    }

    // A second, faster model for interim passes only — see
    // SpeechRecognizer::loadDraft.
    //
    // Discovered rather than configured, like the embedding assets: the
    // operator chose one model and should not have to reason about a
    // "hypothesis model" to get live suggestions. If a small one happens to
    // sit beside theirs, we use it; if not, interim passes run on the model
    // they picked and simply arrive later.
    //
    // Candidates in speed order, and the scan stops at the operator's own
    // model rather than passing it. Reaching it means their model is already
    // at least this fast, and a "draft" slower than the real thing is worse
    // than none — it would spend a second model's memory to produce the guess
    // later than the answer.
    QString draftModelPath() const
    {
        static const QStringList kBySpeed = {
            QStringLiteral("ggml-tiny.en-q5_1.bin"), QStringLiteral("ggml-tiny.en.bin"),
            QStringLiteral("ggml-base.en-q5_1.bin"), QStringLiteral("ggml-base.en.bin"),
        };

        const QString mine = QFileInfo(modelPath()).fileName();
        for (const QString& name : kBySpeed) {
            if (name == mine) return QString();
            const QString found = findAsset({ name });
            if (!found.isEmpty()) return found;
        }
        return QString();
    }

    // Prefer an index built from the translation the operator actually reads
    // — a paraphrase sits closer to the wording of the version being preached
    // from — then fall back to the one that ships with every install.
    QString allusionIndexPath() const
    {
        QStringList names;
        if (settings) {
            const QString pref = settings->defaultScriptureVersion();
            if (!pref.isEmpty())
                names << QStringLiteral("allusion-%1.crai").arg(pref);
        }
        names << QStringLiteral("allusion-KJV.crai");
        names.removeDuplicates();
        return findAsset(names);
    }

    // The translation used for existence checks only. Which translation the
    // operator actually projects in is a QML concern — detection returns
    // coordinates and display follows the operator's selection
    // (docs/narration.md §11).
    QString validationTranslation() const
    {
        if (settings) {
            const QString pref = settings->defaultScriptureVersion();
            if (!pref.isEmpty()) return pref;
        }
        if (bible) {
            const auto all = bible->translations();
            if (!all.isEmpty()) return all.first().code;
        }
        return QString();
    }

    void setState(const QString& s, const QString& detail = QString())
    {
        if (state == s && status == detail) return;
        state  = s;
        status = detail;
        emit q->engineStateChanged();
    }

    void drain();
    void dispatchUtterance();
    void trimPending(int keep);
    void onTranscribed(const QString& text, qint64 startedAtMs);
    void onPartial(const QString& text, qint64 startedAtMs);
    void maybeDispatchInterim();
    void appendTranscript(const QString& text, qint64 atMs);
    // `offThread` sends the quotation pass to QuotationWorker instead of
    // running it inline. True for the audio path, false for injectTranscript.
    //
    // `fromPartial` marks detections that came from an in-progress hypothesis.
    // They may queue and they may stage; they may never project. See route().
    void runDetectors(const QString& text, qint64 atMs, bool offThread,
                      bool fromPartial = false);
    void startQuotationWorker();
    void stopQuotationWorker();
    void route(const HeardReference& ref, bool fromPartial = false);
    bool isDuplicate(const HeardReference& ref);
    bool isAlreadyLive(const HeardReference& ref) const;
    // Takes a mutable reference: recording is where a detection acquires its
    // session id, and the caller needs it back so the emitted signal carries
    // the same handle the queue and log do.
    void record(HeardReference& ref, const QString& action, bool enqueue);
    void teardownWorker();
    void stopCapture();
};

// ─────────────────────────────────────────────────────────────────────────

void NarrationService::Impl::trimPending(int keep)
{
    if (keep < 0) keep = 0;
    const int excess = int(pending.size()) - keep;
    if (excess > 0) pending.remove(0, excess);
}

void NarrationService::Impl::drain()
{
    if (!tap) return;

    float buf[kDrainChunk];
    int   n = 0;
    while ((n = tap->read(buf, kDrainChunk)) > 0) {
        // Append first, gate second: an utterance must include the audio that
        // opened it, and the gate reports the boundary only after consuming
        // the frames that crossed it.
        const int old = int(pending.size());
        pending.resize(old + n);
        std::memcpy(pending.data() + old, buf, size_t(n) * sizeof(float));

        const QList<VoiceGate::Event> events = gate.push(buf, n);
        for (const VoiceGate::Event e : events) {
            if (e == VoiceGate::Event::SpeechStarted) {
                speechOpen = true;
                // Keep this chunk plus the pre-roll that preceded it.
                trimPending(prerollSamples() + n);
            } else {
                dispatchUtterance();
                speechOpen = false;
            }
        }

        if (!speechOpen)
            trimPending(prerollSamples());
        else if (int(pending.size()) > maxUtteranceSamples())
            trimPending(maxUtteranceSamples());
    }

    // Still talking? Take a look at what has been said so far. Outside the
    // read loop so one device buffer can never trigger two passes.
    if (speechOpen) maybeDispatchInterim();
}

// Re-transcribe the utterance in progress, at most every kInterimMs.
//
// Deliberately yields to the final pass. Interim work shares kMaxInFlight with
// real utterances, and the check below reserves a slot: a partial that crowds
// out the completed utterance behind it would trade a result the operator can
// act on for a guess that is about to be superseded anyway.
void NarrationService::Impl::maybeDispatchInterim()
{
    if (!recognizer || pending.isEmpty()) return;
    if (inFlight >= kMaxInFlight - 1) return;

    const qint64 nowMs = gate.elapsedMs();
    if (nowMs - lastInterimMs < kInterimMs) return;

    const int haveMs = int(qint64(pending.size()) * 1000 / narration::AudioTap::kTargetRate);
    if (haveMs < kInterimMinMs) return;

    lastInterimMs = nowMs;

    // The tail, not the whole thing, and timestamped to match so the dedupe
    // window lines up with the final pass over the same speech.
    const int window = (narration::AudioTap::kTargetRate * kInterimWindowMs) / 1000;
    const int from   = std::max(0, int(pending.size()) - window);
    QList<float> slice = pending.mid(from);

    const qint64 lengthMs = qint64(pending.size()) * 1000 / narration::AudioTap::kTargetRate;
    const qint64 startMs  = std::max<qint64>(0, nowMs - lengthMs);

    ++inFlight;
    QMetaObject::invokeMethod(
        recognizer,
        [rec = recognizer, samples = std::move(slice), startMs]() mutable {
            rec->transcribeInterim(std::move(samples), startMs);
        },
        Qt::QueuedConnection);
}

void NarrationService::Impl::dispatchUtterance()
{
    if (pending.isEmpty() || !recognizer) { pending.clear(); return; }

    if (inFlight >= kMaxInFlight) {
        ++dropped;
        pending.clear();
        emit q->droppedUtterancesChanged();
        return;
    }

    // The session clock is the gate's, so every timestamp downstream is
    // consistent whether it came from audio or from injectTranscript().
    const qint64 endMs   = gate.elapsedMs();
    const qint64 lengthMs = qint64(pending.size()) * 1000 / narration::AudioTap::kTargetRate;
    const qint64 startMs = std::max<qint64>(0, endMs - lengthMs);

    ++utterances;
    emit q->utterancesHeardChanged();
    qCInfo(lcNarration) << "utterance" << utterances << "-" << lengthMs << "ms of speech"
                        << "-> recognizer";

    ++inFlight;
    QMetaObject::invokeMethod(
        recognizer,
        [rec = recognizer, samples = std::move(pending), startMs]() mutable {
            rec->transcribe(std::move(samples), startMs);
        },
        Qt::QueuedConnection);
    pending.clear();
}

void NarrationService::Impl::onTranscribed(const QString& text, qint64 startedAtMs)
{
    if (inFlight > 0) --inFlight;
    const QString trimmed = text.trimmed();

    // Length, not content, at Info — enough to tell "the recognizer returned
    // nothing" from "the recognizer returned something the detectors ignored",
    // which is the fork every report of "it isn't working" lands on.
    qCInfo(lcNarration) << "transcribed" << trimmed.size() << "chars";
    qCDebug(lcNarration) << "transcript:" << trimmed;

    // The final text supersedes whatever the interim passes were guessing.
    if (!partialText.isEmpty()) {
        partialText.clear();
        emit q->partialTextChanged();
    }

    if (trimmed.isEmpty()) return;
    appendTranscript(trimmed, startedAtMs);
    runDetectors(trimmed, startedAtMs, /*offThread=*/true);
}

// An in-progress hypothesis. Always arrives, even empty, because it is what
// releases the in-flight slot the interim pass reserved.
void NarrationService::Impl::onPartial(const QString& text, qint64 startedAtMs)
{
    if (inFlight > 0) --inFlight;

    const QString trimmed = text.trimmed();
    if (trimmed != partialText) {
        partialText = trimmed;
        emit q->partialTextChanged();
    }
    if (trimmed.isEmpty()) return;

    qCInfo(lcNarration) << "partial" << trimmed.size() << "chars";
    qCDebug(lcNarration) << "partial:" << trimmed;

    // Detection runs on the guess. This is the entire point: it is what puts a
    // suggestion in front of the operator while the sentence is still being
    // spoken. The same verse will be found again by the final pass, and the
    // 20 s de-duplication window in route() collapses the two.
    runDetectors(trimmed, startedAtMs, /*offThread=*/true, /*fromPartial=*/true);
}

// The operator-visible record of what the microphone actually heard.
//
// docs/narration.md §8 scopes transcripts to the session and forbids them
// reaching disk; it does not forbid showing them, and hiding them turned out
// to be a mistake. Without this the console reports only the END of the
// pipeline — a suggestion chip — so every failure anywhere upstream presents
// as the same blank bar, and nobody can tell a dead microphone from a working
// one that heard something the detectors declined.
//
// Memory only, capped, and cleared by both arm() and disarm().
void NarrationService::Impl::appendTranscript(const QString& text, qint64 atMs)
{
    QVariantMap m;
    m.insert(QStringLiteral("text"), text);
    m.insert(QStringLiteral("atMs"), atMs);
    transcript.append(m);

    while (transcript.size() > kTranscriptCap)
        transcript.removeFirst();

    emit q->transcriptChanged();
}

void NarrationService::Impl::runDetectors(const QString& text, qint64 atMs, bool offThread,
                                          bool fromPartial)
{
    // Citation first, and not only for tidiness. A named address is the
    // strongest evidence there is, and routing it first means route()'s
    // de-duplication suppresses the quotation path's weaker hit on the same
    // verse rather than the other way round — "turn to John three sixteen,
    // for God so loved the world" should be recorded as a citation, which is
    // what an operator reading the heard log would expect to see.
    //
    // Cheap enough to stay inline: pure text parsing plus, at most, one
    // indexed single-verse lookup per candidate through the validator.
    const QList<HeardReference> cited = citation.detect(text, atMs);
    for (const HeardReference& r : cited)
        route(r, fromPartial);
    qCInfo(lcNarration) << "citations:" << cited.size();

    if (offThread && quoteWorker) {
        // Fire and forget: quotation AND allusion, in one hop. Results come
        // back on the main thread carrying the generation they were issued
        // under, so anything still in flight when the operator disarms is
        // discarded rather than reviving a queue that was deliberately
        // emptied.
        const int gen = generation;
        DetectionWorker* w = quoteWorker;
        QMetaObject::invokeMethod(
            w,
            [this, w, text, atMs, gen, fromPartial]() {
                const QList<HeardReference> found = w->match(text, atMs);
                qCInfo(lcNarration) << "quotation + allusion:" << found.size();
                if (found.isEmpty()) return;
                QMetaObject::invokeMethod(
                    q,
                    [this, found, gen, fromPartial]() {
                        if (gen != generation) return;
                        for (const HeardReference& r : found) route(r, fromPartial);
                    },
                    Qt::QueuedConnection);
            },
            Qt::QueuedConnection);
        return;
    }

    // Synchronous path: injectTranscript from Settings > Narration while
    // disarmed. The dialog is modal and the operator is waiting for exactly
    // this answer, so there is no frame budget to protect and no worker to
    // spin up.
    //
    // Quotation only. Allusion needs the 127 MB embedding session, and
    // loading it here would stall the dialog for seconds to answer one typed
    // sentence — so testing a paraphrase means arming first, which is stated
    // on the settings page rather than left to be discovered.
    const QList<HeardReference> quoted = quotation.match(text, atMs);
    for (const HeardReference& r : quoted)
        route(r);

}

void NarrationService::Impl::startQuotationWorker()
{
    if (quoteThread || !bible) return;   // no database, nothing to search

    quoteThread = new QThread(q);
    quoteThread->setObjectName(QStringLiteral("narration-quotation"));

    quoteWorker = new DetectionWorker();
    quoteWorker->moveToThread(quoteThread);
    QObject::connect(quoteThread, &QThread::finished, quoteWorker, &QObject::deleteLater);

    quoteThread->start();

    // Resolve the heavy assets on the main thread (cheap file checks) but
    // OPEN them on the worker, so the ONNX session and the SQLite connection
    // both belong to the thread that will use them.
    const QString embedModel = embedModelPath();
    const QString index      = allusionIndexPath();
    DetectionWorker* w = quoteWorker;
    QMetaObject::invokeMethod(w, [w, embedModel, index]() { w->init(embedModel, index); },
                              Qt::QueuedConnection);
}

void NarrationService::Impl::stopQuotationWorker()
{
    if (!quoteThread) return;
    quoteThread->quit();
    quoteThread->wait();
    delete quoteThread;          // deleteLater on `finished` already reaped the worker
    quoteThread = nullptr;
    quoteWorker = nullptr;
}

bool NarrationService::Impl::isDuplicate(const HeardReference& ref)
{
    const qint64 cutoff = ref.atMs - kDedupeWindowMs;
    for (int i = recent.size() - 1; i >= 0; --i) {
        if (recent[i].atMs < cutoff) { recent.remove(i); continue; }
        if (recent[i].reference == ref.reference) return true;
    }
    return false;
}

bool NarrationService::Impl::isAlreadyLive(const HeardReference& ref) const
{
    if (!projection) return false;
    // A cleared output is showing nothing, so re-sending is meaningful again.
    if (projection->isClear()) return false;

    const QVariantMap item = projection->currentItem();
    if (item.value(QStringLiteral("kind")).toString() != QLatin1String("scripture"))
        return false;

    const QVariantMap sr = item.value(QStringLiteral("scriptureRef")).toMap();
    if (sr.isEmpty()) return false;

    if (sr.value(QStringLiteral("book")).toString().compare(ref.book, Qt::CaseInsensitive) != 0)
        return false;
    if (sr.value(QStringLiteral("chapter")).toInt() != ref.chapter)
        return false;

    // Containment, not equality. If John 3:14-17 is on the screen and the
    // preacher says "verse sixteen", the verse is already in front of the
    // congregation and re-sending it would only cause a transition flash.
    return sr.value(QStringLiteral("verseStart")).toInt() <= ref.verseStart
        && sr.value(QStringLiteral("verseEnd")).toInt()   >= ref.verseEnd;
}

void NarrationService::Impl::record(HeardReference& ref,
                                    const QString&  action,
                                    bool            enqueue)
{
    ref.id = nextId++;

    QVariantMap entry = toMap(ref);
    entry.insert(QStringLiteral("action"), action);

    log.append(entry);
    if (log.size() > kLogCap) log.remove(0, log.size() - kLogCap);
    emit q->sessionLogChanged();

    if (!enqueue) return;

    queue.prepend(entry);
    if (queue.size() > kQueueCap) queue.remove(kQueueCap, queue.size() - kQueueCap);
    emit q->heardChanged();
}

void NarrationService::Impl::route(const HeardReference& incoming, bool fromPartial)
{
    if (!incoming.valid()) return;

    HeardReference ref = incoming;

    // Suppressed detections still reach the log — an operator asking "why
    // didn't that fire?" deserves an answer, and "we already had it" is one.
    if (isDuplicate(ref))   { record(ref, QStringLiteral("duplicate"),    false); return; }
    if (isAlreadyLive(ref)) { record(ref, QStringLiteral("already-live"), false); return; }

    recent.append(Recent{ ref.reference, ref.atMs });

    // A partial is a guess about a sentence nobody has finished saying. The
    // gate caps it at "staged" — see TrustGate.h, where that rule sits beside
    // the others it has to be read with.
    const QString action = narration::trust::actionFor(ref.tier, q->mode(), fromPartial);
    record(ref, action, true);   // assigns ref.id, which the signal carries

    if (action == narration::trust::kLive())        emit q->referenceAutoLive(ref);
    else if (action == narration::trust::kStaged()) emit q->referenceStaged(ref);
    else                                            emit q->referenceDetected(ref);
}

void NarrationService::Impl::stopCapture()
{
    if (!tap) return;
    tap->stop();
    tap->deleteLater();
    tap = nullptr;
}

void NarrationService::Impl::teardownWorker()
{
    if (!worker) return;
    // unload() frees the model's several hundred MB. Narration's memory
    // budget only applies while armed (docs/narration.md §9), which is only
    // true if disarming actually gives the memory back.
    if (recognizer) {
        narration::SpeechRecognizer* rec = recognizer;
        QMetaObject::invokeMethod(rec, [rec]() { rec->unload(); }, Qt::QueuedConnection);
    }
    worker->quit();
    worker->wait();
    delete worker;          // deleteLater on `finished` already reaped the recognizer
    worker     = nullptr;
    recognizer = nullptr;
}

// ─────────────────────────────────────────────────────────────────────────

NarrationService::NarrationService(BibleService*      bible,
                                   ProjectionService* projection,
                                   SettingsService*   settings,
                                   QObject*           parent)
    : QObject(parent)
    , m_impl(std::make_unique<Impl>())
{
    m_impl->q          = this;
    m_impl->bible      = bible;
    m_impl->projection = projection;
    m_impl->settings   = settings;

    if (!available())
        m_impl->state = QStringLiteral("unavailable");

    // Resolve the ambiguous-number cases in docs/narration.md §11 ("Psalm one
    // nineteen" — 119, or 1:19?) against the actual canon rather than a
    // hand-maintained chapter table. Narration does not own a second copy of
    // the Bible's shape.
    m_impl->citation.setValidator(
        [this](const QString& book, int chapter, int verse) -> bool {
            if (!m_impl->bible) return true;
            const QString code = m_impl->validationTranslation();
            if (code.isEmpty()) return true;
            return !m_impl->bible->verse(code, book, chapter, verse).text.isEmpty();
        });

    // The quotation path rides on the FTS5 trigram index that already backs
    // the Scripture tab's search box. No second index, no rebuild, no extra
    // disk. Left uninstalled when there is no BibleService, in which case
    // QuotationMatcher::match returns nothing and the pipeline is unaffected.
    //
    // Deliberately unscoped by translation: a preacher quoting the ESV while
    // the operator has KJV selected should still be recognised, and searching
    // every installed translation is what makes that work. The answer is verse
    // coordinates either way, and display follows the operator (§11).
    if (bible) {
        m_impl->quotation.setSearch([this](const QString& andQuery) {
            return m_impl->bible->search(andQuery, QString());
        });
    }

    if (settings) {
        connect(settings, &SettingsService::narrationModeChanged,
                this, &NarrationService::modeChanged);
        connect(settings, &SettingsService::narrationModelPathChanged,
                this, &NarrationService::engineStateChanged);
    }
}

NarrationService::~NarrationService()
{
    // Not disarm() — that emits signals, and a destructor is no place to be
    // notifying QML bindings that are already being torn down.
    m_impl->stopCapture();
    m_impl->teardownWorker();
    m_impl->stopQuotationWorker();
}

// ── Properties ───────────────────────────────────────────────────────────

bool NarrationService::available() const
{
#ifdef CRATER_WITH_WHISPER
    return true;
#else
    return false;
#endif
}

bool NarrationService::modelReady() const
{
    const QString path = m_impl->modelPath();
    if (path.isEmpty()) return false;
    const QFileInfo fi(path);
    return fi.exists() && fi.isFile();
}

bool    NarrationService::listening()     const { return m_impl->listening; }
qreal   NarrationService::inputLevel()    const { return m_impl->level; }
bool    NarrationService::hearingSpeech() const { return m_impl->speech; }
QString NarrationService::engineState()   const { return m_impl->state; }
QString NarrationService::statusMessage() const { return m_impl->status; }
QString NarrationService::engineName()    const { return m_impl->engineLabel; }
QVariantList NarrationService::heard()      const { return m_impl->queue; }
int          NarrationService::heardCount() const { return int(m_impl->queue.size()); }
QVariantList NarrationService::sessionLog() const { return m_impl->log; }
int          NarrationService::droppedUtterances() const { return m_impl->dropped; }

QString NarrationService::mode() const
{
    const QString m = m_impl->settings ? m_impl->settings->narrationMode() : QString();
    return m.isEmpty() ? QStringLiteral("stage") : m;
}

void NarrationService::setMode(const QString& mode)
{
    if (m_impl->settings) m_impl->settings->setNarrationMode(mode);
}

// ── Arming ───────────────────────────────────────────────────────────────

bool NarrationService::arm()
{
    if (m_impl->listening || m_impl->state == QLatin1String("loading"))
        return true;

    if (!available()) {
        m_impl->setState(QStringLiteral("unavailable"),
                         QStringLiteral("This build of Crater was compiled without speech "
                                        "recognition. Rebuild with -DCRATER_WITH_WHISPER=ON."));
        return false;
    }
    if (!modelReady()) {
        m_impl->setState(QStringLiteral("error"),
                         QStringLiteral("No speech model found. Choose one in "
                                        "Settings > Narration."));
        return false;
    }
    if (m_impl->resolveInputDevice().isNull()) {
        m_impl->setState(QStringLiteral("error"),
                         QStringLiteral("No microphone is available."));
        return false;
    }

    const int gen = ++m_impl->generation;

    // A new service starts with a clean sheet. The previous session's log
    // survived its disarm so it could be reviewed; this is where it stops
    // being useful and starts being confusing.
    if (!m_impl->log.isEmpty()) {
        m_impl->log.clear();
        emit sessionLogChanged();
    }
    m_impl->dropped = 0;
    emit droppedUtterancesChanged();
    m_impl->utterances = 0;
    emit utterancesHeardChanged();
    m_impl->lastInterimMs = -kInterimMs;
    if (!m_impl->transcript.isEmpty()) {
        m_impl->transcript.clear();
        emit transcriptChanged();
    }
    if (!m_impl->partialText.isEmpty()) {
        m_impl->partialText.clear();
        emit partialTextChanged();
    }

    qCInfo(lcNarration) << "arming - model" << QFileInfo(m_impl->modelPath()).fileName()
                        << "- device" << m_impl->resolveInputDevice().description();

    m_impl->worker = new QThread(this);
    m_impl->worker->setObjectName(QStringLiteral("narration-recognizer"));

    auto* rec = new narration::WhisperRecognizer();
    rec->moveToThread(m_impl->worker);
    connect(m_impl->worker, &QThread::finished, rec, &QObject::deleteLater);
    connect(rec, &narration::SpeechRecognizer::transcribed, this,
            [this, gen](const QString& text, qint64 atMs) {
                if (gen != m_impl->generation) return;
                m_impl->onTranscribed(text, atMs);
            });
    connect(rec, &narration::SpeechRecognizer::partial, this,
            [this, gen](const QString& text, qint64 atMs) {
                if (gen != m_impl->generation) return;
                m_impl->onPartial(text, atMs);
            });
    connect(rec, &narration::SpeechRecognizer::failed, this,
            [this, gen](const QString& message) {
                if (gen != m_impl->generation) return;
                if (m_impl->inFlight > 0) --m_impl->inFlight;
                m_impl->setState(QStringLiteral("error"), message);
            });

    m_impl->recognizer  = rec;
    m_impl->engineLabel = rec->engineName();
    m_impl->worker->start();

    m_impl->setState(QStringLiteral("loading"), QStringLiteral("Loading speech model..."));

    // Loading is hundreds of milliseconds to seconds of blocking work, so it
    // happens on the worker. Capture deliberately does NOT start until it
    // succeeds: opening the microphone before we can use what it hears would
    // be recording the room for no reason.
    const QString path  = m_impl->modelPath();
    const QString draft = m_impl->draftModelPath();
    QMetaObject::invokeMethod(
        rec,
        [this, rec, path, draft, gen]() {
            QString    error;
            const bool ok = rec->load(path, &error);

            // Best effort, and deliberately non-fatal. A draft that fails to
            // load costs latency, not correctness, and refusing to arm over it
            // would turn an optimisation into a new way for the microphone not
            // to open on a Sunday morning.
            QString draftError;
            if (ok && !draft.isEmpty() && !rec->loadDraft(draft, &draftError))
                qCWarning(lcNarration) << "draft model not loaded -" << draftError;

            // Read on the thread that owns the recognizer. engineName()
            // reflects whether a draft is in use, and reaching for it from the
            // main thread would be reading a field this thread just wrote.
            const QString label = rec->engineName();

            QMetaObject::invokeMethod(
                this,
                [this, ok, error, label, gen]() {
                    if (gen != m_impl->generation) return;
                    if (!ok) {
                        qCWarning(lcNarration) << "speech model failed to load:" << error;
                        m_impl->setState(QStringLiteral("error"), error);
                        m_impl->teardownWorker();
                        return;
                    }
                    // Before startCapture(), whose setState() is what notifies
                    // the property bound to this.
                    m_impl->engineLabel = label;
                    qCInfo(lcNarration) << "speech model loaded" << label
                                        << "- opening the microphone";
                    startCapture();
                },
                Qt::QueuedConnection);
        },
        Qt::QueuedConnection);

    return true;
}

void NarrationService::startCapture()
{
    auto* tap = new narration::AudioTap(this);

    QString error;
    if (!tap->start(m_impl->resolveInputDevice(), &error)) {
        tap->deleteLater();
        // Clear `listening` explicitly rather than assuming it was already
        // false. It is, when arm() calls this — but setInputDevice() also
        // calls it, mid-session, with the microphone already open. Leaving the
        // flag set after a failed open would show a hot indicator over a
        // closed device, which is the one lie this subsystem must never tell.
        qCWarning(lcNarration) << "could not open the microphone:" << error;
        const bool wasListening = m_impl->listening;
        m_impl->listening = false;
        m_impl->setState(QStringLiteral("error"), error);
        m_impl->teardownWorker();
        if (wasListening) emit listeningChanged();
        return;
    }
    qCInfo(lcNarration) << "microphone open:" << tap->deviceName();

    m_impl->tap = tap;
    m_impl->startQuotationWorker();
    m_impl->gate.reset();
    m_impl->pending.clear();
    m_impl->speechOpen = false;
    m_impl->inFlight   = 0;

    connect(tap, &narration::AudioTap::audioReady, this, [this]() { m_impl->drain(); });
    connect(tap, &narration::AudioTap::levelChanged, this, [this]() {
        if (!m_impl->tap) return;
        m_impl->level  = meterFromDb(m_impl->tap->levelDb());
        m_impl->speech = m_impl->gate.inSpeech();
        emit inputLevelChanged();
    });
    connect(tap, &narration::AudioTap::stopped, this, [this](const QString& reason) {
        emit captureLost(reason);
        disarm();
        m_impl->setState(QStringLiteral("error"), reason);
    });

    // Only a real transition emits. A device swap re-enters this function with
    // the microphone already open, and re-announcing "now listening" would
    // make every binding on it re-evaluate for a state that did not change.
    // setState still fires, so the status line picks up the new device name.
    const bool wasListening = m_impl->listening;
    m_impl->listening = true;
    m_impl->setState(QStringLiteral("listening"), tap->deviceName());
    if (!wasListening) emit listeningChanged();
}

void NarrationService::disarm()
{
    const bool wasListening = m_impl->listening;

    ++m_impl->generation;   // orphan anything still in flight

    m_impl->stopCapture();
    m_impl->teardownWorker();
    // Closes the second SQLite connection too. Narration's resources are only
    // held while armed (docs/narration.md §9), and that has to include the
    // ones nobody thinks of as resources.
    m_impl->stopQuotationWorker();

    // Discarded on disarm (docs/narration.md §8): the audio buffer, the
    // reference context, the de-duplication history, and the pending queue.
    // None of it survives the microphone closing and none of it was ever on
    // disk.
    //
    // The session LOG deliberately survives. §8 scopes the discard rule to
    // transcripts and audio; §5 wants "here is everything it heard last
    // Sunday and what it would have done" to be reviewable, and a log wiped
    // by the same click that ends the service could never be. It holds verse
    // references and their short trigger spans, never the transcript, and
    // arm() clears it so a new service starts clean.
    m_impl->pending.clear();
    m_impl->pending.squeeze();
    m_impl->speechOpen = false;
    // The transcript is the one thing here §8 names explicitly: it is
    // discarded when the microphone closes, not merely capped. It exists to
    // be watched live, never to be kept.
    if (!m_impl->transcript.isEmpty()) {
        m_impl->transcript.clear();
        emit transcriptChanged();
    }
    if (!m_impl->partialText.isEmpty()) {
        m_impl->partialText.clear();
        emit partialTextChanged();
    }
    m_impl->lastInterimMs = -kInterimMs;
    m_impl->gate.reset();
    m_impl->citation.resetContext();
    m_impl->recent.clear();
    m_impl->inFlight = 0;
    m_impl->level    = 0.0;
    m_impl->speech   = false;

    m_impl->queue.clear();
    emit heardChanged();
    emit inputLevelChanged();

    m_impl->listening = false;
    if (wasListening) emit listeningChanged();

    m_impl->setState(available() ? QStringLiteral("idle") : QStringLiteral("unavailable"));
}

// ── Queue ────────────────────────────────────────────────────────────────

void NarrationService::dismiss(int id)
{
    for (int i = 0; i < m_impl->queue.size(); ++i) {
        if (m_impl->queue.at(i).toMap().value(QStringLiteral("id")).toInt() != id) continue;
        m_impl->queue.remove(i);
        emit heardChanged();
        return;
    }
}

void NarrationService::dismissAll()
{
    if (m_impl->queue.isEmpty()) return;
    m_impl->queue.clear();
    emit heardChanged();
}

void NarrationService::amendLog(int id, const QString& action)
{
    // Restricted to outcomes the console can legitimately produce after the
    // fact. The log is an audit trail; letting QML write arbitrary strings
    // into it would make "what did the machine do last Sunday" answerable
    // only by trusting whatever the UI happened to say.
    if (action != QLatin1String("cancelled")
        && action != QLatin1String("superseded")
        && action != QLatin1String("live"))
        return;

    for (int i = m_impl->log.size() - 1; i >= 0; --i) {
        QVariantMap e = m_impl->log.at(i).toMap();
        if (e.value(QStringLiteral("id")).toInt() != id) continue;
        e.insert(QStringLiteral("action"), action);
        m_impl->log[i] = e;
        emit sessionLogChanged();
        return;
    }
}

void NarrationService::clearLog()
{
    if (m_impl->log.isEmpty()) return;
    m_impl->log.clear();
    emit sessionLogChanged();
}

QVariantList NarrationService::inputDevices() const
{
    const QAudioDevice defaultIn = QMediaDevices::defaultAudioInput();
    const QString      chosen    = inputDeviceId();

    QVariantList out;
    const auto devices = QMediaDevices::audioInputs();
    out.reserve(devices.size());
    for (const QAudioDevice& d : devices) {
        const QString id = QString::fromUtf8(d.id());
        QVariantMap m;
        m.insert(QStringLiteral("id"),        id);
        m.insert(QStringLiteral("name"),      d.description());
        m.insert(QStringLiteral("isDefault"), d.id() == defaultIn.id());
        // "Selected" means explicitly chosen, so the picker can distinguish
        // "following the system default" from "pinned to this device, which
        // happens to be the default today".
        m.insert(QStringLiteral("isSelected"), !chosen.isEmpty() && chosen == id);
        out.append(m);
    }
    return out;
}

QVariantList NarrationService::transcript() const      { return m_impl->transcript; }
int          NarrationService::utterancesHeard() const { return m_impl->utterances; }
QString      NarrationService::partialText() const     { return m_impl->partialText; }

QString NarrationService::inputDeviceId() const
{
    return m_impl->settings ? m_impl->settings->narrationInputDeviceId() : QString();
}

QString NarrationService::inputDeviceName() const
{
    const QAudioDevice d = m_impl->resolveInputDevice();
    return d.isNull() ? QString() : d.description();
}

void NarrationService::setInputDevice(const QString& id)
{
    if (!m_impl->settings) return;
    if (m_impl->settings->narrationInputDeviceId() == id) return;

    m_impl->settings->setNarrationInputDeviceId(id);
    emit inputDeviceChanged();

    // Not listening: the choice is saved and the next arm() picks it up. No
    // reason to touch the microphone for a preference change.
    if (!m_impl->listening) return;

    // Listening: reopen on the new device. Only the tap is replaced — the
    // loaded model and the detection worker are untouched, because making an
    // operator sit through a model reload to fix a wrong microphone punishes
    // them for correcting it.
    //
    // startCapture() clears the pending buffer and resets the gate, which is
    // exactly right here: samples captured from the device they just rejected
    // have no business landing in an utterance attributed to the new one.
    m_impl->stopCapture();
    startCapture();
}

void NarrationService::injectTranscript(const QString& text)
{
    const QString trimmed = text.trimmed();
    if (trimmed.isEmpty()) return;
    // Uses the gate's clock so injected and heard lines share one timeline,
    // which is what makes context tracking behave identically on both paths.
    // Synchronous by design: the caller is an operator waiting on a modal
    // dialog for this exact answer, and returning before the answer exists
    // would make the feature look broken.
    m_impl->runDetectors(trimmed, m_impl->gate.elapsedMs(), /*offThread=*/false);
}

}  // namespace crater
