#pragma once

#include <QString>

// crater::rtf — minimal RTF-to-plain-text extraction.
//
// This is NOT a general RTF renderer. It exists for one job: pull the
// readable text out of the RTF blobs EasyWorship stores in its SongWords.db
// `word.words` column, so the song importer can recover lyric lines.
//
// Qt ships no RTF reader (QTextDocument speaks HTML and Markdown only), so
// this is hand-written. It is deliberately small and forgiving: anything it
// does not understand is skipped rather than treated as an error.
//
// Pure and side-effect-free — no I/O, no Qt GUI types — so it stays inside
// crater-core per ARCHITECTURE.md §1 and is unit-testable headlessly.

namespace crater::rtf {

// Extract plain text from an RTF document.
//
//   - Control groups that carry no readable content — \fonttbl, \colortbl,
//     \stylesheet, \info, and \*\... ignorable destinations — are skipped
//     wholesale.
//   - \par / \line / \sect become '\n'; \tab becomes '\t'.
//   - \'hh hex escapes are decoded as Windows-1252 (the code page EasyWorship
//     writes), so curly quotes and accented characters survive.
//   - \uN unicode escapes are decoded to their code point; the matching \ucN
//     fallback characters are then skipped.
//
// Input that is not RTF at all (no "\rtf" marker) is returned trimmed but
// otherwise unchanged, so callers may treat it as plain text.
QString toPlainText(const QString& rtf);

}  // namespace crater::rtf
