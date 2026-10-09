#pragma once

#include <QObject>
#include <QString>
#include <QtQmlIntegration>

namespace crater {

// A scripture reference the narration subsystem heard in the preacher's
// speech. See docs/narration.md §2 — all three detection paths (citation,
// quotation, allusion) converge on this one type, so everything downstream
// (context tracking, the trust gate, the operator UI) is written once.
//
// `reference` is the normalized textual form — it is deliberately shaped to
// be fed straight into BibleService::parseReference rather than resolved
// here. Narration does not own a second book-name resolver.
struct HeardReference
{
    Q_GADGET
    QML_VALUE_TYPE(heardReference)
    Q_PROPERTY(QString reference  MEMBER reference)
    Q_PROPERTY(QString book       MEMBER book)
    Q_PROPERTY(int     chapter    MEMBER chapter)
    Q_PROPERTY(int     verseStart MEMBER verseStart)
    Q_PROPERTY(int     verseEnd   MEMBER verseEnd)
    Q_PROPERTY(QString tier       MEMBER tier)
    Q_PROPERTY(QString kind       MEMBER kind)
    Q_PROPERTY(QString heardText  MEMBER heardText)
    Q_PROPERTY(qint64  atMs       MEMBER atMs)
    Q_PROPERTY(int     id         MEMBER id)
    Q_PROPERTY(bool    valid      READ valid CONSTANT)

public:
    // "1 Corinthians 13:4" / "John 3:16" — parseReference-ready.
    QString reference;
    QString book;
    int     chapter    = 0;
    int     verseStart = 0;
    int     verseEnd   = 0;   // == verseStart for a single verse

    // Evidence quality, NOT a tuned score — see docs/narration.md §5. The
    // tier is a property of which path produced the hit, and it is what the
    // trust gate keys off:
    //   "certain"  — the preacher spoke the address out loud
    //   "high"     — unambiguous but inferred (context, or verbatim quote)
    //   "possible" — a guess; never reaches the projector on its own
    QString tier;

    // "citation" | "quotation" | "allusion"
    QString kind;

    // The transcript span that triggered this. Retained for the heard log so
    // an operator can audit why something fired; the full transcript is not
    // retained (docs/narration.md §8).
    QString heardText;

    // Monotonic milliseconds since the narration session was armed.
    qint64  atMs = 0;

    // Session-unique handle, assigned when the trust gate records the
    // detection. The heard queue, the session log and the signal all carry
    // the same value, which is what lets the console amend a decision after
    // the fact — an Auto-mode projection the operator cancels during its
    // grace period has to be findable in the log to be marked cancelled.
    // Zero on a detection that has not been recorded (a bare parse result).
    int     id = 0;

    bool valid() const { return !book.isEmpty() && chapter > 0; }
};

}  // namespace crater
