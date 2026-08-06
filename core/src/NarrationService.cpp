#include "crater/NarrationService.h"

#include "crater/BibleService.h"
#include "crater/ProjectionService.h"
#include "crater/SettingsService.h"

#include "narration/AudioTap.h"
#include "narration/AllusionIndex.h"
#include "narration/AllusionMatcher.h"
#include "narration/CitationDetector.h"
#include "narration/QuotationMatcher.h"
#include "narration/SpeechRecognizer.h"
#include "narration/TrustGate.h"
#include "narration/VoiceGate.h"
#include "narration/WhisperRecognizer.h"

#include <QAudioDevice>
#include <QFileInfo>
#include <QMediaDevices>
#include <QThread>

#include <algorithm>
#include <cmath>
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
class QuotationWorker : public QObject
{
public:
    // Called only on the worker thread.
    QList<HeardReference> match(const QString& text, qint64 atMs)
    {
        if (!m_bible) {
            // Built lazily, and here rather than in the constructor, so the
            // connection and its prepared statements are created on the
            // thread that will use them.
            m_bible = std::make_unique<BibleService>();
            m_matcher.setSearch([this](const QString& q) {
                return m_bible->search(q, QString());
            });
        }
        return m_matcher.match(text, atMs);
    }

private:
    std::unique_ptr<BibleService> m_bible;
    narration::QuotationMatcher   m_matcher;
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

    // Phase 4. Inert until both an index file and an embedder exist, which is
    // the normal state of a build that ships without the embedding model:
    // AllusionMatcher::match returns nothing and every other path is
    // unaffected. See docs/narration.md §7.2.
    narration::AllusionIndex    allusionIndex;
    narration::AllusionMatcher  allusion;

    QThread*                     worker     = nullptr;
    narration::SpeechRecognizer* recognizer = nullptr;

    // Quotation runs off-thread while armed (see QuotationWorker). Both are
    // null when disarmed; injectTranscript falls back to the synchronous
    // matcher above, which is correct for a one-shot from a modal dialog.
    QThread*         quoteThread = nullptr;
    QuotationWorker* quoteWorker = nullptr;

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
    // Bumped on every arm/disarm. Work posted to the recognizer thread carries
    // the generation it was issued under, so a result arriving after the
    // operator disarmed is discarded instead of reviving a dead session.
    int generation = 0;

    QVariantList queue;   // newest first
    QVariantList log;     // oldest first
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
    // `offThread` sends the quotation pass to QuotationWorker instead of
    // running it inline. True for the audio path, false for injectTranscript.
    void runDetectors(const QString& text, qint64 atMs, bool offThread);
    void runAllusion(const QString& text, qint64 atMs);
    void startQuotationWorker();
    void stopQuotationWorker();
    void route(const HeardReference& ref);
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
    if (trimmed.isEmpty()) return;
    runDetectors(trimmed, startedAtMs, /*offThread=*/true);
}

void NarrationService::Impl::runDetectors(const QString& text, qint64 atMs, bool offThread)
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
        route(r);

    if (offThread && quoteWorker) {
        // Fire and forget. Results come back on the main thread carrying the
        // generation they were issued under, so anything still in flight when
        // the operator disarms is discarded rather than reviving a queue that
        // was deliberately emptied.
        const int gen = generation;
        QuotationWorker* w = quoteWorker;
        QMetaObject::invokeMethod(
            w,
            [this, w, text, atMs, gen]() {
                const QList<HeardReference> found = w->match(text, atMs);
                if (found.isEmpty()) return;
                QMetaObject::invokeMethod(
                    q,
                    [this, found, gen]() {
                        if (gen != generation) return;
                        for (const HeardReference& r : found) route(r);
                    },
                    Qt::QueuedConnection);
            },
            Qt::QueuedConnection);
        return;
    }

    // Synchronous path: injectTranscript from Settings > Narration. The
    // dialog is modal and the operator is waiting for exactly this answer, so
    // there is no frame budget to protect and no worker to spin up.
    const QList<HeardReference> quoted = quotation.match(text, atMs);
    for (const HeardReference& r : quoted)
        route(r);

    runAllusion(text, atMs);
}

void NarrationService::Impl::runAllusion(const QString& text, qint64 atMs)
{
    // Last, deliberately. Citation and quotation are stronger evidence for
    // the same verse, and route()'s de-duplication keeps whichever arrived
    // first — so a paraphrase of a verse the preacher also named is recorded
    // as the citation it really was.
    if (!allusion.isReady()) return;
    const QList<HeardReference> alluded = allusion.match(text, atMs);
    for (const HeardReference& r : alluded)
        route(r);
}

void NarrationService::Impl::startQuotationWorker()
{
    if (quoteThread || !bible) return;   // no database, nothing to search

    quoteThread = new QThread(q);
    quoteThread->setObjectName(QStringLiteral("narration-quotation"));

    quoteWorker = new QuotationWorker();
    quoteWorker->moveToThread(quoteThread);
    QObject::connect(quoteThread, &QThread::finished, quoteWorker, &QObject::deleteLater);

    quoteThread->start();
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

void NarrationService::Impl::route(const HeardReference& incoming)
{
    if (!incoming.valid()) return;

    HeardReference ref = incoming;

    // Suppressed detections still reach the log — an operator asking "why
    // didn't that fire?" deserves an answer, and "we already had it" is one.
    if (isDuplicate(ref))   { record(ref, QStringLiteral("duplicate"),    false); return; }
    if (isAlreadyLive(ref)) { record(ref, QStringLiteral("already-live"), false); return; }

    recent.append(Recent{ ref.reference, ref.atMs });

    const QString action = narration::trust::actionFor(ref.tier, q->mode());
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
    if (QMediaDevices::defaultAudioInput().isNull()) {
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
    const QString path = m_impl->modelPath();
    QMetaObject::invokeMethod(
        rec,
        [this, rec, path, gen]() {
            QString    error;
            const bool ok = rec->load(path, &error);
            QMetaObject::invokeMethod(
                this,
                [this, ok, error, gen]() {
                    if (gen != m_impl->generation) return;
                    if (!ok) {
                        m_impl->setState(QStringLiteral("error"), error);
                        m_impl->teardownWorker();
                        return;
                    }
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
    if (!tap->start(&error)) {
        tap->deleteLater();
        m_impl->setState(QStringLiteral("error"), error);
        m_impl->teardownWorker();
        return;
    }

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

    m_impl->listening = true;
    m_impl->setState(QStringLiteral("listening"), tap->deviceName());
    emit listeningChanged();
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

    QVariantList out;
    const auto devices = QMediaDevices::audioInputs();
    out.reserve(devices.size());
    for (const QAudioDevice& d : devices) {
        QVariantMap m;
        m.insert(QStringLiteral("id"),        QString::fromUtf8(d.id()));
        m.insert(QStringLiteral("name"),      d.description());
        m.insert(QStringLiteral("isDefault"), d.id() == defaultIn.id());
        out.append(m);
    }
    return out;
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
