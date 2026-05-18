#pragma once

#include <QString>
#include <QStringList>
#include <QList>
#include <QtQmlIntegration>

// crater::lyrics — DSL for marked-up song lyrics.
//
// Storage in song_sections.lines_json is a JSON array of DSL strings, one per
// line. The DSL is a small custom format that supports:
//
//     **bold**                              CommonMark-style bold
//     *italic*                              CommonMark-style italic
//     ++underline++                         markdown-it / HedgeDoc convention
//     {color=red}text{/color}               named color from a 7-entry palette
//     {color=#c33}text{/color}              hex-form color (3 or 6 digits)
//     \*  \{  \\                            backslash-escape any literal
//
// Marks nest freely (bold + color OK), but cannot cross line boundaries — a
// "**" opened on one line MUST close before the trailing newline. This rule
// keeps each line independently parseable and prevents "rest of the song
// became bold" corruption from a single missing close marker.
//
// Why a custom DSL: Qt's built-in MarkdownText parser is sealed (no extension
// hooks), HTML in storage is brittle, and we explicitly want raw-mode editing
// to surface every formatting choice as readable text (no hidden HTML tags).
// See qt/docs/ARCHITECTURE.md and the lyric-formatting design notes for the
// long version.
//
// All functions in this module are pure, side-effect-free, and run on the
// calling thread — no DB, no I/O, no signals. They're unit-tested in
// qt/core/tests/test_lyrics_dsl.cpp.

namespace crater::lyrics {

// One run of contiguously-formatted text inside a line. A line decomposes
// into 1..N runs depending on how many distinct formatting regions appear.
struct Run
{
    Q_GADGET
    Q_PROPERTY(QString text      MEMBER text)
    Q_PROPERTY(bool    bold      MEMBER bold)
    Q_PROPERTY(bool    italic    MEMBER italic)
    Q_PROPERTY(bool    underline MEMBER underline)
    Q_PROPERTY(QString color     MEMBER color)

public:
    QString text;
    bool    bold      = false;
    bool    italic    = false;
    bool    underline = false;
    // Color is stored as the operator wrote it — either a named color
    // ("red", "blue", …) or a hex code ("#c33", "#cc3344"). Resolution
    // to a final paint color happens at render time via resolveColor() so
    // theme-aware remapping stays possible without rewriting stored runs.
    QString color;

    bool operator==(const Run&) const = default;
};

// A line is a flat sequence of runs. Marks cannot cross line boundaries
// (DSL rule v1), so each Line is independently parseable / renderable.
using Line = QList<Run>;

// A Doc is the full lyric block — the lyrics of one section, parsed from
// a single DSL string with newline-separated lines.
using Doc = QList<Line>;

// Parse a DSL string into a Doc.
//
//   - Each newline in `source` produces one Line in the output (an empty
//     trailing line is preserved if `source` ends with "\n").
//   - Plain text (no markers) is valid input and produces single-Run lines.
//   - Malformed input (unclosed markers, unknown color names) degrades
//     gracefully: stray markers are emitted as literal characters where
//     possible, and the parser never throws.
Doc parseDSL(const QString& source);

// Serialize a Doc back to DSL.
//
// Canonical form:
//   - Markers are always emitted in lower-case ASCII (`**`, `*`, `++`,
//     `{color=…}`).
//   - Nesting order from outermost to innermost: color > bold > italic >
//     underline.
//   - Adjacent runs that share marks keep those marks open (no redundant
//     close+reopen pairs).
//
// Round-trip is idempotent: serializeDSL(parseDSL(serializeDSL(x))) ==
// serializeDSL(x) for any well-formed x.
QString serializeDSL(const Doc& doc);

// Flatten a Doc to plain text — drops all marks, joins lines with "\n".
// Used by SongService when populating the FTS5 index so search ranks on
// words, not on markup characters.
QString flattenText(const Doc& doc);

// Resolve a color identifier (named or hex) to a "#rrggbb" / "#rgb" hex
// code. Returns an empty QString when the input is neither a known name
// nor a valid hex code.
//
// Renderers should call this lazily and treat an empty result as "no
// color override" — that way an unknown name in stored DSL doesn't lose
// the operator's text, it just renders in the theme's default color
// while keeping the bad marker visible in raw mode for the operator to
// fix.
QString resolveColor(const QString& nameOrHex);

// The seven recognized named colors, in the canonical palette order used
// by the toolbar swatch. Returned in lowercase. Exposed publicly so the
// QML toolbar can enumerate them without hardcoding the list at the call
// site.
QStringList namedColors();

// ─── HTML emission (for Qt RichText renderers) ───────────────────────────
//
// Storage convention starting in Phase 2: each entry of
// `crater::SongSection::lines` is a DSL string (not plain text). Plain text
// is a valid DSL string with no markers, so existing songs work unchanged.
//
// To render a DSL line through `Text { textFormat: Text.RichText }`, we
// emit an HTML fragment with `<b>`/`<i>`/`<u>` for marks and
// `<span style="color:#xxx;">` for color overrides. The outer Text
// element's font/color act as defaults — runs without a color mark inherit
// from there, so themes still drive the base look.
//
// HTML output is safe to embed in a larger document — text content is
// escaped (`<`, `>`, `&` become entities). Marker nesting matches DSL
// canonical order: color outside, then bold, then italic, then underline.

// Convert one line's runs to an HTML fragment. No trailing newline.
QString runsToHtml(const Line& runs);

// Convenience: parse a single DSL line and emit its HTML. If the input
// contains '\n', everything after the first newline is ignored — by DSL
// rule v1, marks can't cross line boundaries, so callers should split on
// '\n' first if they have multi-line input.
QString dslLineToHtml(const QString& dslLine);

// Convert a multi-line DSL body (one DSL string per line, the canonical
// `SongSection::lines` shape) to HTML with `<br>` between lines. Suitable
// for `Text { textFormat: Text.RichText }`.
QString linesToHtml(const QStringList& dslLines);

// Convert an arbitrary DSL string (which may contain internal '\n' line
// separators) to HTML with `<br>` between lines, optionally applying a
// case transform to the visible text only (markers and color values are
// preserved). `textTransform` accepts the same values as CSS:
//   ""           — no transform (default)
//   "uppercase"  — every letter in run text uppercased
//   "lowercase"  — every letter in run text lowercased
//   "capitalize" — first letter of each word uppercased
// Unknown values are treated as no-op rather than errors — keeps the
// renderer forgiving when a theme stores a value we don't recognize yet.
//
// This is the one-shot entry point for QML renderers (NodeRenderer):
// the input is the resolved text content of a text node, the output is
// HTML ready to feed into a `Text { textFormat: Text.RichText }`.
QString dslToHtml(const QString& dsl, const QString& textTransform = QString());

// ─── FTS5 plain-text projection ──────────────────────────────────────────
//
// Strip all DSL markers from a single line, leaving the plain text content.
// Equivalent to `flattenText(parseDSL(line))` for a single-line input, but
// returns the bare string rather than a Doc — convenient for FTS indexing
// pipelines that want one flattened string per line.
QString flattenLine(const QString& dslLine);

// ─── HTML ingest (for Qt RichText editors) ───────────────────────────────
//
// The reverse of dslToHtml/runsToHtml: parse a Qt-shaped HTML fragment into
// the equivalent DSL string. Used by the rich-text editor when it needs to
// hand its current document content back to the rest of the app in DSL
// form (for storage, FTS, raw-mode display).
//
// Handles two flavors of line breaks that Qt's RichText engine can produce:
//   - Block boundaries (typing Enter creates a new QTextBlock) — these map
//     directly to DSL line boundaries.
//   - U+2028 LINE SEPARATOR chars inside a single block (Qt's parsed form
//     of <br>) — these also map to DSL line boundaries.
//
// The output is canonical DSL — bold uses `**`, italic uses `*`, etc.,
// regardless of which HTML markup the input used. Round-trip through
// dslToHtml -> htmlToDsl is stable for canonical-form input.
QString htmlToDsl(const QString& html);

}  // namespace crater::lyrics
