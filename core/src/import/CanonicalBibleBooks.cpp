#include "import/CanonicalBibleBooks.h"

#include <QHash>
#include <QRegularExpression>

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
        return h;
    }();
    return table;
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
    if (it == tbl.end()) return std::nullopt;
    return it.value();
}

}  // namespace crater::import
