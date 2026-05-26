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

std::optional<BibleBookMeta> lookupBook(QStringView nameOrAlt)
{
    const QString key = normalizeKey(nameOrAlt);
    const auto& tbl = lookupTable();
    const auto it = tbl.find(key);
    if (it != tbl.end()) return it.value();
    // Hash miss → fuzzy. Catches shortforms (gn → Genesis, mt → Matthew),
    // typos (phillipians → Philippians), and missing-vowel inputs (jdgs →
    // Judges) without hand-maintaining an alias table for every variant.
    return fuzzyResolveBook(key);
}

}  // namespace crater::import
