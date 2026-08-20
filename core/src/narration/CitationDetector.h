#pragma once

#include "crater/value/HeardReference.h"

#include <QList>
#include <QString>

#include <functional>
#include <utility>

namespace crater::narration {

// What the preacher is currently working inside. See docs/narration.md §6.
//
// This is the highest-leverage piece of the subsystem and it's nearly free.
// Preachers state a full reference once and then live inside it: "verse nine",
// "look at verse twelve", "the next verse". Without this, the feature dies
// exactly where the sermon actually happens.
struct RefContext
{
    QString book;
    int     chapter   = 0;
    int     lastVerse = 0;
    qint64  atMs      = -1;

    bool valid() const { return !book.isEmpty() && chapter > 0 && atMs >= 0; }
};

// Spoken reference to a parseReference-ready string. Pure: no DB, no audio,
// no Qt GUI. Everything it needs from the Bible lives behind the optional
// validator below, which is what keeps it unit-testable against transcript
// fixtures with no database present (docs/narration.md §10, phase 0).
class CitationDetector
{
public:
    // A bare "verse nine" recovered from context this stale is a coin flip.
    // Sermons wander; six minutes without scripture activity means whatever
    // chapter we were in is no longer a safe assumption.
    static constexpr qint64 kContextTtlMs = 6 * 60 * 1000;

    // Answers "does book chapter:verse exist?". Defaults to accepting
    // everything, which is correct for pure parsing tests. NarrationService
    // installs a BibleService-backed implementation so the ambiguous-number
    // rule in docs/narration.md §11 can actually resolve.
    using Validator = std::function<bool(const QString& book, int chapter, int verse)>;
    void setValidator(Validator v) { m_validate = std::move(v); }

    // Detect every citation in one utterance, in order. `nowMs` is monotonic
    // milliseconds since the session was armed.
    QList<crater::HeardReference> detect(const QString& utterance, qint64 nowMs);

    const RefContext& context() const { return m_ctx; }
    void setContext(RefContext ctx) { m_ctx = std::move(ctx); }
    void resetContext() { m_ctx = RefContext{}; }

private:
    RefContext m_ctx;
    Validator  m_validate;
};

}  // namespace crater::narration
