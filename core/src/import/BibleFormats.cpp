#include "import/BibleFormats.h"

#include "import/CanonicalBibleBooks.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QRegularExpression>
#include <QSet>
#include <QStringDecoder>
#include <QXmlStreamReader>

#include <algorithm>
#include <initializer_list>

namespace crater::import {

namespace {

// ── Book codes ──────────────────────────────────────────────────────────

// USFM / USX three-letter codes for the 66 books, in canonical order.
constexpr const char* kUsfmCodes[66] = {
    "GEN", "EXO", "LEV", "NUM", "DEU", "JOS", "JDG", "RUT", "1SA", "2SA",
    "1KI", "2KI", "1CH", "2CH", "EZR", "NEH", "EST", "JOB", "PSA", "PRO",
    "ECC", "SNG", "ISA", "JER", "LAM", "EZK", "DAN", "HOS", "JOL", "AMO",
    "OBA", "JON", "MIC", "NAM", "HAB", "ZEP", "HAG", "ZEC", "MAL",
    "MAT", "MRK", "LUK", "JHN", "ACT", "ROM", "1CO", "2CO", "GAL", "EPH",
    "PHP", "COL", "1TH", "2TH", "1TI", "2TI", "TIT", "PHM", "HEB", "JAS",
    "1PE", "2PE", "1JN", "2JN", "3JN", "JUD", "REV",
};

// OSIS book names for the 66 books, in canonical order.
constexpr const char* kOsisCodes[66] = {
    "Gen", "Exod", "Lev", "Num", "Deut", "Josh", "Judg", "Ruth", "1Sam", "2Sam",
    "1Kgs", "2Kgs", "1Chr", "2Chr", "Ezra", "Neh", "Esth", "Job", "Ps", "Prov",
    "Eccl", "Song", "Isa", "Jer", "Lam", "Ezek", "Dan", "Hos", "Joel", "Amos",
    "Obad", "Jonah", "Mic", "Nah", "Hab", "Zeph", "Hag", "Zech", "Mal",
    "Matt", "Mark", "Luke", "John", "Acts", "Rom", "1Cor", "2Cor", "Gal", "Eph",
    "Phil", "Col", "1Thess", "2Thess", "1Tim", "2Tim", "Titus", "Phlm", "Heb", "Jas",
    "1Pet", "2Pet", "1John", "2John", "3John", "Jude", "Rev",
};

int indexIn(const char* const (&codes)[66], QStringView code)
{
    for (int i = 0; i < 66; ++i)
        if (code.compare(QLatin1String(codes[i]), Qt::CaseInsensitive) == 0) return i + 1;
    return 0;
}

// ── Shared helpers ──────────────────────────────────────────────────────

// One line of plain text: runs of whitespace (line breaks, tabs, the
// no-break spaces some files use) become one space.
QString cleanText(const QString& raw)
{
    QString out;
    out.reserve(raw.size());
    bool space = false;
    for (QChar c : raw) {
        if (c.isSpace() || c == QChar(0x00A0)) {
            space = true;
            continue;
        }
        if (space && !out.isEmpty()) out += QLatin1Char(' ');
        space = false;
        out += c;
    }
    return out;
}

// "3", "3a", "3-5", "3b-4a". False when it doesn't start with a number.
bool parseVerseNumbers(QStringView s, int* first, int* last)
{
    static const QRegularExpression re(QStringLiteral(R"(^\s*(\d+)[a-z]?(?:\s*[-\x{2013}]\s*(\d+)[a-z]?)?)"));
    const auto m = re.matchView(s);
    if (!m.hasMatch()) return false;
    *first = m.capturedView(1).toInt();
    *last  = m.capturedView(2).isEmpty() ? *first : m.capturedView(2).toInt();
    if (*last < *first || *last - *first > 200) *last = *first;
    return *first > 0;
}

void addVerse(ParsedBible& out, int book, int chapter, int verse, int verseEnd,
              const QString& rawText)
{
    if (book < 1 || book > 66 || chapter < 1 || verse < 1) return;
    const QString text = cleanText(rawText);
    if (text.isEmpty()) return;   // a verse the translation leaves out
    out.verses.append({ book, chapter, verse, qMax(verse, verseEnd), text });
}

void skipBook(ParsedBible& out, const QString& name)
{
    const QString n = name.trimmed();
    if (!n.isEmpty() && !out.skippedBooks.contains(n)) out.skippedBooks.append(n);
}

bool isName(const QXmlStreamReader& x, const char* name)
{
    return x.name().compare(QLatin1String(name), Qt::CaseInsensitive) == 0;
}

bool isAnyName(const QXmlStreamReader& x, std::initializer_list<const char*> names)
{
    for (const char* n : names)
        if (isName(x, n)) return true;
    return false;
}

QString attr(const QXmlStreamReader& x, const char* name)
{
    for (const QXmlStreamAttribute& a : x.attributes())
        if (a.qualifiedName().compare(QLatin1String(name), Qt::CaseInsensitive) == 0)
            return a.value().toString().trimmed();
    return {};
}

// The text inside the current element, skipping the subtrees named in
// `skip`, with a line break element counted as a space. Leaves the reader on
// the element's end tag.
QString readMixed(QXmlStreamReader& x, std::initializer_list<const char*> skip)
{
    QString text;
    int depth = 1;
    while (depth > 0 && !x.atEnd()) {
        x.readNext();
        if (x.isStartElement()) {
            if (isAnyName(x, skip)) {
                x.skipCurrentElement();
                continue;
            }
            if (isAnyName(x, { "br", "lb" })) text += QLatin1Char(' ');
            ++depth;
        } else if (x.isEndElement()) {
            --depth;
        } else if (x.isCharacters()) {
            text += x.text();
        }
    }
    return text;
}

// ── Zefania XML ─────────────────────────────────────────────────────────

void readZefania(QXmlStreamReader& x, ParsedBible& out)
{
    out.format = QStringLiteral("Zefania XML");
    bool inInfo = false;
    int book = 0, chapter = 0;
    while (!x.atEnd()) {
        x.readNext();
        if (x.isEndElement() && isName(x, "INFORMATION")) inInfo = false;
        if (!x.isStartElement()) continue;
        if (isName(x, "XMLBIBLE")) {
            out.name = attr(x, "biblename");
        } else if (isName(x, "INFORMATION")) {
            inInfo = true;
        } else if (inInfo && isName(x, "title")) {
            if (const QString t = x.readElementText(QXmlStreamReader::IncludeChildElements).trimmed(); !t.isEmpty()) out.name = t;
        } else if (inInfo && isName(x, "identifier")) {
            out.code = x.readElementText(QXmlStreamReader::IncludeChildElements).trimmed();
        } else if (inInfo && isName(x, "language")) {
            out.language = x.readElementText(QXmlStreamReader::IncludeChildElements).trimmed();
        } else if (isName(x, "BIBLEBOOK")) {
            // bnumber follows the 66-book order; the deuterocanon is 67 up.
            const int number = attr(x, "bnumber").toInt();
            const QString name = attr(x, "bname");
            book = number >= 1 && number <= 66 ? number : 0;
            if (!book && number == 0) {
                if (const auto meta = lookupBook(name)) book = meta->bookNumber;
            }
            if (!book) skipBook(out, name.isEmpty() ? attr(x, "bnumber") : name);
            chapter = 0;
        } else if (isName(x, "CHAPTER")) {
            chapter = attr(x, "cnumber").toInt();
        } else if (isName(x, "VERS")) {
            int first = 0, last = 0;
            const bool ok = parseVerseNumbers(attr(x, "vnumber"), &first, &last);
            const QString text = readMixed(x, { "NOTE", "XREF", "DIV", "MEDIA" });
            if (ok) addVerse(out, book, chapter, first, last, text);
        }
    }
}

// ── OpenSong ────────────────────────────────────────────────────────────

// Canonical numbers for books known only by their names, in file order, with
// 0 for a book that can't be placed. OpenSong names books in the
// translation's own language, so a name alone often says nothing.
//
// Names that resolve (English, the usual abbreviations, and others close
// enough) and keep canonical order are anchors: the longest such run is
// trusted, so one name that resolves wrongly can't drag the rest. Books
// between two anchors take the numbers between them when the counts match
// exactly. Before the first anchor and after the last, they take the
// numbers leading up to it or following it when there's room, as in a New
// Testament on its own. Books that fit nowhere, like the deuterocanon
// between the testaments of a Catholic Bible, are left out.
QList<int> placeBooks(const QStringList& names, bool* byPosition)
{
    const int n = int(names.size());
    QList<int> resolved(n, 0);
    for (int i = 0; i < n; ++i)
        if (const auto meta = lookupBook(names[i])) resolved[i] = meta->bookNumber;

    // Longest strictly increasing run of resolved numbers. A Bible has
    // under a hundred books, so the quadratic search costs nothing.
    QList<int> length(n, 0), previous(n, -1);
    int best = -1;
    for (int i = 0; i < n; ++i) {
        if (!resolved[i]) continue;
        length[i] = 1;
        for (int j = 0; j < i; ++j)
            if (resolved[j] && resolved[j] < resolved[i] && length[j] + 1 > length[i]) {
                length[i] = length[j] + 1;
                previous[i] = j;
            }
        if (best < 0 || length[i] > length[best]) best = i;
    }
    QList<int> anchors;
    for (int i = best; i >= 0; i = previous[i]) anchors.prepend(i);

    QList<int> out(n, 0);
    for (int i : anchors) out[i] = resolved[i];
    *byPosition = false;
    const auto fill = [&](int fromPos, int fromNumber, int count) {
        for (int i = 0; i < count; ++i) out[fromPos + i] = fromNumber + i;
        if (count > 0) *byPosition = true;
    };

    if (anchors.isEmpty()) {
        // Nothing recognised: only a whole Bible or one whole testament
        // says by its size which books it holds.
        if (n == 66 || n == 39) fill(0, 1, n);
        else if (n == 27)       fill(0, 40, n);
        return out;
    }
    // Leading up to the first anchor, following on from the last.
    const int first = anchors.first(), last = anchors.last();
    if (first <= out[first] - 1) fill(0, out[first] - first, first);
    if (n - 1 - last <= 66 - out[last]) fill(last + 1, out[last] + 1, n - 1 - last);
    for (int k = 1; k < anchors.size(); ++k) {
        const int a = anchors[k - 1], b = anchors[k];
        if (b - a == out[b] - out[a]) fill(a + 1, out[a] + 1, b - a - 1);
    }
    return out;
}

void readOpenSong(QXmlStreamReader& x, ParsedBible& out)
{
    out.format = QStringLiteral("OpenSong");
    struct FileBook { QString name; QList<ParsedVerse> verses; };
    QList<FileBook> books;
    int chapter = 0;
    while (!x.atEnd()) {
        x.readNext();
        if (!x.isStartElement()) continue;
        if (isName(x, "b")) {
            books.append({ attr(x, "n"), {} });
            chapter = 0;
        } else if (isName(x, "c")) {
            chapter = attr(x, "n").toInt();
        } else if (isName(x, "v") && !books.isEmpty()) {
            int first = 0, last = 0;
            const bool ok = parseVerseNumbers(attr(x, "n"), &first, &last);
            const QString text = cleanText(readMixed(x, {}));
            if (ok && chapter > 0 && !text.isEmpty())
                books.last().verses.append({ 0, chapter, first, last, text });
        }
    }
    books.removeIf([](const FileBook& b) { return b.verses.isEmpty(); });
    if (books.isEmpty()) return;

    const QList<int> numbers = placeBooks([&] {
        QStringList names;
        for (const FileBook& b : books) names << b.name;
        return names;
    }(), &out.booksByPosition);
    if (std::all_of(numbers.cbegin(), numbers.cend(), [](int n) { return n == 0; })) {
        out.error = QStringLiteral("The book names in this file aren't ones Crater recognises, "
                                   "and their order doesn't say which books they are.");
        return;
    }
    for (int i = 0; i < books.size(); ++i) {
        if (!numbers[i]) {
            skipBook(out, books[i].name);
            continue;
        }
        for (ParsedVerse v : books[i].verses) {
            v.book = numbers[i];
            out.verses.append(std::move(v));
        }
    }
}

// ── OSIS ────────────────────────────────────────────────────────────────

struct OsisRef { int book = 0; int chapter = 0; int verse = 0; int verseEnd = 0; QString bookCode; };

// "Gen.1.1", "KJV:Gen.1.1", or several space-separated for combined verses.
OsisRef parseOsisRef(const QString& osisId)
{
    OsisRef ref;
    const QStringList ids = osisId.split(QLatin1Char(' '), Qt::SkipEmptyParts);
    for (int i = 0; i < ids.size(); ++i) {
        QString id = ids[i];
        if (const int colon = id.indexOf(QLatin1Char(':')); colon >= 0) id = id.mid(colon + 1);
        const QStringList parts = id.split(QLatin1Char('.'));
        if (parts.size() < 3) continue;
        const int verse = parts[2].toInt();
        if (i == 0) {
            ref.bookCode = parts[0];
            ref.book     = bookFromOsisCode(parts[0]);
            ref.chapter  = parts[1].toInt();
            ref.verse    = verse;
            ref.verseEnd = verse;
        } else if (parts[0] == ref.bookCode && parts[1].toInt() == ref.chapter && verse > ref.verseEnd) {
            ref.verseEnd = verse;
        }
    }
    return ref;
}

void readOsis(QXmlStreamReader& x, ParsedBible& out)
{
    out.format = QStringLiteral("OSIS");
    OsisRef open;
    bool isOpen = false, container = false, inWork = false;
    int skipDepth = 0;
    QString text;
    const auto flush = [&] {
        if (!isOpen) return;
        if (open.book) addVerse(out, open.book, open.chapter, open.verse, open.verseEnd, text);
        else if (!cleanText(text).isEmpty()) skipBook(out, open.bookCode);
        isOpen = false;
        text.clear();
    };
    while (!x.atEnd()) {
        x.readNext();
        if (x.isStartElement()) {
            if (skipDepth > 0) { ++skipDepth; continue; }
            if (isName(x, "osisText")) {
                out.code = attr(x, "osisIDWork");
                if (const QString lang = attr(x, "xml:lang"); !lang.isEmpty()) out.language = lang;
            } else if (isName(x, "work") && out.name.isEmpty()) {
                inWork = true;
            } else if (inWork && isName(x, "title")) {
                out.name = x.readElementText(QXmlStreamReader::IncludeChildElements).trimmed();
            } else if (inWork && isName(x, "language") && out.language.isEmpty()) {
                out.language = x.readElementText(QXmlStreamReader::IncludeChildElements).trimmed();
            } else if (isName(x, "verse")) {
                const QString eid = attr(x, "eID");
                flush();
                if (!eid.isEmpty()) continue;
                const QString sid = attr(x, "sID");
                QString id = attr(x, "osisID");
                if (id.isEmpty()) id = sid;
                open = parseOsisRef(id);
                isOpen = open.verse > 0;
                container = sid.isEmpty();
            } else if (isAnyName(x, { "note", "title", "rdg" })) {
                skipDepth = 1;
            } else if (isAnyName(x, { "lb", "l", "p", "lg" }) && isOpen) {
                text += QLatin1Char(' ');
            }
        } else if (x.isEndElement()) {
            if (skipDepth > 0) { --skipDepth; continue; }
            if (isName(x, "work")) inWork = false;
            else if (isName(x, "verse") && isOpen && container) flush();
            else if (isAnyName(x, { "l", "p", "lg" }) && isOpen) text += QLatin1Char(' ');
        } else if (x.isCharacters() && isOpen && skipDepth == 0) {
            text += x.text();
        }
    }
    flush();
}

// ── USX ─────────────────────────────────────────────────────────────────

// Paragraph styles that are headings, titles or introduction rather than
// verse text (USFM's marker names, which USX uses as styles).
bool isHeadingStyle(QString style)
{
    while (!style.isEmpty() && style.back().isDigit()) style.chop(1);
    static const QSet<QString> headings = {
        QStringLiteral("id"), QStringLiteral("ide"), QStringLiteral("h"), QStringLiteral("toc"),
        QStringLiteral("toca"), QStringLiteral("rem"), QStringLiteral("sts"), QStringLiteral("usfm"),
        QStringLiteral("mt"), QStringLiteral("mte"), QStringLiteral("ms"), QStringLiteral("mr"),
        QStringLiteral("s"), QStringLiteral("sr"), QStringLiteral("sp"), QStringLiteral("sd"),
        QStringLiteral("r"), QStringLiteral("d"), QStringLiteral("cl"), QStringLiteral("cd"),
        QStringLiteral("cp"), QStringLiteral("lit"), QStringLiteral("restore"),
        // Introduction (\it is italic, not one of these)
        QStringLiteral("imt"), QStringLiteral("imte"), QStringLiteral("is"), QStringLiteral("ip"),
        QStringLiteral("ipi"), QStringLiteral("im"), QStringLiteral("imi"), QStringLiteral("ipq"),
        QStringLiteral("imq"), QStringLiteral("ipr"), QStringLiteral("iq"), QStringLiteral("ib"),
        QStringLiteral("ili"), QStringLiteral("iot"), QStringLiteral("io"), QStringLiteral("iex"),
        QStringLiteral("ie"),
    };
    return headings.contains(style);
}

void readUsx(QXmlStreamReader& x, ParsedBible& out)
{
    out.format = QStringLiteral("USX");
    int book = 0, chapter = 0, skipDepth = 0;
    QString bookCode, text;
    bool isOpen = false, heading = false;
    int verse = 0, verseEnd = 0;
    const auto flush = [&] {
        if (!isOpen) return;
        if (book) addVerse(out, book, chapter, verse, verseEnd, text);
        else if (!cleanText(text).isEmpty()) skipBook(out, bookCode);
        isOpen = false;
        text.clear();
    };
    while (!x.atEnd()) {
        x.readNext();
        if (x.isStartElement()) {
            if (skipDepth > 0) { ++skipDepth; continue; }
            if (isName(x, "book")) {
                flush();
                bookCode = attr(x, "code").toUpper();
                book = bookFromUsfmCode(bookCode);
                chapter = 0;
                x.skipCurrentElement();
            } else if (isName(x, "chapter")) {
                flush();
                if (attr(x, "eid").isEmpty()) chapter = attr(x, "number").toInt();
            } else if (isName(x, "verse")) {
                flush();
                if (!attr(x, "eid").isEmpty()) continue;
                isOpen = chapter > 0 && parseVerseNumbers(attr(x, "number"), &verse, &verseEnd);
            } else if (isName(x, "para")) {
                heading = isHeadingStyle(attr(x, "style"));
                if (isOpen) text += QLatin1Char(' ');
            } else if (isAnyName(x, { "note", "figure", "sidebar" })) {
                skipDepth = 1;
            }
        } else if (x.isEndElement()) {
            if (skipDepth > 0) { --skipDepth; continue; }
            if (isName(x, "para")) {
                heading = false;
                if (isOpen) text += QLatin1Char(' ');
            }
        } else if (x.isCharacters() && isOpen && !heading && skipDepth == 0) {
            text += x.text();
        }
    }
    flush();
}

// ── USFM ────────────────────────────────────────────────────────────────

enum class Marker { Heading, Paragraph, Character };

Marker classifyMarker(QString name)
{
    if (isHeadingStyle(name)) return Marker::Heading;
    while (!name.isEmpty() && name.back().isDigit()) name.chop(1);
    static const QSet<QString> paragraphs = {
        QStringLiteral("p"), QStringLiteral("m"), QStringLiteral("po"), QStringLiteral("pr"),
        QStringLiteral("cls"), QStringLiteral("pmo"), QStringLiteral("pm"), QStringLiteral("pmc"),
        QStringLiteral("pmr"), QStringLiteral("pi"), QStringLiteral("mi"), QStringLiteral("nb"),
        QStringLiteral("pc"), QStringLiteral("ph"), QStringLiteral("q"), QStringLiteral("qr"),
        QStringLiteral("qc"), QStringLiteral("qa"), QStringLiteral("qm"), QStringLiteral("qd"),
        QStringLiteral("lh"), QStringLiteral("li"), QStringLiteral("lf"), QStringLiteral("lim"),
        QStringLiteral("b"), QStringLiteral("tr"), QStringLiteral("tc"), QStringLiteral("th"),
        QStringLiteral("tcr"), QStringLiteral("thr"),
    };
    return paragraphs.contains(name) ? Marker::Paragraph : Marker::Character;
}

void readUsfm(const QString& source, ParsedBible& out)
{
    out.format = QStringLiteral("USFM");
    QString t = source;
    // Footnotes, cross references and figures go with their contents.
    static const QRegularExpression notes(
        QStringLiteral(R"(\\(f|fe|ef|x|ex|fig)\b.*?\\\1\*)"),
        QRegularExpression::DotMatchesEverythingOption);
    t.remove(notes);
    // Attributes on a word (\w grace|strong="G5485"\w*) go, the word stays.
    static const QRegularExpression attributes(QStringLiteral(R"(\|[^\\]*(?=\\\+?[a-z0-9]+\*))"));
    t.remove(attributes);
    // Word markers wrap every word of a Bible with Strong's numbers. Going
    // now, as plain text, saves the marker loop below most of its work.
    for (const QLatin1String word : { QLatin1String("\\w "), QLatin1String("\\+w ") })
        t.replace(word, QLatin1String(" "));
    for (const QLatin1String word : { QLatin1String("\\w*"), QLatin1String("\\+w*") })
        t.remove(word);
    t.replace(QLatin1Char('~'), QLatin1Char(' '));
    t.remove(QStringLiteral("//"));

    static const QRegularExpression marker(QStringLiteral(R"(\\(\+?)([A-Za-z]+[0-9]*)(\*?))"));
    static const QRegularExpression number(QStringLiteral(R"(^\s+(\d+[a-z]?(?:-\d+[a-z]?)?))"));
    static const QRegularExpression code(QStringLiteral(R"(^\s+([A-Za-z0-9]{3}))"));

    int book = 0, chapter = 0, verse = 0, verseEnd = 0;
    QString bookCode, text;
    bool isOpen = false, heading = true, inlineSkip = false;
    const auto flush = [&] {
        if (!isOpen) return;
        if (book) addVerse(out, book, chapter, verse, verseEnd, text);
        else if (!cleanText(text).isEmpty()) skipBook(out, bookCode);
        isOpen = false;
        text.clear();
    };

    qsizetype pos = 0;
    auto it = marker.globalMatch(t);
    while (true) {
        const bool more = it.hasNext();
        const QRegularExpressionMatch m = more ? it.next() : QRegularExpressionMatch();
        const qsizetype start = more ? m.capturedStart() : t.size();
        if (start > pos && isOpen && !heading && !inlineSkip)
            text += QStringView(t).mid(pos, start - pos);
        if (!more) break;
        pos = m.capturedEnd();
        // The +-prefixed form is a nested character marker, the same thing.
        const QString name = m.captured(2).toLower();
        const bool closing = !m.capturedView(3).isEmpty();
        // Alternate and published numbers (\va 4\va*) aren't verse text.
        if (name == u"ca" || name == u"va" || name == u"vp") {
            inlineSkip = !closing;
            continue;
        }
        if (closing) continue;
        // A short window: the number or code is right after the marker, and
        // matching against the rest of the file each time costs seconds.
        const QStringView rest = QStringView(t).mid(pos, 48);
        if (name == u"id") {
            flush();
            const auto c = code.matchView(rest);
            bookCode = c.hasMatch() ? c.captured(1).toUpper() : QString();
            book = bookFromUsfmCode(bookCode);
            chapter = 0;
            heading = true;
            if (c.hasMatch()) pos += c.capturedEnd();
        } else if (name == u"c") {
            flush();
            const auto n = number.matchView(rest);
            chapter = n.hasMatch() ? n.capturedView(1).toInt() : 0;
            if (n.hasMatch()) pos += n.capturedEnd();
            heading = false;
        } else if (name == u"v") {
            flush();
            const auto n = number.matchView(rest);
            if (n.hasMatch()) {
                pos += n.capturedEnd();
                isOpen = chapter > 0 && parseVerseNumbers(n.capturedView(1), &verse, &verseEnd);
            }
            heading = false;
        } else {
            switch (classifyMarker(name)) {
            case Marker::Heading:
                heading = true;
                break;
            case Marker::Paragraph:
                heading = false;
                if (isOpen) text += QLatin1Char(' ');
                break;
            case Marker::Character:
                break;
            }
        }
    }
    flush();
}

// ── Files ───────────────────────────────────────────────────────────────

QString decode(const QByteArray& bytes)
{
    QStringDecoder utf8(QStringDecoder::Utf8);
    QString text = utf8.decode(bytes);
    if (utf8.hasError()) text = QString::fromLatin1(bytes);   // an old 8-bit file
    if (text.startsWith(QChar(0xFEFF))) text.remove(0, 1);
    return text;
}

enum class Format { Unknown, Zefania, OpenSong, Osis, Usx, Usfm };

Format detect(const QByteArray& bytes)
{
    QXmlStreamReader x(bytes);
    while (!x.atEnd()) {
        x.readNext();
        if (x.isStartElement()) {
            if (isName(x, "XMLBIBLE")) return Format::Zefania;
            if (isName(x, "bible"))    return Format::OpenSong;
            if (isName(x, "osis"))     return Format::Osis;
            if (isName(x, "usx"))      return Format::Usx;
            return Format::Unknown;
        }
    }
    const QString head = decode(bytes.left(64 * 1024));
    if (head.contains(QStringLiteral("\\id ")) || head.contains(QStringLiteral("\\c "))) return Format::Usfm;
    return Format::Unknown;
}

}  // namespace

int bookFromUsfmCode(QStringView code)
{
    return indexIn(kUsfmCodes, code);
}

int bookFromOsisCode(QStringView code)
{
    return indexIn(kOsisCodes, code);
}

ParsedBible parseBibleFiles(const QStringList& paths)
{
    ParsedBible out;
    if (paths.isEmpty()) {
        out.error = QStringLiteral("No file chosen.");
        return out;
    }
    // A folder of book files often carries other things too (eBible's
    // copyright page, a stylesheet). With several files chosen those are
    // passed over; a single file has to be a Bible.
    struct Source { QString path; QByteArray bytes; Format format; };
    QList<Source> sources;
    for (const QString& path : paths) {
        QFile file(path);
        if (!file.open(QIODevice::ReadOnly)) {
            out.error = QStringLiteral("Couldn't open %1.").arg(QFileInfo(path).fileName());
            return out;
        }
        QByteArray bytes = file.readAll();
        const Format f = detect(bytes);
        if (f == Format::Unknown && paths.size() > 1) {
            out.ignoredFiles.append(QFileInfo(path).fileName());
            continue;
        }
        if (f == Format::Unknown) {
            out.error = QStringLiteral("%1 isn't a Bible format Crater reads "
                                       "(Zefania XML, OpenSong, OSIS, USFM or USX).")
                            .arg(QFileInfo(path).fileName());
            return out;
        }
        if (!sources.isEmpty() && f != sources.first().format) {
            out.error = QStringLiteral("The chosen files are in different formats. Choose the files of one Bible.");
            return out;
        }
        sources.append({ path, std::move(bytes), f });
    }
    if (sources.isEmpty()) {
        out.error = QStringLiteral("None of the chosen files is a Bible format Crater reads "
                                   "(Zefania XML, OpenSong, OSIS, USFM or USX).");
        return out;
    }
    const Format format = sources.first().format;
    if (format != Format::Usfm && format != Format::Usx && sources.size() > 1) {
        out.error = QStringLiteral("A %1 Bible is a single file. Choose just that one.")
                        .arg(format == Format::Zefania ? QStringLiteral("Zefania")
                           : format == Format::Osis    ? QStringLiteral("OSIS")
                                                       : QStringLiteral("OpenSong"));
        return out;
    }

    for (const Source& source : std::as_const(sources)) {
        const QString& path = source.path;
        const QByteArray& bytes = source.bytes;
        const Format f = source.format;
        QXmlStreamReader x(bytes);
        switch (f) {
        case Format::Zefania:  readZefania(x, out); break;
        case Format::OpenSong: readOpenSong(x, out); break;
        case Format::Osis:     readOsis(x, out); break;
        case Format::Usx:      readUsx(x, out); break;
        case Format::Usfm:     readUsfm(decode(bytes), out); break;
        case Format::Unknown:  break;
        }
        if (x.hasError() && f != Format::Usfm && out.verses.isEmpty()) {
            out.error = QStringLiteral("%1 couldn't be read: %2 (line %3).")
                            .arg(QFileInfo(path).fileName(), x.errorString())
                            .arg(x.lineNumber());
            return out;
        }
        if (!out.error.isEmpty()) return out;
    }

    // USFM and USX don't name the translation, only each book. A folder of
    // book files is usually named after it ("eng-web_usfm").
    if (out.name.isEmpty()) {
        const QFileInfo first(paths.first());
        out.name = paths.size() > 1 ? first.dir().dirName() : first.completeBaseName();
        static const QRegularExpression formatSuffix(
            QStringLiteral("[\\s_.-]+(usfm|usx|osis|zefania|opensong)$"),
            QRegularExpression::CaseInsensitiveOption);
        out.name.remove(formatSuffix);
    }
    if (out.verses.isEmpty() && out.error.isEmpty())
        out.error = QStringLiteral("No verses from the 66 books were found in this file.");
    return out;
}

}  // namespace crater::import
