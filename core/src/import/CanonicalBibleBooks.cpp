#include "import/CanonicalBibleBooks.h"

#include <QHash>
#include <QRegularExpression>

#include <algorithm>
#include <climits>
#include <tuple>

namespace crater::import {

namespace {

QList<BibleBookMeta> buildCanonicalList()
{
    using S = QString;
    return {
        // Old Testament (1..39)
        {QStringLiteral("Genesis"),         QStringLiteral("Gen"),    1,  QStringLiteral("OT")},
        {QStringLiteral("Exodus"),          QStringLiteral("Exod"),   2,  QStringLiteral("OT")},
        {QStringLiteral("Leviticus"),       QStringLiteral("Lev"),    3,  QStringLiteral("OT")},
        {QStringLiteral("Numbers"),         QStringLiteral("Num"),    4,  QStringLiteral("OT")},
        {QStringLiteral("Deuteronomy"),     QStringLiteral("Deut"),   5,  QStringLiteral("OT")},
        {QStringLiteral("Joshua"),          QStringLiteral("Josh"),   6,  QStringLiteral("OT")},
        {QStringLiteral("Judges"),          QStringLiteral("Judg"),   7,  QStringLiteral("OT")},
        {QStringLiteral("Ruth"),            QStringLiteral("Ruth"),   8,  QStringLiteral("OT")},
        {QStringLiteral("1 Samuel"),        QStringLiteral("1Sam"),   9,  QStringLiteral("OT")},
        {QStringLiteral("2 Samuel"),        QStringLiteral("2Sam"),   10, QStringLiteral("OT")},
        {QStringLiteral("1 Kings"),         QStringLiteral("1Kgs"),   11, QStringLiteral("OT")},
        {QStringLiteral("2 Kings"),         QStringLiteral("2Kgs"),   12, QStringLiteral("OT")},
        {QStringLiteral("1 Chronicles"),    QStringLiteral("1Chr"),   13, QStringLiteral("OT")},
        {QStringLiteral("2 Chronicles"),    QStringLiteral("2Chr"),   14, QStringLiteral("OT")},
        {QStringLiteral("Ezra"),            QStringLiteral("Ezra"),   15, QStringLiteral("OT")},
        {QStringLiteral("Nehemiah"),        QStringLiteral("Neh"),    16, QStringLiteral("OT")},
        {QStringLiteral("Esther"),          QStringLiteral("Esth"),   17, QStringLiteral("OT")},
        {QStringLiteral("Job"),             QStringLiteral("Job"),    18, QStringLiteral("OT")},
        {QStringLiteral("Psalms"),          QStringLiteral("Ps"),     19, QStringLiteral("OT")},
        {QStringLiteral("Proverbs"),        QStringLiteral("Prov"),   20, QStringLiteral("OT")},
        {QStringLiteral("Ecclesiastes"),    QStringLiteral("Eccl"),   21, QStringLiteral("OT")},
        {QStringLiteral("Song of Solomon"), QStringLiteral("Song"),   22, QStringLiteral("OT")},
        {QStringLiteral("Isaiah"),          QStringLiteral("Isa"),    23, QStringLiteral("OT")},
        {QStringLiteral("Jeremiah"),        QStringLiteral("Jer"),    24, QStringLiteral("OT")},
        {QStringLiteral("Lamentations"),    QStringLiteral("Lam"),    25, QStringLiteral("OT")},
        {QStringLiteral("Ezekiel"),         QStringLiteral("Ezek"),   26, QStringLiteral("OT")},
        {QStringLiteral("Daniel"),          QStringLiteral("Dan"),    27, QStringLiteral("OT")},
        {QStringLiteral("Hosea"),           QStringLiteral("Hos"),    28, QStringLiteral("OT")},
        {QStringLiteral("Joel"),            QStringLiteral("Joel"),   29, QStringLiteral("OT")},
        {QStringLiteral("Amos"),            QStringLiteral("Amos"),   30, QStringLiteral("OT")},
        {QStringLiteral("Obadiah"),         QStringLiteral("Obad"),   31, QStringLiteral("OT")},
        {QStringLiteral("Jonah"),           QStringLiteral("Jonah"),  32, QStringLiteral("OT")},
        {QStringLiteral("Micah"),           QStringLiteral("Mic"),    33, QStringLiteral("OT")},
        {QStringLiteral("Nahum"),           QStringLiteral("Nah"),    34, QStringLiteral("OT")},
        {QStringLiteral("Habakkuk"),        QStringLiteral("Hab"),    35, QStringLiteral("OT")},
        {QStringLiteral("Zephaniah"),       QStringLiteral("Zeph"),   36, QStringLiteral("OT")},
        {QStringLiteral("Haggai"),          QStringLiteral("Hag"),    37, QStringLiteral("OT")},
        {QStringLiteral("Zechariah"),       QStringLiteral("Zech"),   38, QStringLiteral("OT")},
        {QStringLiteral("Malachi"),         QStringLiteral("Mal"),    39, QStringLiteral("OT")},
        // New Testament (40..66)
        {QStringLiteral("Matthew"),         QStringLiteral("Matt"),   40, QStringLiteral("NT")},
        {QStringLiteral("Mark"),            QStringLiteral("Mark"),   41, QStringLiteral("NT")},
        {QStringLiteral("Luke"),            QStringLiteral("Luke"),   42, QStringLiteral("NT")},
        {QStringLiteral("John"),            QStringLiteral("John"),   43, QStringLiteral("NT")},
        {QStringLiteral("Acts"),            QStringLiteral("Acts"),   44, QStringLiteral("NT")},
        {QStringLiteral("Romans"),          QStringLiteral("Rom"),    45, QStringLiteral("NT")},
        {QStringLiteral("1 Corinthians"),   QStringLiteral("1Cor"),   46, QStringLiteral("NT")},
        {QStringLiteral("2 Corinthians"),   QStringLiteral("2Cor"),   47, QStringLiteral("NT")},
        {QStringLiteral("Galatians"),       QStringLiteral("Gal"),    48, QStringLiteral("NT")},
        {QStringLiteral("Ephesians"),       QStringLiteral("Eph"),    49, QStringLiteral("NT")},
        {QStringLiteral("Philippians"),     QStringLiteral("Phil"),   50, QStringLiteral("NT")},
        {QStringLiteral("Colossians"),      QStringLiteral("Col"),    51, QStringLiteral("NT")},
        {QStringLiteral("1 Thessalonians"), QStringLiteral("1Thess"), 52, QStringLiteral("NT")},
        {QStringLiteral("2 Thessalonians"), QStringLiteral("2Thess"), 53, QStringLiteral("NT")},
        {QStringLiteral("1 Timothy"),       QStringLiteral("1Tim"),   54, QStringLiteral("NT")},
        {QStringLiteral("2 Timothy"),       QStringLiteral("2Tim"),   55, QStringLiteral("NT")},
        {QStringLiteral("Titus"),           QStringLiteral("Titus"),  56, QStringLiteral("NT")},
        {QStringLiteral("Philemon"),        QStringLiteral("Phlm"),   57, QStringLiteral("NT")},
        {QStringLiteral("Hebrews"),         QStringLiteral("Heb"),    58, QStringLiteral("NT")},
        {QStringLiteral("James"),           QStringLiteral("Jas"),    59, QStringLiteral("NT")},
        {QStringLiteral("1 Peter"),         QStringLiteral("1Pet"),   60, QStringLiteral("NT")},
        {QStringLiteral("2 Peter"),         QStringLiteral("2Pet"),   61, QStringLiteral("NT")},
        {QStringLiteral("1 John"),          QStringLiteral("1John"),  62, QStringLiteral("NT")},
        {QStringLiteral("2 John"),          QStringLiteral("2John"),  63, QStringLiteral("NT")},
        {QStringLiteral("3 John"),          QStringLiteral("3John"),  64, QStringLiteral("NT")},
        {QStringLiteral("Jude"),            QStringLiteral("Jude"),   65, QStringLiteral("NT")},
        {QStringLiteral("Revelation"),      QStringLiteral("Rev"),    66, QStringLiteral("NT")},
    };
}

// USFM's order (TOB, JDT, ESG, WIS, ...). 84 is Psalm 151, stored as Psalms
// 151 (kPsalm151), so it has no entry.
QList<BibleBookMeta> buildDeuterocanonList()
{
    const auto ot = QStringLiteral("OT");
    return {
        {QStringLiteral("Tobit"),              QStringLiteral("Tob"),    67, ot},
        {QStringLiteral("Judith"),             QStringLiteral("Jdt"),    68, ot},
        {QStringLiteral("Esther (Greek)"),     QStringLiteral("EsthGr"), 69, ot},
        {QStringLiteral("Wisdom"),             QStringLiteral("Wis"),    70, ot},
        {QStringLiteral("Sirach"),             QStringLiteral("Sir"),    71, ot},
        {QStringLiteral("Baruch"),             QStringLiteral("Bar"),    72, ot},
        {QStringLiteral("Letter of Jeremiah"), QStringLiteral("EpJer"),  73, ot},
        {QStringLiteral("Prayer of Azariah"),  QStringLiteral("PrAzar"), 74, ot},
        {QStringLiteral("Susanna"),            QStringLiteral("Sus"),    75, ot},
        {QStringLiteral("Bel and the Dragon"), QStringLiteral("Bel"),    76, ot},
        {QStringLiteral("1 Maccabees"),        QStringLiteral("1Macc"),  77, ot},
        {QStringLiteral("2 Maccabees"),        QStringLiteral("2Macc"),  78, ot},
        {QStringLiteral("3 Maccabees"),        QStringLiteral("3Macc"),  79, ot},
        {QStringLiteral("4 Maccabees"),        QStringLiteral("4Macc"),  80, ot},
        {QStringLiteral("1 Esdras"),           QStringLiteral("1Esd"),   81, ot},
        {QStringLiteral("2 Esdras"),           QStringLiteral("2Esd"),   82, ot},
        {QStringLiteral("Prayer of Manasseh"), QStringLiteral("PrMan"),  83, ot},
        {QStringLiteral("Daniel (Greek)"),     QStringLiteral("DanGr"),  85, ot},
    };
}

// Normalize a book name for lookup: lowercase, collapse whitespace, expand
// number prefixes ("first" -> "1", "1samuel" -> "1 samuel").
QString normalizeKey(QStringView s)
{
    QString out = s.toString().toLower().simplified();

    if (out.startsWith(QStringLiteral("first ")))
        out = QStringLiteral("1 ") + out.mid(6);
    else if (out.startsWith(QStringLiteral("second ")))
        out = QStringLiteral("2 ") + out.mid(7);
    else if (out.startsWith(QStringLiteral("third ")))
        out = QStringLiteral("3 ") + out.mid(6);
    else if (out.startsWith(QStringLiteral("fourth ")))
        out = QStringLiteral("4 ") + out.mid(7);

    // "1samuel" -> "1 samuel"  (digit immediately followed by letter)
    static const QRegularExpression numPrefix(QStringLiteral("^(\\d)([a-z])"));
    out.replace(numPrefix, QStringLiteral("\\1 \\2"));

    return out;
}

const QHash<QString, BibleBookMeta>& lookupTable()
{
    static const QHash<QString, BibleBookMeta> table = []() {
        QHash<QString, BibleBookMeta> h;
        for (const auto& b : allCanonicalBooks()) {
            h.insert(normalizeKey(b.name),   b);
            h.insert(normalizeKey(b.abbrev), b);
        }

        // Common alternates not derivable from canonical form.
        auto addAlias = [&](QStringView alias, const QString& canonicalName) {
            const auto canon = h.value(normalizeKey(canonicalName));
            if (!canon.name.isEmpty()) h.insert(normalizeKey(alias), canon);
        };
        addAlias(u"psalm",          QStringLiteral("Psalms"));
        addAlias(u"song of songs",  QStringLiteral("Song of Solomon"));
        addAlias(u"song",           QStringLiteral("Song of Solomon"));
        addAlias(u"canticles",      QStringLiteral("Song of Solomon"));
        addAlias(u"revelations",    QStringLiteral("Revelation"));
        addAlias(u"apocalypse",     QStringLiteral("Revelation"));

        // Tie-breakers for short inputs where the fuzzy resolver below
        // would otherwise pick the wrong book on equal-cost matches.
        // Operators typing these almost always mean the NT entry, but the
        // resolver's edit-distance + book-index tie-break would route to
        // the OT one (lower index, equal distance). Force the right
        // answer here so the fast hash path catches them before fuzzy
        // runs. NOT a place to dump every shortform — only ones where
        // fuzzy is provably ambiguous.
        addAlias(u"jn",  QStringLiteral("John"));        // vs Jonah / Job / Joel
        addAlias(u"jud", QStringLiteral("Jude"));        // vs Judges (Judg)
        addAlias(u"hb",  QStringLiteral("Hebrews"));     // vs Habakkuk (Hab)
        addAlias(u"ph",  QStringLiteral("Philippians")); // vs Philemon (Phlm)

        // The deuterocanon, by name and abbreviation only: none of these
        // takes part in the fuzzy matching below.
        for (const auto& b : deuterocanonicalBooks()) {
            h.insert(normalizeKey(b.name),   b);
            h.insert(normalizeKey(b.abbrev), b);
        }
        addAlias(u"tobias",                          QStringLiteral("Tobit"));   // Douay
        addAlias(u"wisdom of solomon",               QStringLiteral("Wisdom"));
        addAlias(u"ecclesiasticus",                  QStringLiteral("Sirach"));
        addAlias(u"ben sira",                        QStringLiteral("Sirach"));
        addAlias(u"epistle of jeremiah",             QStringLiteral("Letter of Jeremiah"));
        addAlias(u"epistle of jeremy",               QStringLiteral("Letter of Jeremiah"));
        addAlias(u"song of the three",               QStringLiteral("Prayer of Azariah"));
        addAlias(u"song of the three holy children", QStringLiteral("Prayer of Azariah"));
        addAlias(u"song of the three young men",     QStringLiteral("Prayer of Azariah"));
        addAlias(u"prayer of manasses",              QStringLiteral("Prayer of Manasseh"));
        addAlias(u"greek esther",                    QStringLiteral("Esther (Greek)"));
        addAlias(u"additions to esther",             QStringLiteral("Esther (Greek)"));
        addAlias(u"rest of esther",                  QStringLiteral("Esther (Greek)"));
        addAlias(u"greek daniel",                    QStringLiteral("Daniel (Greek)"));
        return h;
    }();
    return table;
}

// Bounded Damerau-Levenshtein with adjacent transpositions. Returns
// `maxDist + 1` if the true distance exceeds the bound — callers only
// need a yes/no plus the score, never the exact distance past the cap.
// Early-outs when the cheapest cell in a row already exceeds the cap.
//
// Inputs here are always short — book names and abbrevs cap at ~16
// chars, queries at ~32 — so the O(n·m) table is < 600 cells. No need
// for the rolling-row optimization.
int boundedDamerauLevenshtein(QStringView a, QStringView b, int maxDist)
{
    const int n = a.size();
    const int m = b.size();
    if (std::abs(n - m) > maxDist) return maxDist + 1;

    QList<QList<int>> dp(n + 1, QList<int>(m + 1, 0));
    for (int i = 0; i <= n; ++i) dp[i][0] = i;
    for (int j = 0; j <= m; ++j) dp[0][j] = j;

    for (int i = 1; i <= n; ++i) {
        int rowMin = INT_MAX;
        for (int j = 1; j <= m; ++j) {
            const int cost = (a[i - 1] == b[j - 1]) ? 0 : 1;
            int best = std::min({dp[i - 1][j] + 1,           // delete
                                 dp[i][j - 1] + 1,           // insert
                                 dp[i - 1][j - 1] + cost});  // substitute
            if (i > 1 && j > 1
                && a[i - 1] == b[j - 2]
                && a[i - 2] == b[j - 1]) {
                best = std::min(best, dp[i - 2][j - 2] + 1);  // transpose
            }
            dp[i][j] = best;
            rowMin = std::min(rowMin, best);
        }
        if (rowMin > maxDist) return maxDist + 1;
    }
    return dp[n][m];
}

// Does `query` appear in `candidate` as a (non-contiguous) subsequence?
// "gn" is a subseq of "genesis" (g…n), "mt" of "matt" (m…t). This is the
// load-bearing scoring axis for two-letter shortforms: edit distance
// alone treats "mt" → "matt" (dist 2), "mt" → "mic" (dist 2), and
// "mt" → "mal" (dist 2) as equal, but subsequence membership uniquely
// picks "matt" because operators type shortforms by dropping vowels.
bool isSubsequence(QStringView query, QStringView candidate)
{
    int qi = 0;
    for (int ci = 0; ci < candidate.size() && qi < query.size(); ++ci) {
        if (query[qi] == candidate[ci]) ++qi;
    }
    return qi == query.size();
}

// Fuzzy fallback used only when the exact-match hash misses. Scores every
// canonical book by its best (name, abbrev) candidate against `key`, then
// returns the global best — preferring prefix > subsequence > low edit
// distance > NT-over-OT on true ties (operators reach for NT references
// more often during a service). Returns nullopt if nothing clears the
// gate: not a prefix, not a subsequence, AND edit distance > kMaxDist.
//
// Cost: 66 books × up to 2 candidate strings × one bounded DL = ~120
// short-string passes per call. Sub-millisecond on any machine inside
// the architecture §6 perf budget.
std::optional<BibleBookMeta> fuzzyResolveBook(const QString& key)
{
    if (key.isEmpty()) return std::nullopt;

    constexpr int kMaxDist = 3;

    struct Scored {
        bool isPrefix = false;
        bool isSubseq = false;
        int  dist     = INT_MAX;
        int  bookIdx  = 0;
        BibleBookMeta meta {};
        // Higher tuple = better candidate.
        auto rank() const {
            // NT bias: prefer higher book index on otherwise-equal scores
            // (chapter 4 vs 19, Matt 5:3 vs whatever OT match also ties).
            return std::tuple(isPrefix ? 1 : 0, isSubseq ? 1 : 0, -dist, bookIdx);
        }
    };

    std::optional<Scored> best;

    auto consider = [&](QStringView candidate, const BibleBookMeta& meta) {
        const bool prefix = candidate.startsWith(key);
        const bool subseq = isSubsequence(key, candidate);
        const int  dist   = boundedDamerauLevenshtein(key, candidate, kMaxDist);
        // Gate: must clear at least one quality threshold. Without this
        // any 1-char query would match every book at distance ≤ longest
        // book name and the only signal left would be tie-break.
        if (!prefix && !subseq && dist > kMaxDist) return;

        Scored s{prefix, subseq, dist, meta.bookNumber, meta};
        if (!best.has_value() || s.rank() > best->rank()) best = s;
    };

    for (const auto& b : allCanonicalBooks()) {
        const QString nameKey   = normalizeKey(b.name);
        const QString abbrevKey = normalizeKey(b.abbrev);
        consider(nameKey, b);
        if (abbrevKey != nameKey) consider(abbrevKey, b);
    }

    if (!best) return std::nullopt;
    return best->meta;
}

}  // namespace

const QList<BibleBookMeta>& allCanonicalBooks()
{
    static const QList<BibleBookMeta> list = buildCanonicalList();
    return list;
}

const QList<BibleBookMeta>& deuterocanonicalBooks()
{
    static const QList<BibleBookMeta> list = buildDeuterocanonList();
    return list;
}

const BibleBookMeta* bookByNumber(int bookNumber)
{
    if (bookNumber >= 1 && bookNumber <= 66) return &allCanonicalBooks().at(bookNumber - 1);
    for (const auto& b : deuterocanonicalBooks())
        if (b.bookNumber == bookNumber) return &b;
    return nullptr;
}

int bookListPosition(int bookNumber)
{
    static const QHash<int, int> positions = [] {
        // Each book of the deuterocanon follows the one named here.
        static const int after[][2] = {
            { 14, 83 },   // 2 Chronicles: the Prayer of Manasseh, his prayer in 2 Chr 33
            { 16, 81 }, { 81, 82 },             // Nehemiah: 1 and 2 Esdras
            { 82, 67 }, { 67, 68 },             // Tobit, Judith
            { 17, 69 },                         // Esther: the Greek Esther
            { 69, 77 }, { 77, 78 }, { 78, 79 }, { 79, 80 },   // the Maccabees
            { 22, 70 }, { 70, 71 },             // Song of Songs: Wisdom, Sirach
            { 25, 72 }, { 72, 73 },             // Lamentations: Baruch, Letter of Jeremiah
            { 27, 85 }, { 85, 74 }, { 74, 75 }, { 75, 76 },   // Daniel and its additions
        };
        QHash<int, int> follows;
        for (const auto& pair : after) follows.insert(pair[0], pair[1]);
        QHash<int, int> out;
        int position = 0;
        for (const auto& b : allCanonicalBooks()) {
            for (int n = b.bookNumber; n; n = follows.value(n)) out.insert(n, position++);
        }
        return out;
    }();
    return positions.value(bookNumber, 1000 + bookNumber);
}

namespace {

// A book name from a file, ready to compare: lowercase, diacritics off
// ("Deuteronómium" -> "deuteronomium"), hyphens and dots gone (Vietnamese
// "Phi-lê-môn", "1. Samuelova"), Roman numbers as digits ("II Kings").
QString plainName(QStringView name)
{
    QString plain;
    for (const QChar c : normalizeKey(name).normalized(QString::NormalizationForm_D)) {
        if (c.category() == QChar::Mark_NonSpacing || c == u'-' || c == u'.') continue;
        plain += c;
    }
    static const QRegularExpression roman(QStringLiteral(R"(^(i{1,3})\s+)"));
    if (const auto m = roman.match(plain); m.hasMatch())
        plain = QString::number(m.capturedLength(1)) + u' ' + plain.mid(m.capturedEnd());
    return normalizeKey(plain);
}

// Every letter is Latin, and there are at least `minimum` of them.
bool latinLetters(const QString& plain, int minimum, int* count = nullptr)
{
    int letters = 0;
    for (const QChar c : plain) {
        if (!c.isLetter()) continue;
        if (c.script() != QChar::Script_Latin) return false;
        ++letters;
    }
    if (count) *count = letters;
    return letters >= minimum;
}

// What a plain name says about the deuterocanon: its book number, by the
// stems its names share across languages, kUnheld for a book Crater holds
// under no number, kAmbiguous for a name that could be more than one book,
// or 0 for neither. The stems also keep these names from matching one of the
// 66 they look like (Ecclesiasticus or Eclesiástico / Ecclesiastes, Tobit /
// Obadiah, Psalms of Solomon / Song of Solomon). "Esdras" alone is Ezra in
// French, Spanish and Portuguese. A numbered Esdras is Ezra or Nehemiah in a
// Catholic Bible and 1 or 2 Esdras in the KJV's Apocrypha, so where the book
// sits has to decide.
constexpr int kUnheld = -1;
constexpr int kAmbiguous = -2;

bool isEsdras(int bookNumber)
{
    return bookNumber == 81 || bookNumber == 82;
}

// The number a book's name gives it: before the name ("1 Maccabees", "IV
// Maccabees", "4. Makabejcov" once plain) or after it ("Machabaeorum I",
// "Makkabeusok II"). 0 for none.
int nameOrdinal(const QString& plain)
{
    static const QRegularExpression before(QStringLiteral(R"(^([1-4]|iv)\s)"));
    static const QRegularExpression after(QStringLiteral(R"(\s([1-4]|i{1,3}|iv)(\s|$))"));
    const auto toNumber = [](const QString& n) {
        if (n == u"iv") return 4;
        if (n.startsWith(u'i')) return int(n.size());
        return n.toInt();
    };
    if (const auto m = before.match(plain); m.hasMatch()) return toNumber(m.captured(1));
    if (const auto m = after.match(plain); m.hasMatch()) return toNumber(m.captured(1));
    return 0;
}

int deuterocanonFromPlain(const QString& plain)
{
    const int number = nameOrdinal(plain);

    static const char* const unheld[] = {
        "laodic", "odes", "psalms of solomon", "enoch", "henoch", "jubile",
    };
    for (const char* stem : unheld)
        if (plain.contains(QLatin1String(stem))) return kUnheld;
    if (plain.contains(QLatin1String("esdras"))) return number ? kAmbiguous : 0;
    // A numbered Baruch (2 Baruch, the Syriac apocalypse) isn't Baruch.
    for (const char* stem : { "baruc", "baruk", "baruh" })
        if (plain.contains(QLatin1String(stem))) return number ? kUnheld : 72;
    for (const char* stem : { "macc", "makab", "makk", "macab", "machab" })
        if (plain.contains(QLatin1String(stem))) return number ? 76 + number : kAmbiguous;

    // Sirach before Wisdom: "The Wisdom of Jesus the Son of Sirach".
    struct Stem { const char* stem; int book; };
    static const Stem held[] = {
        { "sirach", 71 }, { "sirac", 71 }, { "sirak", 71 }, { "syracyd", 71 },
        { "clesiastic", 71 }, { "clesiastiq", 71 }, { "ben sira", 71 },
        { "tob", 67 }, { "judit", 68 }, { "giudit", 68 }, { "iudit", 68 }, { "judyt", 68 },
        { "wisdom", 70 }, { "sabidur", 70 }, { "sagesse", 70 }, { "weisheit", 70 },
        { "sapienz", 70 }, { "sapient", 70 }, { "wijsheid", 70 }, { "sabedoria", 70 },
        { "mudrost", 70 }, { "moudrost", 70 }, { "madrosc", 70 }, { "bolcsesseg", 70 },
        { "jeremy", 73 }, { "azaria", 74 }, { "three holy", 74 }, { "three young", 74 },
        { "susan", 75 }, { "zuzan", 75 },
        { "bel and", 76 }, { "bel et", 76 }, { "bel y", 76 }, { "bel und", 76 }, { "bel dan", 76 },
        { "manasse", 83 }, { "manases", 83 }, { "manase", 83 },
    };
    for (const Stem& s : held)
        if (plain.contains(QLatin1String(s.stem))) return s.book;
    return 0;
}

}  // namespace

bool isUnheldBookName(QStringView name)
{
    return deuterocanonFromPlain(plainName(name)) == kUnheld;
}

int apocryphalEsdras(QStringView name)
{
    const QString plain = plainName(name);
    if (!plain.contains(QLatin1String("esdras"))) return 0;
    switch (nameOrdinal(plain)) {
    case 1: case 3: return 81;   // the Vulgate's 3 Esdras is 1 Esdras
    case 2: case 4: return 82;
    default: return 0;
    }
}

std::optional<BibleBookMeta> lookupBookName(QStringView name)
{
    const auto& tbl = lookupTable();
    if (const auto it = tbl.find(normalizeKey(name)); it != tbl.end()) {
        if (isEsdras(it->bookNumber)) return std::nullopt;
        return it.value();
    }
    const QString plain = plainName(name);
    if (const int book = deuterocanonFromPlain(plain); book != 0) {
        if (book < 0) return std::nullopt;
        return *bookByNumber(book);
    }
    // Short names with an accent ("Jób", "Rút") match once it's off.
    if (const auto it = tbl.find(plain); it != tbl.end()) {
        if (isEsdras(it->bookNumber)) return std::nullopt;
        return it.value();
    }
    // Ezra in French, Spanish and Portuguese, too far from "Ezra" to match.
    if (plain == u"esdras") return tbl.value(QStringLiteral("ezra"));

    // Otherwise only Latin names of four letters or more, and only the
    // closest full name within a third of the length. A tie means it could
    // be either, so neither.
    int letters = 0;
    if (!latinLetters(plain, 4, &letters)) return std::nullopt;
    const int bound = qMax(1, letters / 3);
    std::optional<BibleBookMeta> best;
    int bestDist = bound + 1;
    bool tied = false;
    for (const auto& b : allCanonicalBooks()) {
        const int dist = boundedDamerauLevenshtein(plain, normalizeKey(b.name), bound);
        if (dist < bestDist) {
            best = b;
            bestDist = dist;
            tied = false;
        } else if (dist == bestDist && dist <= bound) {
            tied = true;
        }
    }
    return tied ? std::nullopt : best;
}

std::optional<BibleBookMeta> guessBookName(QStringView name)
{
    const QString plain = plainName(name);
    bool isNumber = false;
    plain.toInt(&isNumber);
    if (isNumber || !latinLetters(plain, 2)) return std::nullopt;
    if (const int book = deuterocanonFromPlain(plain); book != 0) {
        if (book < 0) return std::nullopt;
        return *bookByNumber(book);
    }
    auto guess = lookupBook(name);
    if (guess && isEsdras(guess->bookNumber)) return std::nullopt;
    return guess;
}

std::optional<BibleBookMeta> lookupBook(QStringView nameOrAlt)
{
    const QString key = normalizeKey(nameOrAlt);
    const auto& tbl = lookupTable();
    const auto it = tbl.find(key);
    if (it != tbl.end()) return it.value();
    // The start of a deuterocanonical name ("tobi", "1 macca"), unless one
    // of the 66 starts that way too: then the shortform keeps its meaning.
    if (key.size() >= 3) {
        const auto starts = [&key](const BibleBookMeta& b) {
            return normalizeKey(b.name).startsWith(key) || normalizeKey(b.abbrev).startsWith(key);
        };
        const auto& canon = allCanonicalBooks();
        if (std::none_of(canon.cbegin(), canon.cend(), starts)) {
            const BibleBookMeta* found = nullptr;
            int count = 0;
            for (const auto& b : deuterocanonicalBooks())
                if (starts(b)) { found = &b; ++count; }
            if (count == 1) return *found;
        }
    }
    // Hash miss → fuzzy. Catches shortforms (gn → Genesis, mt → Matthew),
    // typos (phillipians → Philippians), and missing-vowel inputs (jdgs →
    // Judges) without hand-maintaining an alias table for every variant.
    return fuzzyResolveBook(key);
}

}  // namespace crater::import
