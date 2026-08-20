#pragma once

#include "narration/SpeechRecognizer.h"

#include <QList>
#include <QString>

struct whisper_context;

namespace crater::narration {

// whisper.cpp backend. See docs/narration.md §7.1.
//
// Compiled only when CRATER_WITH_WHISPER is defined; the header always
// exists so callers can name the type unconditionally, and the CMake option
// decides whether it links. With the option off, NarrationService falls back
// to NullRecognizer and the rest of the stack still builds and runs.
//
// Threading: this object is meant to be moveToThread()'d onto a dedicated
// worker. whisper_full() is a long blocking call — seconds on a large model —
// and must never run on the thread that draws the projection.
class WhisperRecognizer final : public SpeechRecognizer
{
    Q_OBJECT

public:
    explicit WhisperRecognizer(QObject* parent = nullptr);
    ~WhisperRecognizer() override;

    bool    load(const QString& modelPath, QString* error) override;
    bool    loadDraft(const QString& modelPath, QString* error) override;
    bool    isLoaded()   const override;
    QString engineName() const override;
    void    unload() override;

    // Filename of the draft model in use, empty when interim passes run on
    // the main model. Reported in the engine label so an operator watching
    // suggestions arrive can tell which configuration produced them.
    QString draftName() const;

    // Decode threads. Defaults to (hardware concurrency - 1), leaving one core
    // for the UI and the projection renderer, which have hard frame budgets
    // (architecture.md §6) that a saturated CPU would blow.
    void setThreadCount(int n);
    int  threadCount() const { return m_threads; }

public slots:
    void transcribe(QList<float> mono16k, qint64 startedAtMs) override;
    void transcribeInterim(QList<float> mono16k, qint64 startedAtMs) override;

private:
    // One inference path for both passes, so a fix to the audio handling or
    // the decode parameters cannot land on the final pass and miss the interim
    // one. `mono16k` is taken by reference because it is normalized in place.
    // Only the decode settings differ, and only where the shorter shelf life
    // of a partial hypothesis justifies it.
    //
    // Whisper is compiled out in some builds; this member is declared inside
    // the same guard as the rest of the real implementation would be, but the
    // signature has no whisper types in it, so the header stays unconditional.
    QString run(QList<float>& mono16k, bool interim, QString* error);

    whisper_context* m_ctx     = nullptr;
    // Interim-only context, null when there is no draft model. Two contexts on
    // one thread is deliberate: whisper_full() is single-threaded from the
    // caller's side, so the passes serialize, and serializing them is what
    // keeps a draft pass from stealing cores from the final one it exists to
    // precede.
    whisper_context* m_draft   = nullptr;
    int              m_threads = 0;
    QString          m_modelPath;
    QString          m_draftPath;
};

}  // namespace crater::narration
