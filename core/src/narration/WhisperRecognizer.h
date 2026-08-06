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
    bool    isLoaded()   const override;
    QString engineName() const override;
    void    unload() override;

    // Decode threads. Defaults to (hardware concurrency - 1), leaving one core
    // for the UI and the projection renderer, which have hard frame budgets
    // (architecture.md §6) that a saturated CPU would blow.
    void setThreadCount(int n);
    int  threadCount() const { return m_threads; }

public slots:
    void transcribe(QList<float> mono16k, qint64 startedAtMs) override;

private:
    whisper_context* m_ctx     = nullptr;
    int              m_threads = 0;
    QString          m_modelPath;
};

}  // namespace crater::narration
