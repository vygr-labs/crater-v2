#include "import/BibleFormats.h"

#include "bundle/Zip.h"
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
#include <climits>
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

// The deuterocanon's codes, with Crater's numbers for those books
// (CanonicalBibleBooks.h). PS2 and AddPs are Psalm 151.
struct ExtraCode { const char* code; int book; };

constexpr ExtraCode kUsfmExtra[] = {
    { "TOB", 67 }, { "JDT", 68 }, { "ESG", 69 }, { "WIS", 70 }, { "SIR", 71 }, { "BAR", 72 },
    { "LJE", 73 }, { "S3Y", 74 }, { "SUS", 75 }, { "BEL", 76 }, { "1MA", 77 }, { "2MA", 78 },
    { "3MA", 79 }, { "4MA", 80 }, { "1ES", 81 }, { "2ES", 82 }, { "MAN", 83 }, { "PS2", kPsalm151 },
    { "DAG", 85 },
};

constexpr ExtraCode kOsisExtra[] = {
    { "Tob", 67 }, { "Jdt", 68 }, { "EsthGr", 69 }, { "AddEsth", 69 }, { "Wis", 70 },
    { "Sir", 71 }, { "Bar", 72 }, { "EpJer", 73 }, { "PrAzar", 74 }, { "SgThree", 74 },
    { "Sus", 75 }, { "Bel", 76 }, { "1Macc", 77 }, { "2Macc", 78 }, { "3Macc", 79 },
    { "4Macc", 80 }, { "1Esd", 81 }, { "2Esd", 82 }, { "PrMan", 83 }, { "AddPs", kPsalm151 },
    { "DanGr", 85 },
};

template <size_t N>
int indexIn(const char* const (&codes)[66], const ExtraCode (&extra)[N], QStringView code)
{
    for (int i = 0; i < 66; ++i)
        if (code.compare(QLatin1String(codes[i]), Qt::CaseInsensitive) == 0) return i + 1;
    for (const ExtraCode& e : extra)
        if (code.compare(QLatin1String(e.code), Qt::CaseInsensitive) == 0) return e.book;
    return 0;
}

// ── Shared helpers ──────────────────────────────────────────────────────

// One line of plain text: runs of whitespace (line breaks, tabs, the
// no-break spaces some files use) become one space. The ideographic space
// is part of Chinese text (the Union Version sets one before a name) and
// stays.
QString cleanText(const QString& raw)
{
    QString out;
    out.reserve(raw.size());
    bool space = false;
    for (QChar c : raw) {
        if (c.isSpace() && c != QChar(0x3000)) {
            space = true;
            continue;
        }
        if (space && !out.isEmpty()) out += QLatin1Char(' ');
        space = false;
        out += c;
    }
    while (out.startsWith(QChar(0x3000))) out.remove(0, 1);
    while (out.endsWith(QChar(0x3000))) out.chop(1);
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
    if (book < 1 || book > kLastBookNumber || chapter < 1 || verse < 1) return;
    // Psalm 151 as a book of its own (USFM's PS2) is the 151st psalm.
    if (book == kPsalm151) {
        book = 19;
        chapter += 150;
    }
    const QString text = cleanText(rawText);
    if (text.isEmpty()) return;   // a verse the translation leaves out
    // A verse split in two ("3a", "3b") is one verse.
    if (!out.verses.isEmpty()) {
        ParsedVerse& last = out.verses.last();
        if (last.book == book && last.chapter == chapter && last.verse == verse) {
            // The same verse twice (a file's mistake) stays once.
            if (!last.text.endsWith(text)) last.text += QLatin1Char(' ') + text;
            last.verseEnd = qMax(last.verseEnd, verseEnd);
            return;
        }
    }
    out.verses.append({ book, chapter, verse, qMax(verse, verseEnd), text });
}

// What to call a book Crater doesn't hold in the list of ones left out.
// Files name them by code ("ODA", "PssSol"), which few operators would
// recognise.
QString outsideCanonName(const QString& code)
{
    static const QHash<QString, QString> names = {
        { QStringLiteral("ADDDAN"), QStringLiteral("Additions to Daniel") },
        { QStringLiteral("5EZ"), QStringLiteral("5 Ezra") },
        { QStringLiteral("6EZ"), QStringLiteral("6 Ezra") },
        { QStringLiteral("4BA"), QStringLiteral("4 Baruch") },
        { QStringLiteral("2BA"), QStringLiteral("2 Baruch") },
        { QStringLiteral("ENO"), QStringLiteral("Enoch") },
        { QStringLiteral("JUB"), QStringLiteral("Jubilees") },
        { QStringLiteral("ODA"), QStringLiteral("Odes") },
        { QStringLiteral("ODES"), QStringLiteral("Odes") },
        { QStringLiteral("PSS"), QStringLiteral("Psalms of Solomon") },
        { QStringLiteral("PSSSOL"), QStringLiteral("Psalms of Solomon") },
        { QStringLiteral("LAO"), QStringLiteral("Laodiceans") },
        { QStringLiteral("EPLAO"), QStringLiteral("Laodiceans") },
    };
    return names.value(code.trimmed().toUpper(), code.trimmed());
}

void skipBook(ParsedBible& out, const QString& name)
{
    bool isNumber = false;
    name.trimmed().toInt(&isNumber);
    // A book known only by its number, past the ones Crater can place.
    const QString n = isNumber ? QStringLiteral("book %1").arg(name.trimmed()) : outsideCanonName(name);
    if (!n.isEmpty() && !out.skippedBooks.contains(n)) out.skippedBooks.append(n);
}

// A book named in a file: a number from 1 to 66, or a name close enough to
// one Crater knows (lookupBookName), the deuterocanon included. 0 when
// unsure. Files number the deuterocanon differently, so a number past 66
// says nothing.
int bookFromName(const QString& name)
{
    bool isNumber = false;
    const int number = name.trimmed().toInt(&isNumber);
    if (isNumber) return number >= 1 && number <= 66 ? number : 0;
    const auto meta = lookupBookName(name);
    return meta ? meta->bookNumber : 0;
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
            // bnumber follows the 66-book order. Past it, Zefania files number
            // the deuterocanon each their own way, so those go by name. A
            // book there that looks like one of the 66 by name ("Zusätze zu
            // Ester") can't be one.
            const int number = attr(x, "bnumber").toInt();
            const QString name = attr(x, "bname");
            book = number >= 1 && number <= 66 ? number : 0;
            if (!book) {
                const int named = bookFromName(name);
                book = number > 66 && named <= 66 ? 0 : named;
                // Past 66 a numbered Esdras can only be 1 or 2 Esdras.
                if (!book && number > 66) book = apocryphalEsdras(name);
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

// How many chapters each of the 66 has, in the usual English numbering.
constexpr int kChapterCounts[66] = {
    50, 40, 27, 36, 34, 24, 21, 4, 31, 24, 22, 25, 29, 36, 10, 13, 10, 42, 150, 31,
    12, 8, 66, 52, 5, 48, 12, 14, 3, 9, 1, 4, 7, 3, 3, 3, 2, 14, 4,
    28, 16, 24, 21, 28, 16, 16, 13, 6, 6, 4, 4, 5, 3, 6, 4, 3, 1, 13, 5,
    5, 3, 5, 1, 1, 1, 22,
};

// The chapter counts Bibles give `book`, the usual one first. Some number
// books differently: Esther with the Greek additions has 16, Daniel with
// Susanna and Bel 14, Joel 4 and Malachi 3 in the Hebrew numbering, the
// Psalms 151 in Orthodox Bibles.
const QList<int>& chapterCounts(int book)
{
    static const QHash<int, QList<int>> counts = [] {
        QHash<int, QList<int>> h;
        for (int n = 1; n <= 66; ++n) h.insert(n, { kChapterCounts[n - 1] });
        h[17] << 16;
        h[19] << 151;
        h[27] << 13 << 14;
        h[29] << 4;
        h[39] << 3;
        const int deuterocanon[][2] = {
            { 67, 14 }, { 68, 16 }, { 69, 16 }, { 70, 19 }, { 71, 51 }, { 72, 5 }, { 73, 1 },
            { 74, 1 }, { 75, 1 }, { 76, 1 }, { 77, 16 }, { 78, 15 }, { 79, 7 }, { 80, 18 },
            { 81, 9 }, { 82, 16 }, { 83, 1 }, { 85, 14 },
        };
        for (const auto& d : deuterocanon) h.insert(d[0], { d[1] });
        h[69] << 10;   // Greek Esther numbered as the Hebrew
        h[72] << 6;    // Baruch with the Letter of Jeremiah as chapter 6
        return h;
    }();
    static const QList<int> none;
    const auto it = counts.constFind(book);
    return it == counts.cend() ? none : *it;
}

// How far `chapters` is from the nearest count Bibles give `book`.
int chapterGap(int book, int chapters)
{
    int gap = INT_MAX;
    for (int c : chapterCounts(book)) gap = qMin(gap, qAbs(c - chapters));
    return gap;
}

// Books few Bibles have, or have as books of their own. A book whose name
// says nothing goes to one of these only when nothing commoner fits:
// Daniel with 14 chapters is Daniel, not the Greek Daniel.
bool isRareBook(int book)
{
    return book == 69 || (book >= 73 && book <= 76) || (book >= 79 && book <= 83) || book == 85;
}

// The orders Bibles put their books in: each Old Testament order with each
// New Testament one. Books a Bible lacks are simply passed over, so one
// order covers a Protestant Bible and a Catholic one alike.
const QList<QList<int>>& bookOrders()
{
    static const QList<QList<int>> orders = [] {
        const auto range = [](int from, int to) {
            QList<int> r;
            for (int n = from; n <= to; ++n) r << n;
            return r;
        };
        const QList<QList<int>> oldTestaments = {
            // Catholic (NAB, Jerusalem): Tobit and Judith after Nehemiah, the
            // Maccabees after Esther, Wisdom and Sirach after the Song, Baruch
            // after Lamentations.
            range(1, 16) + QList<int>{ 67, 68, 17, 69, 77, 78, 79, 80 } + range(18, 22) + QList<int>{ 70, 71 }
                + range(23, 25) + QList<int>{ 72, 73, 26, 27, 85, 74, 75, 76 } + range(28, 39),
            // Vulgate and Douay: the Maccabees last.
            range(1, 16) + QList<int>{ 67, 68, 17, 69 } + range(18, 22) + QList<int>{ 70, 71 }
                + range(23, 25) + QList<int>{ 72, 73, 26, 27, 85, 74, 75, 76 } + range(28, 39)
                + QList<int>{ 77, 78, 79, 80 },
            // The KJV's Apocrypha, between the testaments.
            range(1, 39) + QList<int>{ 81, 82, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 83, 77, 78, 79, 80 },
            // Luther, and Bibles that follow it (the Slovak Catholic): after Malachi.
            range(1, 39) + QList<int>{ 68, 70, 67, 71, 72, 73, 77, 78, 79, 80, 69, 74, 75, 76, 83 },
            // Russian Synodal.
            range(1, 14) + QList<int>{ 83, 15, 16, 81, 67, 68, 17, 69 } + range(18, 22) + QList<int>{ 70, 71 }
                + range(23, 25) + QList<int>{ 73, 72, 26, 27, 85, 74, 75, 76 } + range(28, 39)
                + QList<int>{ 77, 78, 79, 80, 82 },
        };
        const QList<QList<int>> newTestaments = {
            range(40, 66),
            // Luther: Hebrews and James after the letters of Peter and John.
            range(40, 57) + QList<int>{ 60, 61, 62, 63, 64, 58, 59, 65, 66 },
            // Russian: the general letters straight after Acts.
            range(40, 44) + range(59, 65) + range(45, 58) + QList<int>{ 66 },
        };
        QList<QList<int>> out;
        for (const QList<int>& ot : oldTestaments)
            for (const QList<int>& nt : newTestaments) out.append(ot + nt);
        return out;
    }();
    return orders;
}

// Canonical numbers for books known only by their names, in file order, with
// 0 for a book that can't be placed. OpenSong names books in the
// translation's own language, so a name alone often says nothing.
//
// Each book is matched against each order Bibles use (bookOrders), as two
// lists are lined up in a diff: books keep the order of the file, and either
// side may have books the other lacks. A pairing scores by what the book
// says about itself:
//   - its name, when it resolves (bookFromName: numbers, names and close
//     spellings). Such a book takes that number or none, so a name that
//     resolves wrongly is left out rather than pushing the rest along.
//   - otherwise a looser guess at its name (guessBookName),
//   - and its number of chapters, which differs from book to book far more
//     than names do.
// The best-scoring order wins. A book placed without its name to go by is
// kept only when the file gives enough to trust its order, three books
// placed by name or twenty books or more whose chapter counts mostly agree,
// and its chapter count fits, and only when it doesn't pass over books of
// the 66 the file lacks to get there (Matthew a chapter short is not
// Leviticus). Books between two placed ones then take the numbers between
// them in that order when the counts match exactly, and when the file is
// trusted, books before the first or after the last take the ones leading up
// to it or following on. A book its name places that ended up off the
// chosen order still takes its own number when that's free and its chapter
// count fits.
//
// Douay and other Vulgate-numbered Bibles call Samuel 1 and 2 Kings and
// Kings 3 and 4 Kings. A "3 Kings" or "4 Kings" says a file numbers them so.
//
// With too little to go by otherwise (names in another script, chapters
// left out), a whole Bible or a whole testament says by its size which
// books it holds, as long as what was recognised sits where that order puts
// it.
struct FileBook { QString name; int chapters = 0; };

QList<int> placeBooks(const QList<FileBook>& books, bool* byPosition)
{
    const int n = int(books.size());
    struct Evidence { int name = 0; int guess = 0; bool unheld = false; };
    QList<Evidence> evidence(n);
    static const QRegularExpression vulgateKings(
        QStringLiteral(R"(^(1|2|3|4|i|ii|iii|iv)\.?\s*(kings|kgs|regum|reis|reyes|rois)\b)"),
        QRegularExpression::CaseInsensitiveOption);
    bool vulgateNumbering = false;
    for (const FileBook& b : books) {
        const auto m = vulgateKings.match(b.name.trimmed());
        if (m.hasMatch() && (m.captured(1) == u"3" || m.captured(1) == u"4"
                             || m.captured(1).compare(u"iii", Qt::CaseInsensitive) == 0
                             || m.captured(1).compare(u"iv", Qt::CaseInsensitive) == 0))
            vulgateNumbering = true;
    }
    for (int i = 0; i < n; ++i) {
        if (vulgateNumbering) {
            if (const auto m = vulgateKings.match(books[i].name.trimmed()); m.hasMatch()) {
                const QString k = m.captured(1).toLower();
                evidence[i].name = k == u"1" || k == u"i" ? 9 : k == u"2" || k == u"ii" ? 10
                                 : k == u"3" || k == u"iii" ? 11 : 12;
                continue;
            }
        }
        evidence[i].name = bookFromName(books[i].name);
        if (!evidence[i].name) {
            evidence[i].unheld = isUnheldBookName(books[i].name);
            if (const auto g = guessBookName(books[i].name)) evidence[i].guess = g->bookNumber;
        }
    }
    constexpr int kNever = INT_MIN / 4;
    const auto pairScore = [&](int i, int book) {
        const Evidence& e = evidence[i];
        if (e.unheld || (e.name && e.name != book)) return kNever;
        int score = e.name ? 10 : e.guess == book ? 4 : e.guess ? -2 : 0;
        // The usual count says more than another Bible's numbering.
        const QList<int>& counts = chapterCounts(book);
        const int gap = chapterGap(book, books[i].chapters);
        score += !counts.isEmpty() && counts.first() == books[i].chapters ? 6
               : gap == 0 ? 4 : gap == 1 ? 1 : -3;
        if (isRareBook(book)) score -= 3;
        return score;
    };

    struct Match { int file; int position; int book; };
    QList<Match> best;
    const QList<int>* bestOrder = nullptr;
    int bestScore = INT_MIN;
    for (const QList<int>& order : bookOrders()) {
        const int m = int(order.size());
        // score[i][j]: the best pairing of the first i books with the first
        // j of the order. Passing over a place in the order between two
        // books costs a little, so of two equal pairings the one that keeps
        // the books together wins (Malachi as Malachi, not as 2 Timothy,
        // which has as many chapters). Before the first book and after the
        // last it costs nothing: a New Testament passes over the Old.
        // On a tie that still leaves, one of the 66 wins: Lamentations and
        // Baruch both have five chapters and sit side by side.
        constexpr int kScale = 100;
        const auto gain = [&](int i, int j) {
            const int pair = pairScore(i - 1, order[j - 1]);
            if (pair == kNever || pair <= 0) return kNever;
            return pair * kScale - (order[j - 1] > 66 ? 2 : 0);
        };
        QList<QList<int>> score(n + 1, QList<int>(m + 1, 0));
        for (int i = 1; i <= n; ++i)
            for (int j = 1; j <= m; ++j) {
                int s = qMax(score[i - 1][j], score[i][j - 1] - 1);
                if (const int g = gain(i, j); g != kNever) s = qMax(s, score[i - 1][j - 1] + g);
                score[i][j] = s;
            }
        int end = m;
        for (int j = 0; j <= m; ++j)
            if (score[n][j] > score[n][end]) end = j;
        if (score[n][end] <= bestScore) continue;
        bestScore = score[n][end];
        bestOrder = &order;
        best.clear();
        for (int i = n, j = end; i > 0 && j > 0; ) {
            const int g = gain(i, j);
            if (g != kNever && score[i][j] == score[i - 1][j - 1] + g) {
                best.prepend({ i - 1, j - 1, order[j - 1] });
                --i;
                --j;
            } else if (score[i][j] == score[i - 1][j]) {
                --i;
            } else {
                --j;
            }
        }
    }

    int named = 0, fitting = 0, firstNamed = n, lastNamed = -1;
    for (const Match& match : std::as_const(best)) {
        if (evidence[match.file].name) {
            ++named;
            firstNamed = qMin(firstNamed, match.file);
            lastNamed = match.file;
        }
        if (chapterGap(match.book, books[match.file].chapters) == 0) ++fitting;
    }
    // Most of the file fits the order chapter for chapter, or its names
    // place three books or more.
    const bool agrees = n >= 20 && fitting * 5 >= n * 4;
    const bool trusted = named >= 3 || agrees;

    QList<int> out(n, 0);
    *byPosition = false;
    if (!trusted && (n == 66 || n == 39 || n == 27)) {
        const int first = n == 27 ? 40 : 1;
        bool inOrder = true;
        for (int i = 0; i < n; ++i)
            if (evidence[i].unheld || (evidence[i].name && evidence[i].name != first + i)) inOrder = false;
        if (inOrder) {
            for (int i = 0; i < n; ++i) out[i] = first + i;
            *byPosition = true;
            return out;
        }
    }
    QList<Match> kept;
    for (const Match& match : std::as_const(best)) {
        const Evidence& e = evidence[match.file];
        if (!e.name) {
            const bool guessed = e.guess == match.book;
            const bool fits = chapterGap(match.book, books[match.file].chapters) == 0;
            // Going by names alone, only between two named books: past them
            // a short count fits too many books (Matthew as Nahum).
            const bool boxedIn = match.file > firstNamed && match.file < lastNamed;
            if (!(agrees || (trusted && boxedIn)) || !(fits || guessed)) continue;
            if (!guessed) *byPosition = true;
        }
        kept.append(match);
    }
    // A book placed by its count alone that passes over books of the 66 the
    // file lacks, to reach a place or leave it, is on a chance match: a
    // 27-chapter Matthew at the start of a New Testament fits Leviticus. Two
    // are let pass, for a file that lacks a book or two (a Swahili New
    // Testament without Philippians).
    constexpr int kMissingAllowed = 2;
    const auto canonPassed = [&](int fromPosition, int toPosition) {
        int count = 0;
        for (int p = fromPosition + 1; p < toPosition; ++p)
            if (bestOrder->at(p) <= 66) ++count;
        return count;
    };
    for (bool dropped = true; dropped; ) {
        dropped = false;
        for (int k = 0; k < kept.size(); ++k) {
            const Evidence& e = evidence[kept[k].file];
            if (e.name || e.guess == kept[k].book) continue;
            const bool jumpIn = k > 0 && canonPassed(kept[k - 1].position, kept[k].position)
                                         > kept[k].file - kept[k - 1].file - 1 + kMissingAllowed;
            const bool jumpOut = k + 1 < kept.size() && canonPassed(kept[k].position, kept[k + 1].position)
                                                         > kept[k + 1].file - kept[k].file - 1 + kMissingAllowed;
            if (jumpIn || jumpOut) {
                kept.removeAt(k);
                dropped = true;
                break;
            }
        }
    }
    for (const Match& match : std::as_const(kept)) out[match.file] = match.book;
    if (kept.isEmpty()) return out;
    // Books from `from` to `to` in the file (inclusive) take `numbers`, one
    // for one, unless one of them says by its name it's something else.
    const auto fill = [&](int from, int to, const QList<int>& numbers) {
        if (to < from || numbers.size() != to - from + 1) return;
        for (int i = from; i <= to; ++i)
            if (out[i] || evidence[i].name || evidence[i].unheld) return;
        for (int i = from; i <= to; ++i) {
            out[i] = numbers[i - from];
            if (evidence[i].guess != out[i]) *byPosition = true;
        }
    };
    // The order's books from position `from` up to `to` (exclusive): all of
    // them, all but the ones few Bibles carry as books (a Catholic Bible has
    // no Greek Esther or Susanna of its own), or only the 66.
    enum class Books { All, Common, Canon };
    const auto between = [&](int from, int to, Books which) {
        QList<int> numbers;
        for (int p = qMax(0, from); p < qMin(int(bestOrder->size()), to); ++p) {
            const int book = bestOrder->at(p);
            if (which == Books::Canon && book > 66) continue;
            if (which == Books::Common && isRareBook(book)) continue;
            numbers << book;
        }
        return numbers;
    };
    for (int k = 1; k < kept.size(); ++k) {
        const Match& a = kept[k - 1];
        const Match& b = kept[k];
        if (b.file - a.file < 2) continue;
        for (const Books which : { Books::All, Books::Common, Books::Canon }) {
            fill(a.file + 1, b.file - 1, between(a.position + 1, b.position, which));
            if (out[a.file + 1]) break;
        }
    }
    if (trusted) {
        const Match& first = kept.first();
        const Match& last = kept.last();
        QList<int> before = between(0, first.position, Books::Canon);
        if (before.size() >= first.file) fill(0, first.file - 1, before.mid(before.size() - first.file));
        const QList<int> after = between(last.position + 1, int(bestOrder->size()), Books::Canon);
        if (after.size() >= n - 1 - last.file) fill(last.file + 1, n - 1, after.first(n - 1 - last.file));
    }
    // Named books the chosen order passed over (the Psalms after Revelation
    // in a New Testament with Psalms): their own number, when it's free and
    // their chapters fit.
    QSet<int> used;
    for (int number : std::as_const(out))
        if (number) used.insert(number);
    for (int i = 0; i < n; ++i) {
        const int name = evidence[i].name;
        if (out[i] || !name || used.contains(name) || chapterGap(name, books[i].chapters) > 1) continue;
        out[i] = name;
        used.insert(name);
    }
    return out;
}

// OpenSong: <bible><b n="Genesis"><c n="1"><v n="1">. The same reader takes
// the "XML Bible" layout Beblia publishes, <bible><testament><book
// number="1"><chapter number="1"><verse number="1">, whose book numbers
// follow the 66-book order like Zefania's.
void readOpenSong(QXmlStreamReader& x, ParsedBible& out)
{
    out.format = QStringLiteral("OpenSong");
    struct Book { QString name; QList<ParsedVerse> verses; };
    QList<Book> books;
    int chapter = 0;
    while (!x.atEnd()) {
        x.readNext();
        if (!x.isStartElement()) continue;
        if (isName(x, "bible") && !attr(x, "translation").isEmpty()) {
            out.name = attr(x, "translation");
        } else if (isName(x, "b") || isName(x, "book")) {
            const QString number = attr(x, "number");
            books.append({ number.isEmpty() ? attr(x, "n") : number, {} });
            chapter = 0;
        } else if (isName(x, "c") || isName(x, "chapter")) {
            const QString number = attr(x, "number");
            chapter = (number.isEmpty() ? attr(x, "n") : number).toInt();
        } else if ((isName(x, "v") || isName(x, "verse")) && !books.isEmpty()) {
            int first = 0, last = 0;
            const QString number = attr(x, "number");
            const bool ok = parseVerseNumbers(number.isEmpty() ? attr(x, "n") : number, &first, &last);
            const QString text = cleanText(readMixed(x, {}));
            if (!ok || chapter <= 0 || text.isEmpty()) continue;
            // A verse split in two ("3a", "3b") is one verse, as in addVerse.
            QList<ParsedVerse>& verses = books.last().verses;
            if (!verses.isEmpty() && verses.last().chapter == chapter && verses.last().verse == first) {
                if (!verses.last().text.endsWith(text)) verses.last().text += QLatin1Char(' ') + text;
                verses.last().verseEnd = qMax(verses.last().verseEnd, last);
                continue;
            }
            verses.append({ 0, chapter, first, last, text });
        }
    }
    books.removeIf([](const Book& b) { return b.verses.isEmpty(); });
    if (books.isEmpty()) return;

    const QList<int> numbers = placeBooks([&] {
        QList<FileBook> list;
        for (const Book& b : books) {
            int chapters = 0;
            for (const ParsedVerse& v : b.verses) chapters = qMax(chapters, v.chapter);
            list.append({ b.name, chapters });
        }
        return list;
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
        // A verse split across two entries is "Gen.13.11!a" and
        // "Gen.13.11!b": the part after "!" names the half.
        const int verse = parts[2].section(QLatin1Char('!'), 0, 0).toInt();
        if (i == 0) {
            ref.bookCode = parts[0];
            ref.book     = bookFromOsisCode(parts[0]);
            if (!ref.book) ref.book = bookFromUsfmCode(parts[0]);   // "Psa", "Mat" in looser files
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
    int sinceVerseStart = 0;   // tokens since a container verse opened
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
        ++sinceVerseStart;
        if (x.isStartElement()) {
            if (skipDepth > 0) { ++skipDepth; continue; }
            // A milestone verse never closed with an eID ends with its
            // chapter or book, not in the next book's introduction.
            if ((isName(x, "chapter") || (isName(x, "div") && attr(x, "type") == u"book"))
                && isOpen && !container)
                flush();
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
                sinceVerseStart = 0;
            } else if (isName(x, "title") && isOpen && attr(x, "canonical") == u"true"
                       && attr(x, "type") == u"psalm" && cleanText(text).isEmpty()) {
                // A psalm's title opening the verse it belongs to: where the
                // Hebrew numbering makes it verse 1, it is the verse. Other
                // canonical titles (Psalm 119's acrostic letters) are
                // headings.
            } else if (isAnyName(x, { "note", "title", "rdg" })) {
                skipDepth = 1;
            } else if (isAnyName(x, { "lb", "l", "p", "lg" }) && isOpen) {
                text += QLatin1Char(' ');
            }
        } else if (x.isEndElement()) {
            if (skipDepth > 0) { --skipDepth; continue; }
            if (isName(x, "work")) {
                inWork = false;
            } else if (isName(x, "verse") && isOpen && container) {
                // <verse osisID="Gen.1.1"/>, self-closing with no sID, is
                // used as a milestone too: its text follows it.
                if (sinceVerseStart == 1) container = false;
                else flush();
            } else if (isAnyName(x, { "l", "p", "lg", "title" }) && isOpen) {
                text += QLatin1Char(' ');
            }
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
        QStringLiteral("qa"),   // Psalm 119's acrostic letters (ALEPH, BETH)
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
            } else if (isName(x, "char")) {
                // Alternate and published numbers, and the reference after
                // a quotation, aren't verse text.
                const QString style = attr(x, "style");
                if (style == u"va" || style == u"vp" || style == u"ca" || style == u"rq") skipDepth = 1;
            } else if (isAnyName(x, { "row", "cell" }) && isOpen) {
                text += QLatin1Char(' ');
            }
        } else if (x.isEndElement()) {
            if (skipDepth > 0) { --skipDepth; continue; }
            if (isName(x, "para")) {
                heading = false;
                if (isOpen) text += QLatin1Char(' ');
            } else if (isAnyName(x, { "row", "cell" }) && isOpen) {
                text += QLatin1Char(' ');
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
        QStringLiteral("qc"), QStringLiteral("qm"), QStringLiteral("qd"),
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
    // USFM 3 milestones (\qt-s |who="Jesus"\*, \ts\*, the aligned-word
    // \zaln-s ...\* of unfoldingWord texts) carry no verse text.
    static const QRegularExpression milestones(
        QStringLiteral(R"(\\[A-Za-z0-9]+(?:-[se])?[ \t]*(?:\|[^\\]*)?\\\*)"));
    t.remove(milestones);
    // Footnotes, cross references and figures go with their contents. One
    // left unclosed stops at the next verse, chapter or book rather than
    // taking everything up to some later note's end with it. A stray closer
    // (\f* on its own) isn't an opener.
    static const QRegularExpression notes(
        QStringLiteral(R"(\\(f|fe|ef|x|ex|fig)\b(?!\*)(?:(?!\\(?:[cv]|id)\s).)*?\\\1\*)"),
        QRegularExpression::DotMatchesEverythingOption);
    t.remove(notes);
    static const QRegularExpression unclosedNotes(
        QStringLiteral(R"(\\(?:f|fe|ef|x|ex|fig)\b(?!\*)(?:(?!\\(?:[cv]|id)\s).)*)"),
        QRegularExpression::DotMatchesEverythingOption);
    t.remove(unclosedNotes);
    // Sidebars (\esb ... \esbe) and the reference after a quotation
    // (\rq Isa 40:3\rq*) aren't verse text either, bounded the same way.
    static const QRegularExpression asides(
        QStringLiteral(R"(\\esb\b(?:(?!\\(?:c|id)\s).)*?\\esbe\b|\\rq\b(?!\*)(?:(?!\\(?:[cv]|id)\s).)*?\\rq\*)"),
        QRegularExpression::DotMatchesEverythingOption);
    t.remove(asides);
    // Attributes on a word (\w grace|strong="G5485"\w*) go, the word stays.
    static const QRegularExpression attributes(QStringLiteral(R"(\|[^\\]*(?=\\\+?[a-z0-9]*\*))"));
    t.remove(attributes);
    // Word markers wrap every word of a Bible with Strong's numbers. Going
    // now, as plain text, saves the marker loop below most of its work. The
    // space after an opening marker belongs to the marker, so Chinese or
    // Thai words, which have none between them, don't gain one.
    for (const QLatin1String word : { QLatin1String("\\w "), QLatin1String("\\+w "),
                                      QLatin1String("\\w*"), QLatin1String("\\+w*") })
        t.remove(word);
    t.replace(QLatin1Char('~'), QLatin1Char(' '));
    t.remove(QStringLiteral("//"));

    static const QRegularExpression marker(QStringLiteral(R"(\\(\+?)([A-Za-z]+[0-9]*)(\*?))"));
    static const QRegularExpression number(
        QStringLiteral(R"(^\s+(\d+[a-z]?(?:[-\x{2013}]\d+[a-z]?)?))"));
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
        // An alternate number never closed ends with its verse.
        if (name == u"v" || name == u"c" || classifyMarker(name) != Marker::Character)
            inlineSkip = false;
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
                // Its space belongs to the marker, not the text, which
                // matters where words have no spaces between them. Kept
                // otherwise: a file that writes "the\nd LORD\nd*" still
                // reads "the LORD".
                if (pos < t.size() && t.at(pos).isSpace() && m.capturedStart() > 0) {
                    switch (t.at(m.capturedStart() - 1).script()) {
                    case QChar::Script_Han:
                    case QChar::Script_Hiragana:
                    case QChar::Script_Katakana:
                    case QChar::Script_Thai:
                    case QChar::Script_Lao:
                    case QChar::Script_Khmer:
                    case QChar::Script_Myanmar:
                    case QChar::Script_Tibetan:
                        ++pos;
                        break;
                    default:
                        break;
                    }
                }
                break;
            }
        }
    }
    flush();
}

// ── Files ───────────────────────────────────────────────────────────────

// An old 8-bit file is Windows-1252 far more often than true Latin-1. The
// two differ only at 0x80-0x9F, where 1252 has curly quotes, dashes and the
// ellipsis.
QString fromWindows1252(const QByteArray& bytes)
{
    static const char16_t high[32] = {
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
    };
    QString out;
    out.reserve(bytes.size());
    for (const char ch : bytes) {
        const uchar b = uchar(ch);
        out += (b >= 0x80 && b < 0xA0) ? QChar(high[b - 0x80]) : QChar(b);
    }
    return out;
}

// Text files are UTF-8 unless a byte-order mark says otherwise (UTF-16
// USFM exists). Invalid bytes decide between the rest: a UTF-8 file with a
// stray bad byte still has far more good non-ASCII characters than bad
// ones, and only loses that character. An 8-bit file has none good.
QString decode(const QByteArray& bytes)
{
    // A byte-order mark settles it, UTF-8 included.
    if (const auto bom = QStringConverter::encodingForData(bytes)) {
        QStringDecoder decoder(*bom);
        QString text = decoder.decode(bytes);
        if (text.startsWith(QChar(0xFEFF))) text.remove(0, 1);
        return text;
    }
    QStringDecoder utf8(QStringDecoder::Utf8);
    QString text = utf8.decode(bytes);
    if (utf8.hasError()) {
        qsizetype good = 0, bad = 0;
        for (const QChar c : std::as_const(text)) {
            if (c == QChar(QChar::ReplacementCharacter)) ++bad;
            else if (c.unicode() > 0x7F) ++good;
        }
        if (good <= bad) return fromWindows1252(bytes);
    }
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
    // Decoded first, so UTF-16 USFM is found too. An odd byte count from
    // cutting a UTF-16 file mid-character doesn't matter here.
    const QString head = decode(bytes.left(64 * 1024));
    if (head.contains(QStringLiteral("\\id ")) || head.contains(QStringLiteral("\\c "))) return Format::Usfm;
    return Format::Unknown;
}

// One chosen file, or one file inside a chosen zip.
struct Input {
    QString name;           // the file's own name, for messages
    QString folder;         // where it is, so book files can be told apart by folder
    QString folderLabel;    // that folder's own name, or the zip's
    QByteArray bytes;
};

struct Source {
    Input input;
    Format format;
};

QString formatName(Format format)
{
    switch (format) {
    case Format::Zefania:  return QStringLiteral("Zefania XML");
    case Format::OpenSong: return QStringLiteral("OpenSong");
    case Format::Osis:     return QStringLiteral("OSIS");
    case Format::Usx:      return QStringLiteral("USX");
    case Format::Usfm:     return QStringLiteral("USFM");
    case Format::Unknown:  break;
    }
    return {};
}

// A zip can hold one Bible in several formats (a download that offers each
// of them) or several Bibles. Each XML file is one Bible, and each folder of
// USFM or USX book files one. The same Bible in several formats is read from
// the one that says most about it: OSIS and Zefania name the translation and
// number every book, USX and USFM number the books, and OpenSong only names
// them. Several Bibles are refused rather than read as one.
bool keepOneBible(QList<Source>& sources, ParsedBible& out)
{
    struct Bible { Format format; QString folder; QString label; QList<qsizetype> members; };
    QList<Bible> bibles;
    for (qsizetype i = 0; i < sources.size(); ++i) {
        const Source& s = sources[i];
        const bool bookFiles = s.format == Format::Usfm || s.format == Format::Usx;
        const auto same = std::find_if(bibles.begin(), bibles.end(), [&](const Bible& b) {
            return bookFiles && b.format == s.format && b.folder == s.input.folder;
        });
        if (same != bibles.end()) {
            same->members.append(i);
            continue;
        }
        bibles.append({ s.format, s.input.folder,
                        bookFiles ? s.input.folderLabel : s.input.name.section(u'.', 0, 0), { i } });
    }
    if (bibles.size() < 2) return true;

    for (const Bible& b : std::as_const(bibles)) {
        const auto sameFormat = std::count_if(bibles.cbegin(), bibles.cend(),
                                              [&](const Bible& other) { return other.format == b.format; });
        if (sameFormat < 2) continue;
        QStringList labels;
        for (const Bible& each : std::as_const(bibles))
            if (!labels.contains(each.label)) labels.append(each.label);
        const QString named = labels.size() > 4
            ? QStringLiteral("%1 and %2 more").arg(labels.first(3).join(QStringLiteral(", "))).arg(labels.size() - 3)
            : labels.size() > 1
                ? QStringLiteral("%1 and %2").arg(labels.first(labels.size() - 1).join(QStringLiteral(", ")), labels.last())
                : labels.join(QString());
        out.error = QStringLiteral("The zip holds more than one Bible (%1). Unzip it and choose one.").arg(named);
        return false;
    }

    const auto rank = [](Format f) {
        switch (f) {
        case Format::Osis:     return 0;
        case Format::Zefania:  return 1;
        case Format::Usx:      return 2;
        case Format::Usfm:     return 3;
        default:               return 4;
        }
    };
    std::sort(bibles.begin(), bibles.end(),
              [&](const Bible& a, const Bible& b) { return rank(a.format) < rank(b.format); });
    for (qsizetype k = 1; k < bibles.size(); ++k) out.otherFormats.append(formatName(bibles[k].format));
    QList<Source> kept;
    for (const qsizetype i : std::as_const(bibles.first().members)) kept.append(std::move(sources[i]));
    sources = std::move(kept);
    return true;
}

// Reads the files inside the zip at `path` into `inputs`, at any depth: a
// Digital Bible Library bundle keeps its books in release/USX_1/. Folders,
// macOS's __MACOSX copies and hidden files are passed over. A zip is someone
// else's file, so what it may hold is capped before anything is inflated.
// False with out.error set when the zip can't be read at all.
bool readZip(const QString& path, QList<Input>& inputs, ParsedBible& out)
{
    constexpr qint64 kMaxBytes = qint64(256) * 1024 * 1024;
    constexpr qsizetype kMaxFiles = 5000;
    const QString zipName = QFileInfo(path).fileName();
    bundle::ZipReader zip(path);
    if (!zip.isOpen()) {
        out.error = QStringLiteral("%1 is damaged or isn't a zip, so it couldn't be opened.").arg(zipName);
        return false;
    }
    zip.setMaxInflatedSize(kMaxBytes);

    static const QRegularExpression separator(QStringLiteral("[/\\\\]"));
    const QString zipLabel = QFileInfo(path).completeBaseName();
    QStringList names;
    QSet<QString> seen;
    qint64 total = 0;
    for (const QString& name : zip.entryNames()) {
        if (name.endsWith(u'/') || name.endsWith(u'\\') || seen.contains(name)) continue;
        const QStringList parts = name.split(separator, Qt::SkipEmptyParts);
        // "./GEN.usx" is in the zip's top folder, not a hidden one.
        const bool skipped = std::any_of(parts.cbegin(), parts.cend(), [](const QString& part) {
            return (part.startsWith(u'.') && part != u"." && part != u"..")
                || part.compare(u"__MACOSX", Qt::CaseInsensitive) == 0;
        });
        if (skipped || parts.isEmpty()) continue;
        seen.insert(name);
        names.append(name);
        total += qMax<qint64>(0, zip.entrySize(name));
    }
    if (names.size() > kMaxFiles || total > kMaxBytes) {
        out.error = QStringLiteral("%1 holds more than one Bible would. Unzip it and choose the Bible's files.")
                        .arg(zipName);
        return false;
    }
    for (const QString& name : std::as_const(names)) {
        QStringList parts = name.split(separator, Qt::SkipEmptyParts);
        parts.removeAll(QStringLiteral("."));
        if (parts.isEmpty()) continue;
        const QString fileName = parts.takeLast();
        QByteArray bytes = zip.readEntry(name);
        if (bytes.isEmpty() && zip.entrySize(name) != 0) {
            // Compressed in a way Crater doesn't read, encrypted, or damaged.
            out.warnings.append(QStringLiteral("%1 in %2 couldn't be read, so it was left out.")
                                    .arg(fileName, zipName));
            continue;
        }
        inputs.append({ fileName, path + u'|' + parts.join(u'/'),
                        parts.isEmpty() ? zipLabel : parts.last(), std::move(bytes) });
    }
    return true;
}

}  // namespace

int bookFromUsfmCode(QStringView code)
{
    return indexIn(kUsfmCodes, kUsfmExtra, code);
}

int bookFromOsisCode(QStringView code)
{
    return indexIn(kOsisCodes, kOsisExtra, code);
}

ParsedBible parseBibleFiles(const QStringList& paths)
{
    ParsedBible out;
    if (paths.isEmpty()) {
        out.error = QStringLiteral("No file chosen.");
        return out;
    }
    // USFM and USX downloads are zips of book files. Those are read in
    // memory and stand in for the files chosen one by one.
    QList<Input> inputs;
    bool zipped = false;
    for (const QString& path : paths) {
        QFile file(path);
        if (!file.open(QIODevice::ReadOnly)) {
            out.error = QStringLiteral("Couldn't open %1.").arg(QFileInfo(path).fileName());
            return out;
        }
        const QByteArray magic = file.peek(4);
        if (magic == QByteArrayLiteral("PK\x03\x04") || magic == QByteArrayLiteral("PK\x05\x06")) {
            file.close();
            if (!readZip(path, inputs, out)) return out;
            zipped = true;
            continue;
        }
        const QFileInfo info(path);
        inputs.append({ info.fileName(), info.absolutePath(), info.dir().dirName(), file.readAll() });
    }

    // A folder of book files often carries other things too (eBible's
    // copyright page, a stylesheet). With several files chosen those are
    // passed over; a single file has to be a Bible.
    QList<Source> sources;
    for (Input& input : inputs) {
        const Format f = detect(input.bytes);
        if (f == Format::Unknown && (inputs.size() > 1 || zipped)) {
            out.ignoredFiles.append(input.name);
            continue;
        }
        if (f == Format::Unknown) {
            out.error = QStringLiteral("%1 isn't a Bible format Crater reads "
                                       "(Zefania XML, OpenSong, OSIS, USFM or USX).")
                            .arg(input.name);
            return out;
        }
        sources.append({ std::move(input), f });
    }
    if (sources.isEmpty()) {
        out.error = zipped && paths.size() == 1
            ? QStringLiteral("Nothing in %1 is a Bible format Crater reads "
                             "(Zefania XML, OpenSong, OSIS, USFM or USX).").arg(QFileInfo(paths.first()).fileName())
            : QStringLiteral("None of the chosen files is a Bible format Crater reads "
                             "(Zefania XML, OpenSong, OSIS, USFM or USX).");
        return out;
    }
    // Files chosen together, a zip among them, are one Bible by choice.
    if (zipped && paths.size() == 1 && !keepOneBible(sources, out)) return out;
    const Format format = sources.first().format;
    if (std::any_of(sources.cbegin(), sources.cend(), [&](const Source& s) { return s.format != format; })) {
        out.error = QStringLiteral("The chosen files are in different formats. Choose the files of one Bible.");
        return out;
    }
    if (format != Format::Usfm && format != Format::Usx && sources.size() > 1) {
        out.error = QStringLiteral("A %1 Bible is a single file. Choose just that one.")
                        .arg(format == Format::Zefania ? QStringLiteral("Zefania") : formatName(format));
        return out;
    }
    out.fileCount = int(sources.size());

    for (const Source& source : std::as_const(sources)) {
        const QByteArray& bytes = source.input.bytes;
        const Format f = source.format;
        QXmlStreamReader x(bytes);
        const qsizetype versesBefore = out.verses.size();
        switch (f) {
        case Format::Zefania:  readZefania(x, out); break;
        case Format::OpenSong: readOpenSong(x, out); break;
        case Format::Osis:     readOsis(x, out); break;
        case Format::Usx:      readUsx(x, out); break;
        case Format::Usfm:     readUsfm(decode(bytes), out); break;
        case Format::Unknown:  break;
        }
        if (x.hasError() && f != Format::Usfm) {
            QString reason = x.errorString().trimmed();
            while (reason.endsWith(u'.')) reason.chop(1);
            const QString problem = QStringLiteral("%1 is damaged at line %2 (%3)")
                .arg(source.input.name, QString::number(x.lineNumber()), reason);
            const bool nothingRead = out.verses.size() == versesBefore;
            if (nothingRead && sources.size() == 1) {
                out.error = problem + QStringLiteral(", so nothing could be read.");
                return out;
            }
            // Reading stops at the damage. What came before is usable, but
            // the operator has to know the rest is missing.
            out.warnings.append(problem + (nothingRead
                ? QStringLiteral(", so it was left out.")
                : QStringLiteral(". Only what comes before that was read.")));
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
        out.error = QStringLiteral("No Bible verses were found in this file.");
    return out;
}

}  // namespace crater::import
