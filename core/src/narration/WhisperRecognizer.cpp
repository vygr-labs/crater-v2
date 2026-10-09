#include "narration/WhisperRecognizer.h"

#include <QFileInfo>
#include <QThread>

#ifdef CRATER_WITH_WHISPER
#include <whisper.h>
#endif

#include <algorithm>
#include <cmath>

namespace crater::narration {

namespace {
// Below this, whisper produces noise from room tone. Guards against a gate
// that latched on a door slam.
constexpr int kMinSamples = 16000 / 4;   // 250 ms

// Whisper is trained on roughly normalized speech, and a congregation
// microphone six feet from a preacher does not deliver that: a laptop array at
// conversational distance lands around -30 dBFS peak, which is a sixth of full
// scale. The model still returns *something* for quiet input, and that
// something is where the invented words come from.
//
// So level the utterance before inference. This is gain, not compression —
// every sample scales by one factor, so nothing about the speech changes
// except how loud it is.
constexpr float kTargetPeak = 0.90f;
// A ceiling on the gain, so a near-silent buffer cannot be blown up to full
// scale.
constexpr float kMaxGain    = 25.0f;

// ── The silence floor ────────────────────────────────────────────────────
//
// Below this the buffer is a room, not a voice — and whisper's behaviour on
// an amplified room is the worst latency case in this system by a wide
// margin. Measured on a real desk-microphone recording: five seconds of a
// quiet office cost 4.8 s idle and 18-26 s under load, to return an empty
// string. Ten seconds of the same room came back "(clippers buzzing)". Every
// one of those seconds is a second the recognizer thread is not available for
// the sentence the preacher is actually saying, and with only kMaxInFlight
// slots upstream it is also where dropped utterances come from.
//
// RMS, not peak, and that distinction is the entire fix. This gate used to
// read the loudest single sample, which a door click or a plosive clears
// easily while carrying no speech at all — so a silent buffer with one
// transient in it was licensing 25x gain on ventilation noise, and whisper
// was dutifully finding words in the result.
//
// Measured levels from that recording: a window containing speech sits at
// -40 dBFS RMS, the same room without it at -66 to -70. The floor is set in
// the middle of that 25 dB gap. It is also deliberately far looser than
// VoiceGate's -38 dBFS speech threshold, so anything the gate was confident
// enough to send here passes comfortably; this catches what the gate let
// through, not what it decided.
constexpr float kSpeechRmsFloor = 0.0018f;   // about -55 dBFS

float rmsOf(const QList<float>& samples)
{
    if (samples.isEmpty()) return 0.0f;
    double sumSq = 0.0;
    for (const float v : samples) sumSq += double(v) * double(v);
    return float(std::sqrt(sumSq / double(samples.size())));
}

// ── Encoder context ──────────────────────────────────────────────────────
//
// whisper pads every input to a 30-second mel spectrogram before the encoder
// runs. A two-second clip therefore costs very nearly what a thirty-second
// one does, which is why the interim pass does not get cheaper simply by
// being handed less audio — and why shortening the interim window, on its
// own, buys much less than it looks like it should.
//
// audio_ctx caps how much of that padded window the encoder attends to, and
// it is the only parameter that makes encoder cost track the audio actually
// present. Halving it roughly halves the dominant term.
//
// Interim only. The final pass is the answer an operator acts on; trading its
// accuracy for latency it does not have would be spending the wrong currency.
constexpr int kFullAudioCtx = 1500;   // 30 s at 50 encoder frames/s
// A floor rather than a strict proportion: below roughly this, the encoder
// loses enough context that the text degrades faster than the time saved is
// worth. Even at the floor a five-second window costs about half of full.
constexpr int kMinAudioCtx  = 768;

// Encoder frames to allow for `samples` of 16 kHz audio, with two seconds of
// headroom so a window that fills up mid-pass isn't clipped by its own budget.
int audioCtxFor(qsizetype samples)
{
    constexpr int kRate   = 16000;
    const int     seconds = int((samples + kRate - 1) / kRate) + 2;
    const int     want    = (seconds * kFullAudioCtx) / 30;
    return std::clamp(want, kMinAudioCtx, kFullAudioCtx);
}

// Scale to kTargetPeak in place. Also attenuates: a hot desk mic that clips
// is just as bad for recognition as a quiet one.
//
// The caller has already established there is speech here (see
// kSpeechRmsFloor), so this only has to decide how much headroom the peak
// leaves to use.
void normalize(QList<float>& samples)
{
    float peak = 0.0f;
    for (const float v : samples) peak = std::max(peak, std::fabs(v));
    if (peak <= 0.0f) return;

    const float gain = std::min(kMaxGain, kTargetPeak / peak);
    // Nothing to do when it is already at the right level.
    if (gain > 0.99f && gain < 1.01f) return;

    for (float& v : samples) v *= gain;
}
}  // namespace

WhisperRecognizer::WhisperRecognizer(QObject* parent)
    : SpeechRecognizer(parent)
{
    // Leave a core for the UI thread and the projection renderer. Saturating
    // every core is measurably faster at transcription and measurably worse
    // at holding the frame budget in architecture.md §6, and dropped frames
    // on the audience screen are the more expensive failure.
    const int cores = std::max(1, QThread::idealThreadCount());
    m_threads       = std::max(1, cores - 1);
}

WhisperRecognizer::~WhisperRecognizer()
{
    unload();
}

QString WhisperRecognizer::engineName() const
{
#ifdef CRATER_WITH_WHISPER
    // Name the draft when there is one. Two models behave visibly differently
    // — suggestions appear early and then get corrected — and an operator who
    // cannot see that configuration would read the correction as a bug.
    const QString draft = draftName();
    if (draft.isEmpty()) return QStringLiteral("whisper.cpp");
    return QStringLiteral("whisper.cpp + %1 draft").arg(draft);
#else
    return QStringLiteral("whisper.cpp (not compiled in)");
#endif
}

QString WhisperRecognizer::draftName() const
{
    return m_draftPath.isEmpty() ? QString() : QFileInfo(m_draftPath).fileName();
}

void WhisperRecognizer::setThreadCount(int n)
{
    m_threads = std::max(1, n);
}

#ifdef CRATER_WITH_WHISPER

namespace {
// One place that knows how to open a ggml model, so the main and draft paths
// cannot drift apart in their context parameters.
whisper_context* openModel(const QString& modelPath, QString* error)
{
    const QFileInfo fi(modelPath);
    if (!fi.exists() || !fi.isFile()) {
        if (error) *error = QStringLiteral("Speech model not found at %1").arg(modelPath);
        return nullptr;
    }

    whisper_context_params cparams = whisper_context_default_params();
    // GPU offload where the platform has it. Falls back to CPU on its own,
    // so this is safe to leave on for the low-end machines that will simply
    // never satisfy it.
    cparams.use_gpu = true;

    whisper_context* ctx =
        whisper_init_from_file_with_params(modelPath.toLocal8Bit().constData(), cparams);
    if (!ctx && error)
        *error = QStringLiteral("Failed to load speech model %1").arg(fi.fileName());
    return ctx;
}
}  // namespace

bool WhisperRecognizer::load(const QString& modelPath, QString* error)
{
    // Replaces the main context only. A draft loaded earlier survives, because
    // the two are chosen independently and dropping one as a side effect of
    // setting the other would be a trap for any future caller that reloads.
    if (m_ctx) {
        whisper_free(m_ctx);
        m_ctx = nullptr;
        m_modelPath.clear();
    }

    m_ctx = openModel(modelPath, error);
    if (!m_ctx) return false;

    m_modelPath = modelPath;
    return true;
}

bool WhisperRecognizer::loadDraft(const QString& modelPath, QString* error)
{
    if (m_draft) {
        whisper_free(m_draft);
        m_draft = nullptr;
        m_draftPath.clear();
    }
    if (modelPath.isEmpty()) return false;

    m_draft = openModel(modelPath, error);
    if (!m_draft) return false;

    m_draftPath = modelPath;
    return true;
}

bool WhisperRecognizer::isLoaded() const
{
    // The main model, and only it. A draft is an optimisation; a recognizer
    // holding one and nothing else can answer no question anyone asked.
    return m_ctx != nullptr;
}

void WhisperRecognizer::unload()
{
    if (m_ctx) {
        whisper_free(m_ctx);
        m_ctx = nullptr;
        m_modelPath.clear();
    }
    if (m_draft) {
        whisper_free(m_draft);
        m_draft = nullptr;
        m_draftPath.clear();
    }
}

QString WhisperRecognizer::run(QList<float>& mono16k, bool interim, QString* error)
{
    // Cheapest possible answer for the most expensive possible input. An
    // empty string is also the correct one: there are no words in a quiet
    // room, and spending twenty seconds of the recognizer thread confirming
    // that is how the pipeline falls behind the preacher.
    if (rmsOf(mono16k) < kSpeechRmsFloor) return QString();

    normalize(mono16k);

    // The draft model answers interim passes when there is one. Falling back
    // to the main context rather than refusing is what makes the draft purely
    // an optimisation: with no draft on disk the feature still works, just
    // later.
    whisper_context* ctx = (interim && m_draft) ? m_draft : m_ctx;
    if (!ctx) {
        if (error) *error = QStringLiteral("No speech model is loaded.");
        return QString();
    }

    whisper_full_params p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    p.n_threads           = m_threads;
    p.print_progress      = false;
    p.print_realtime      = false;
    p.print_timestamps    = false;
    p.print_special       = false;
    p.translate           = false;
    p.single_segment      = interim;
    p.language            = "en";
    // We already segmented on speech pauses, so whisper's own windowing would
    // only re-cut what VoiceGate handed it.
    //
    // Not setting the non-speech-token suppression flag here: it was renamed
    // (suppress_non_speech_tokens -> suppress_nst) across the versions we may
    // pin to, and a compile break on a field name isn't worth the marginal
    // gain. The detectors ignore "[BLANK_AUDIO]"-style artifacts anyway,
    // since neither matches a book name or a number.
    p.no_context          = true;

    // An interim pass runs while the speaker is still talking, and another
    // one follows a second later. Spending temperature fallbacks on a
    // hypothesis with that shelf life would only make the NEXT one late.
    if (interim) {
        p.temperature_inc = 0.0f;
        p.max_tokens      = 96;
        p.audio_ctx       = audioCtxFor(mono16k.size());
    }

    const int rc = whisper_full(ctx, p, mono16k.constData(), int(mono16k.size()));
    if (rc != 0) {
        if (error) *error = QStringLiteral("Speech recognition failed (code %1).").arg(rc);
        return QString();
    }

    QString text;
    const int segments = whisper_full_n_segments(ctx);
    for (int i = 0; i < segments; ++i) {
        if (const char* s = whisper_full_get_segment_text(ctx, i))
            text += QString::fromUtf8(s);
    }
    return text.simplified();
}

void WhisperRecognizer::transcribe(QList<float> mono16k, qint64 startedAtMs)
{
    if (!m_ctx) {
        emit failed(QStringLiteral("No speech model is loaded."));
        return;
    }
    if (mono16k.size() < kMinSamples) {
        emit transcribed(QString(), startedAtMs);
        return;
    }

    QString error;
    const QString text = run(mono16k, /*interim=*/false, &error);
    if (!error.isEmpty()) {
        emit failed(error);
        return;
    }
    emit transcribed(text, startedAtMs);
}

// The same inference on audio that is still arriving. Emits partial(), which
// callers may run detection on but must never project from — see the contract
// on SpeechRecognizer::partial and docs/narration.md §5.
void WhisperRecognizer::transcribeInterim(QList<float> mono16k, qint64 startedAtMs)
{
    // Every path emits exactly once, including the ones with nothing to say.
    // The caller reserved an in-flight slot for this pass and releases it on
    // the signal; returning quietly would leak that slot permanently.
    if (!m_ctx || mono16k.size() < kMinSamples) {
        emit partial(QString(), startedAtMs);
        return;
    }

    QString error;
    const QString text = run(mono16k, /*interim=*/true, &error);

    // A failed interim pass is not worth an error state. The utterance is
    // still in progress and its final pass is the one that has to succeed;
    // reporting this would put "Speech recognition failed" in front of the
    // operator for a hypothesis that was never promised.
    emit partial(error.isEmpty() ? text : QString(), startedAtMs);
}

#else  // !CRATER_WITH_WHISPER

// Stub bodies so the type is nameable and the stack links with the option
// off. Every entry point fails loudly rather than silently pretending to
// listen, which would be indistinguishable from a preacher who hasn't cited
// anything yet.

bool WhisperRecognizer::load(const QString&, QString* error)
{
    if (error) {
        *error = QStringLiteral(
            "This build of Crater was compiled without speech recognition "
            "(configure with -DCRATER_WITH_WHISPER=ON).");
    }
    return false;
}

bool WhisperRecognizer::loadDraft(const QString&, QString* error)
{
    if (error) *error = QStringLiteral("This build of Crater has no speech recognition.");
    return false;
}

bool WhisperRecognizer::isLoaded() const { return false; }

void WhisperRecognizer::unload() {}

QString WhisperRecognizer::run(QList<float>&, bool, QString* error)
{
    if (error) *error = QStringLiteral("This build of Crater has no speech recognition.");
    return QString();
}

void WhisperRecognizer::transcribe(QList<float>, qint64)
{
    emit failed(QStringLiteral("This build of Crater was compiled without speech recognition."));
}

// No failed() here, unlike transcribe(). An interim pass is speculative, and a
// build with no recognizer should say so once when the operator arms rather
// than once per second while they speak. The empty partial() is still
// mandatory — it is what releases the caller's in-flight slot.
void WhisperRecognizer::transcribeInterim(QList<float>, qint64 startedAtMs)
{
    emit partial(QString(), startedAtMs);
}

#endif  // CRATER_WITH_WHISPER

}  // namespace crater::narration
