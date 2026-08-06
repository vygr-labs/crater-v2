#include "narration/WhisperRecognizer.h"

#include <QFileInfo>
#include <QThread>

#ifdef CRATER_WITH_WHISPER
#include <whisper.h>
#endif

#include <algorithm>

namespace crater::narration {

namespace {
// Below this, whisper produces noise from room tone. Guards against a gate
// that latched on a door slam.
constexpr int kMinSamples = 16000 / 4;   // 250 ms
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
    return QStringLiteral("whisper.cpp");
#else
    return QStringLiteral("whisper.cpp (not compiled in)");
#endif
}

void WhisperRecognizer::setThreadCount(int n)
{
    m_threads = std::max(1, n);
}

#ifdef CRATER_WITH_WHISPER

bool WhisperRecognizer::load(const QString& modelPath, QString* error)
{
    unload();

    const QFileInfo fi(modelPath);
    if (!fi.exists() || !fi.isFile()) {
        if (error) *error = QStringLiteral("Speech model not found at %1").arg(modelPath);
        return false;
    }

    whisper_context_params cparams = whisper_context_default_params();
    // GPU offload where the platform has it. Falls back to CPU on its own,
    // so this is safe to leave on for the low-end machines that will simply
    // never satisfy it.
    cparams.use_gpu = true;

    m_ctx = whisper_init_from_file_with_params(modelPath.toLocal8Bit().constData(), cparams);
    if (!m_ctx) {
        if (error) *error = QStringLiteral("Failed to load speech model %1").arg(fi.fileName());
        return false;
    }

    m_modelPath = modelPath;
    return true;
}

bool WhisperRecognizer::isLoaded() const
{
    return m_ctx != nullptr;
}

void WhisperRecognizer::unload()
{
    if (!m_ctx) return;
    whisper_free(m_ctx);
    m_ctx = nullptr;
    m_modelPath.clear();
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

    whisper_full_params p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    p.n_threads           = m_threads;
    p.print_progress      = false;
    p.print_realtime      = false;
    p.print_timestamps    = false;
    p.print_special       = false;
    p.translate           = false;
    p.single_segment      = false;
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

    const int rc = whisper_full(m_ctx, p, mono16k.constData(), int(mono16k.size()));
    if (rc != 0) {
        emit failed(QStringLiteral("Speech recognition failed (code %1).").arg(rc));
        return;
    }

    QString text;
    const int segments = whisper_full_n_segments(m_ctx);
    for (int i = 0; i < segments; ++i) {
        if (const char* s = whisper_full_get_segment_text(m_ctx, i))
            text += QString::fromUtf8(s);
    }

    emit transcribed(text.simplified(), startedAtMs);
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

bool WhisperRecognizer::isLoaded() const { return false; }

void WhisperRecognizer::unload() {}

void WhisperRecognizer::transcribe(QList<float>, qint64)
{
    emit failed(QStringLiteral("This build of Crater was compiled without speech recognition."));
}

#endif  // CRATER_WITH_WHISPER

}  // namespace crater::narration
