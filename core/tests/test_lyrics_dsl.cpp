// Tests for crater::lyrics — the DSL parser, canonical serializer, FTS
// flattener, and color resolver.
//
// Run via CTest: `ctest --test-dir <build-dir> -R lyrics_dsl --output-on-failure`
// Or directly:   `./test_lyrics_dsl` from the build output directory.
//
// Coverage philosophy: every public function in LyricsDSL.h has at least one
// passing test, plus targeted tests for the round-trip invariant
// (serializeDSL(parseDSL(serializeDSL(x))) == serializeDSL(x)) since that's
// the load-bearing property the rest of the pipeline assumes.

#include <QObject>
#include <QString>
#include <QTest>

#include "crater/LyricsDSL.h"

using crater::lyrics::Doc;
using crater::lyrics::Line;
using crater::lyrics::Run;
using crater::lyrics::dslLineToHtml;
using crater::lyrics::dslToHtml;
using crater::lyrics::flattenLine;
using crater::lyrics::flattenText;
using crater::lyrics::htmlToDsl;
using crater::lyrics::linesToHtml;
using crater::lyrics::namedColors;
using crater::lyrics::parseDSL;
using crater::lyrics::resolveColor;
using crater::lyrics::runsToHtml;
using crater::lyrics::serializeDSL;

namespace {

// Tiny constructor helper so test cases read top-to-bottom without QList
// nesting boilerplate. `mk("hello", true)` builds a bold "hello" run.
Run mk(const QString& text,
       bool bold = false, bool italic = false, bool underline = false,
       const QString& color = QString())
{
    Run r;
    r.text      = text;
    r.bold      = bold;
    r.italic    = italic;
    r.underline = underline;
    r.color     = color;
    return r;
}

}  // namespace

class TestLyricsDSL : public QObject
{
    Q_OBJECT

private slots:
    // ── parseDSL ─────────────────────────────────────────────────────────

    void parse_plainText()
    {
        const Doc d = parseDSL(QStringLiteral("hello world"));
        QCOMPARE(d.size(), 1);
        QCOMPARE(d[0].size(), 1);
        QCOMPARE(d[0][0], mk("hello world"));
    }

    void parse_emptyString()
    {
        // Empty input yields one empty Line — gives editors a row to type into.
        const Doc d = parseDSL(QString());
        QCOMPARE(d.size(), 1);
        QCOMPARE(d[0].size(), 0);
    }

    void parse_bold()
    {
        const Doc d = parseDSL(QStringLiteral("**hello**"));
        QCOMPARE(d.size(), 1);
        QCOMPARE(d[0].size(), 1);
        QCOMPARE(d[0][0], mk("hello", true));
    }

    void parse_italic()
    {
        const Doc d = parseDSL(QStringLiteral("*hello*"));
        QCOMPARE(d.size(), 1);
        QCOMPARE(d[0][0], mk("hello", false, true));
    }

    void parse_underline()
    {
        const Doc d = parseDSL(QStringLiteral("++hello++"));
        QCOMPARE(d.size(), 1);
        QCOMPARE(d[0][0], mk("hello", false, false, true));
    }

    void parse_colorNamed()
    {
        const Doc d = parseDSL(QStringLiteral("{color=red}grace{/color}"));
        QCOMPARE(d.size(), 1);
        QCOMPARE(d[0].size(), 1);
        QCOMPARE(d[0][0], mk("grace", false, false, false, "red"));
    }

    void parse_colorHex()
    {
        const Doc d = parseDSL(QStringLiteral("{color=#c33}grace{/color}"));
        QCOMPARE(d[0][0], mk("grace", false, false, false, "#c33"));
    }

    void parse_boldItalic()
    {
        // `***hello***` opens bold then italic, closes italic then bold.
        const Doc d = parseDSL(QStringLiteral("***hello***"));
        QCOMPARE(d[0].size(), 1);
        QCOMPARE(d[0][0], mk("hello", true, true));
    }

    void parse_allMarksWithColor()
    {
        // bold + italic + underline + red color
        const Doc d = parseDSL(QStringLiteral("{color=red}***++hello++***{/color}"));
        QCOMPARE(d[0].size(), 1);
        QCOMPARE(d[0][0], mk("hello", true, true, true, "red"));
    }

    void parse_multiLine()
    {
        const Doc d = parseDSL(QStringLiteral("**foo**\nbar"));
        QCOMPARE(d.size(), 2);
        QCOMPARE(d[0].size(), 1);
        QCOMPARE(d[0][0], mk("foo", true));
        QCOMPARE(d[1].size(), 1);
        QCOMPARE(d[1][0], mk("bar"));
    }

    void parse_marksResetAtLineBoundary()
    {
        // Unclosed bold on line 1 must NOT leak into line 2.
        const Doc d = parseDSL(QStringLiteral("**foo\nbar"));
        QCOMPARE(d.size(), 2);
        QCOMPARE(d[0][0], mk("foo", true));  // graceful: bold partial
        QCOMPARE(d[1][0], mk("bar"));        // NOT bold — line boundary reset
    }

    void parse_escape()
    {
        // \* is literal "*", \\ is literal "\", \{ is literal "{"
        const Doc d = parseDSL(QStringLiteral("\\*foo\\* \\{x\\} \\\\"));
        QCOMPARE(d[0].size(), 1);
        QCOMPARE(d[0][0].text, QStringLiteral("*foo* {x} \\"));
        QVERIFY(!d[0][0].bold);
    }

    void parse_adjacentRunsSharingBold()
    {
        // `**foo*bar*baz**` → "foo" bold, "bar" bold+italic, "baz" bold.
        const Doc d = parseDSL(QStringLiteral("**foo*bar*baz**"));
        QCOMPARE(d[0].size(), 3);
        QCOMPARE(d[0][0], mk("foo", true, false));
        QCOMPARE(d[0][1], mk("bar", true, true));
        QCOMPARE(d[0][2], mk("baz", true, false));
    }

    void parse_unclosedColorTagDegradesGracefully()
    {
        // `{color=` with no closing `}` should NOT consume the rest of input.
        // Parser falls back: emits the open token as literal text.
        const Doc d = parseDSL(QStringLiteral("{color=unclosed text"));
        // The "{color=" was not consumed as a tag — it's literal.
        QVERIFY(d[0][0].text.contains(QLatin1Char('{')));
        QVERIFY(d[0][0].color.isEmpty());
    }

    void parse_trailingNewlinePreservesEmptyLine()
    {
        // Songs occasionally end with a deliberate blank line. Preserve it.
        const Doc d = parseDSL(QStringLiteral("foo\n"));
        QCOMPARE(d.size(), 2);
        QCOMPARE(d[0][0].text, QStringLiteral("foo"));
        QCOMPARE(d[1].size(), 0);
    }

    // ── serializeDSL ─────────────────────────────────────────────────────

    void serialize_plainText()
    {
        Doc d;
        d.append({ mk("hello world") });
        QCOMPARE(serializeDSL(d), QStringLiteral("hello world"));
    }

    void serialize_bold()
    {
        Doc d;
        d.append({ mk("hello", true) });
        QCOMPARE(serializeDSL(d), QStringLiteral("**hello**"));
    }

    void serialize_colorNamed()
    {
        Doc d;
        d.append({ mk("grace", false, false, false, "red") });
        QCOMPARE(serializeDSL(d), QStringLiteral("{color=red}grace{/color}"));
    }

    void serialize_adjacentRunsDontDuplicateMarks()
    {
        // Two adjacent runs that both share bold: bold marker should stay
        // open across them, not close+reopen.
        Doc d;
        d.append({
            mk("foo", true, false),
            mk("bar", true, true),
            mk("baz", true, false),
        });
        QCOMPARE(serializeDSL(d), QStringLiteral("**foo*bar*baz**"));
    }

    void serialize_canonicalNestingOrder()
    {
        // Canonical: color > bold > italic > underline.
        Doc d;
        d.append({ mk("hello", true, true, true, "red") });
        QCOMPARE(serializeDSL(d),
                 QStringLiteral("{color=red}***++hello++***{/color}"));
    }

    void serialize_escapesSpecialChars()
    {
        Doc d;
        d.append({ mk("a*b{c\\d") });
        // Every * { \ gets escaped. + and } don't unless ambiguous; we
        // escape + conservatively too. } is left bare (no standalone meaning).
        QCOMPARE(serializeDSL(d), QStringLiteral("a\\*b\\{c\\\\d"));
    }

    void serialize_multiLineJoinedWithNewline()
    {
        Doc d;
        d.append({ mk("foo", true) });
        d.append({ mk("bar") });
        QCOMPARE(serializeDSL(d), QStringLiteral("**foo**\nbar"));
    }

    // ── Round-trip invariant ─────────────────────────────────────────────
    // serializeDSL(parseDSL(serializeDSL(x))) == serializeDSL(x) for all x.
    // The double-trip catches cases where the parser is lenient about input
    // forms (e.g. accepting `__foo__` as bold) but the serializer always
    // emits canonical (e.g. `**foo**`) — the second pass canonicalizes,
    // and from that point forward round-trips must be stable.

    void roundTrip_plainText()
    {
        const QString src = QStringLiteral("Amazing grace, how sweet the sound");
        QCOMPARE(serializeDSL(parseDSL(src)), src);
    }

    void roundTrip_richExample()
    {
        const QString src = QStringLiteral(
            "Amazing {color=red}grace{/color}, how **sweet** the *sound*\n"
            "That ++saved++ a wretch like me");
        const QString once  = serializeDSL(parseDSL(src));
        const QString twice = serializeDSL(parseDSL(once));
        QCOMPARE(once, twice);
    }

    void roundTrip_allMarksTogether()
    {
        const QString src = QStringLiteral(
            "{color=blue}***++everything at once++***{/color}");
        const QString once  = serializeDSL(parseDSL(src));
        const QString twice = serializeDSL(parseDSL(once));
        QCOMPARE(once, twice);
    }

    void roundTrip_escapedSpecials()
    {
        const QString src = QStringLiteral("literal \\*asterisks\\* and \\{braces\\}");
        const QString once  = serializeDSL(parseDSL(src));
        const QString twice = serializeDSL(parseDSL(once));
        QCOMPARE(once, twice);
    }

    // ── flattenText ──────────────────────────────────────────────────────

    void flatten_dropsAllMarks()
    {
        const Doc d = parseDSL(QStringLiteral(
            "Amazing {color=red}**grace**{/color}, how *sweet*"));
        QCOMPARE(flattenText(d), QStringLiteral("Amazing grace, how sweet"));
    }

    void flatten_joinsLinesWithNewline()
    {
        const Doc d = parseDSL(QStringLiteral("**foo**\n*bar*\n++baz++"));
        QCOMPARE(flattenText(d), QStringLiteral("foo\nbar\nbaz"));
    }

    // ── resolveColor ─────────────────────────────────────────────────────

    void color_namedKnown()
    {
        QCOMPARE(resolveColor(QStringLiteral("red")),    QStringLiteral("#e53935"));
        QCOMPARE(resolveColor(QStringLiteral("blue")),   QStringLiteral("#1e88e5"));
        QCOMPARE(resolveColor(QStringLiteral("purple")), QStringLiteral("#8e24aa"));
    }

    void color_namedCaseInsensitive()
    {
        QCOMPARE(resolveColor(QStringLiteral("RED")), QStringLiteral("#e53935"));
        QCOMPARE(resolveColor(QStringLiteral("Red")), QStringLiteral("#e53935"));
    }

    void color_validHexShortAndLong()
    {
        QCOMPARE(resolveColor(QStringLiteral("#c33")),     QStringLiteral("#c33"));
        QCOMPARE(resolveColor(QStringLiteral("#CC3333")),  QStringLiteral("#cc3333"));
    }

    void color_invalidReturnsEmpty()
    {
        QVERIFY(resolveColor(QStringLiteral("hotpink")).isEmpty());
        QVERIFY(resolveColor(QStringLiteral("#xyz")).isEmpty());
        QVERIFY(resolveColor(QStringLiteral("#cc33")).isEmpty());  // 4 chars, no alpha in v1
        QVERIFY(resolveColor(QString()).isEmpty());
    }

    void color_namedColorsListIsCanonical()
    {
        const QStringList names = namedColors();
        QCOMPARE(names.size(), 7);
        QCOMPARE(names.first(), QStringLiteral("red"));
        QCOMPARE(names.last(),  QStringLiteral("gray"));
        // Every named color in the list must resolve to a non-empty hex.
        for (const QString& name : names) {
            QVERIFY2(!resolveColor(name).isEmpty(),
                     qPrintable("named color resolves: " + name));
        }
    }

    // ── HTML emission ────────────────────────────────────────────────────

    void html_plainText()
    {
        QCOMPARE(dslLineToHtml(QStringLiteral("hello world")),
                 QStringLiteral("hello world"));
    }

    void html_bold()
    {
        QCOMPARE(dslLineToHtml(QStringLiteral("**hello**")),
                 QStringLiteral("<b>hello</b>"));
    }

    void html_italic()
    {
        QCOMPARE(dslLineToHtml(QStringLiteral("*hello*")),
                 QStringLiteral("<i>hello</i>"));
    }

    void html_underline()
    {
        QCOMPARE(dslLineToHtml(QStringLiteral("++hello++")),
                 QStringLiteral("<u>hello</u>"));
    }

    void html_colorNamedResolvesToHex()
    {
        // Named "red" must resolve to its palette hex in the HTML output —
        // otherwise the renderer would emit `color:red` which works in CSS
        // but doesn't match our theme palette.
        QCOMPARE(dslLineToHtml(QStringLiteral("{color=red}grace{/color}")),
                 QStringLiteral("<span style=\"color:#e53935;\">grace</span>"));
    }

    void html_colorHexLowercased()
    {
        QCOMPARE(dslLineToHtml(QStringLiteral("{color=#C33}grace{/color}")),
                 QStringLiteral("<span style=\"color:#c33;\">grace</span>"));
    }

    void html_unknownColorOmitsSpan()
    {
        // Invalid color name → no <span> wrapper, just plain text. The
        // renderer's outer Text element provides the fallback color.
        QCOMPARE(dslLineToHtml(QStringLiteral("{color=hotpink}grace{/color}")),
                 QStringLiteral("grace"));
    }

    void html_canonicalNestingOrder()
    {
        // Same outer-to-inner order as DSL: color > bold > italic > underline
        QCOMPARE(dslLineToHtml(
                     QStringLiteral("{color=red}***++hello++***{/color}")),
                 QStringLiteral("<span style=\"color:#e53935;\">"
                                "<b><i><u>hello</u></i></b></span>"));
    }

    void html_escapesSpecialChars()
    {
        // < > & in lyric text must become entities so the HTML stays valid.
        Doc d;
        d.append({ mk("a<b>c&d") });
        QCOMPARE(runsToHtml(d.first()),
                 QStringLiteral("a&lt;b&gt;c&amp;d"));
    }

    void html_multiLineUsesBr()
    {
        QStringList lines;
        lines << QStringLiteral("**foo**")
              << QStringLiteral("bar");
        QCOMPARE(linesToHtml(lines),
                 QStringLiteral("<b>foo</b><br>bar"));
    }

    void html_skipsEmptyRuns()
    {
        // Defensive: a hand-built Line with an empty Run shouldn't emit
        // empty tag pairs that would render as zero-width artifacts.
        Line runs;
        runs.append(mk(""));
        runs.append(mk("visible", true));
        QCOMPARE(runsToHtml(runs), QStringLiteral("<b>visible</b>"));
    }

    // ── flattenLine ──────────────────────────────────────────────────────

    void flattenLine_plainText()
    {
        QCOMPARE(flattenLine(QStringLiteral("hello world")),
                 QStringLiteral("hello world"));
    }

    void flattenLine_stripsAllMarks()
    {
        QCOMPARE(flattenLine(QStringLiteral(
                     "Amazing {color=red}**grace**{/color}, how *sweet*")),
                 QStringLiteral("Amazing grace, how sweet"));
    }

    void flattenLine_unwrapsEscapes()
    {
        QCOMPARE(flattenLine(QStringLiteral("literal \\*asterisks\\*")),
                 QStringLiteral("literal *asterisks*"));
    }

    // ── dslToHtml (combined entry point for renderers) ───────────────────

    void dslToHtml_plainText()
    {
        QCOMPARE(dslToHtml(QStringLiteral("hello world")),
                 QStringLiteral("hello world"));
    }

    void dslToHtml_multiLine()
    {
        QCOMPARE(dslToHtml(QStringLiteral("**foo**\nbar")),
                 QStringLiteral("<b>foo</b><br>bar"));
    }

    void dslToHtml_uppercaseTransform()
    {
        // Markers stay lowercase (they're parser tokens), only Run.text
        // gets uppercased. Color name still resolves because parser
        // already consumed "{color=red}" before transform ran.
        QCOMPARE(dslToHtml(QStringLiteral("**hello** {color=red}grace{/color}"),
                           QStringLiteral("uppercase")),
                 QStringLiteral("<b>HELLO</b> "
                                "<span style=\"color:#e53935;\">GRACE</span>"));
    }

    void dslToHtml_lowercaseTransform()
    {
        QCOMPARE(dslToHtml(QStringLiteral("HELLO **WORLD**"),
                           QStringLiteral("lowercase")),
                 QStringLiteral("hello <b>world</b>"));
    }

    void dslToHtml_capitalizeTransform()
    {
        // First letter of each word capitalized; rest preserved as-is.
        QCOMPARE(dslToHtml(QStringLiteral("amazing grace, how **sweet** the sound"),
                           QStringLiteral("capitalize")),
                 QStringLiteral("Amazing Grace, How <b>Sweet</b> The Sound"));
    }

    void dslToHtml_unknownTransformIsNoOp()
    {
        // Themes may store "smallcaps" or other future values; renderer
        // should not refuse to render — just skip the transform.
        QCOMPARE(dslToHtml(QStringLiteral("hello"), QStringLiteral("smallcaps")),
                 QStringLiteral("hello"));
    }

    // ── htmlToDsl ────────────────────────────────────────────────────────

    void htmlToDsl_plainText()
    {
        // Plain text, no markup — should round-trip through Qt's HTML
        // parser unchanged. Qt wraps in <p> internally but the DSL output
        // is just the text.
        QCOMPARE(htmlToDsl(QStringLiteral("hello world")),
                 QStringLiteral("hello world"));
    }

    void htmlToDsl_bold()
    {
        QCOMPARE(htmlToDsl(QStringLiteral("<b>hello</b>")),
                 QStringLiteral("**hello**"));
    }

    void htmlToDsl_italic()
    {
        QCOMPARE(htmlToDsl(QStringLiteral("<i>hello</i>")),
                 QStringLiteral("*hello*"));
    }

    void htmlToDsl_underline()
    {
        QCOMPARE(htmlToDsl(QStringLiteral("<u>hello</u>")),
                 QStringLiteral("++hello++"));
    }

    void htmlToDsl_colorSpan()
    {
        // Color via <span style="color:#xxx"> — common form Qt emits.
        QCOMPARE(htmlToDsl(QStringLiteral(
                     "<span style=\"color:#e53935;\">grace</span>")),
                 QStringLiteral("{color=#e53935}grace{/color}"));
    }

    void htmlToDsl_multiLineViaBr()
    {
        // <br> becomes U+2028 inside the QTextBlock; htmlToDsl splits
        // on that boundary so the DSL gets two lines, not one with a
        // separator char in the middle.
        QCOMPARE(htmlToDsl(QStringLiteral("<b>foo</b><br>bar")),
                 QStringLiteral("**foo**\nbar"));
    }

    void htmlToDsl_multiLineViaParagraphs()
    {
        // <p>...</p><p>...</p> structure — typed Enter in the editor
        // creates new blocks. Each block becomes a DSL line.
        QCOMPARE(htmlToDsl(QStringLiteral("<p>foo</p><p>bar</p>")),
                 QStringLiteral("foo\nbar"));
    }

    void htmlToDsl_dropsRedundantWrapping()
    {
        // Qt's setHtml accepts full HTML documents; the parser should
        // ignore <html>/<body> chrome and produce just the content.
        QCOMPARE(htmlToDsl(QStringLiteral(
                     "<html><body><p>hello</p></body></html>")),
                 QStringLiteral("hello"));
    }

    // ── Round-trip: DSL → HTML → DSL ─────────────────────────────────────
    // This is the load-bearing invariant of Phase 4: the structured
    // editor stores HTML internally, emits DSL out, and re-parses DSL
    // on the next edit cycle. If round-trip isn't stable, formatting
    // mutates with each keystroke.

    void roundTrip_dslHtmlPlain()
    {
        const QString dsl = QStringLiteral("Amazing grace");
        QCOMPARE(htmlToDsl(dslToHtml(dsl)), dsl);
    }

    void roundTrip_dslHtmlBold()
    {
        const QString dsl = QStringLiteral("Amazing **grace**");
        QCOMPARE(htmlToDsl(dslToHtml(dsl)), dsl);
    }

    void roundTrip_dslHtmlAllMarks()
    {
        // Hex form is what htmlToDsl emits (Qt's QColor.name() returns hex),
        // so the round-trip canonicalizes named colors to their hex form.
        // Start from the canonical-after-one-trip form so the second trip
        // is stable.
        const QString src = QStringLiteral(
            "Amazing **grace** how *sweet* the ++sound++");
        const QString once  = htmlToDsl(dslToHtml(src));
        const QString twice = htmlToDsl(dslToHtml(once));
        QCOMPARE(once, twice);
    }

    void roundTrip_dslHtmlMultiLine()
    {
        const QString dsl = QStringLiteral("**foo**\n*bar*\nbaz");
        QCOMPARE(htmlToDsl(dslToHtml(dsl)), dsl);
    }
};

QTEST_GUILESS_MAIN(TestLyricsDSL)
#include "test_lyrics_dsl.moc"
