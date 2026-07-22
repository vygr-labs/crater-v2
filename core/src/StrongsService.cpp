#include "crater/StrongsService.h"

#include "db/Connection.h"
#include "db/Error.h"
#include "db/Statement.h"
#include "import/CanonicalBibleBooks.h"

#include <QCoreApplication>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QHash>
#include <QRegularExpression>
#include <QStringList>

namespace crater {

namespace {

// Walks up from the EXE looking for a shipped read-only Strong's DB. Production
// layout expects it under <exe>/legacy/ alongside bibles.sqlite (see
// ElectronDataImporter); dev falls back to the electron repo's seed copy.
// Returns empty when nothing is found — the service then reports the DB
// unavailable instead of crashing.
QString findStrongsDbPath(const QString& fileName)
{
    QDir d(QCoreApplication::applicationDirPath());
    for (int hop = 0; hop < 8; ++hop) {
        const QString prod = d.absoluteFilePath(QStringLiteral("legacy/") + fileName);
        if (QFile::exists(prod)) return prod;

        const QString dev = d.absoluteFilePath(
            QStringLiteral("electron/src/assets/default/databases/") + fileName);
        if (QFile::exists(dev)) return dev;

        if (!d.cdUp()) break;
    }
    return {};
}

// LIKE pattern that scopes a query to one language via the word prefix.
// "H%" / "G%" narrow to Hebrew / Greek; "%" matches everything.
QString languagePattern(const QString& language)
{
    if (language == QStringLiteral("hebrew")) return QStringLiteral("H%");
    if (language == QStringLiteral("greek"))  return QStringLiteral("G%");
    return QStringLiteral("%");
}

QString languageFor(const QString& word)
{
    if (word.startsWith(QLatin1Char('H'), Qt::CaseInsensitive)) return QStringLiteral("hebrew");
    if (word.startsWith(QLatin1Char('G'), Qt::CaseInsensitive)) return QStringLiteral("greek");
    return {};
}

// Minimal HTML-entity decode for the handful the Strong's data uses. crater-core
// can't link Qt6::Gui, so QTextDocument is off-limits — we strip by hand.
QString decodeEntities(QString s)
{
    s.replace(QStringLiteral("&nbsp;"), QStringLiteral(" "));
    s.replace(QStringLiteral("&amp;"),  QStringLiteral("&"));
    s.replace(QStringLiteral("&lt;"),   QStringLiteral("<"));
    s.replace(QStringLiteral("&gt;"),   QStringLiteral(">"));
    s.replace(QStringLiteral("&quot;"), QStringLiteral("\""));
    s.replace(QStringLiteral("&#39;"),  QStringLiteral("'"));
    s.replace(QStringLiteral("&apos;"), QStringLiteral("'"));
    // Numeric decimal entities (e.g. &#8220;). Best-effort BMP decode.
    static const QRegularExpression num(QStringLiteral("&#(\\d+);"));
    QRegularExpressionMatchIterator it = num.globalMatch(s);
    QString out;
    int last = 0;
    while (it.hasNext()) {
        const auto m = it.next();
        out += s.mid(last, m.capturedStart() - last);
        const uint code = m.captured(1).toUInt();
        if (code > 0 && code <= 0xFFFF) out += QChar(static_cast<char16_t>(code));
        last = m.capturedEnd();
    }
    out += s.mid(last);
    return out;
}

// Flatten a Strong's HTML `data` blob into trimmed, non-empty text lines.
// Block-level closers become line breaks; every other tag is dropped.
QStringList htmlToLines(const QString& html)
{
    QString s = html;
    // Block boundaries → newlines so fields/list-items don't run together.
    static const QRegularExpression blockClose(
        QStringLiteral("</p>|</li>|</ol>|</ul>|<br\\s*/?>"),
        QRegularExpression::CaseInsensitiveOption);
    s.replace(blockClose, QStringLiteral("\n"));
    // Drop every remaining tag.
    static const QRegularExpression anyTag(QStringLiteral("<[^>]*>"));
    s.replace(anyTag, QString());
    s = decodeEntities(s);

    QStringList out;
    const auto rawLines = s.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    for (const QString& raw : rawLines) {
        const QString t = raw.simplified();
        if (!t.isEmpty()) out.append(t);
    }
    return out;
}

// Read the value after a "Label:" prefix, case-insensitively. Empty if absent.
QString fieldAfter(const QStringList& lines, const QString& label)
{
    for (const QString& line : lines) {
        if (line.startsWith(label, Qt::CaseInsensitive))
            return line.mid(label.size()).simplified();
    }
    return {};
}

// Split one over-long line into ≤budget pieces at word boundaries.
QStringList splitLong(const QString& line, int budget)
{
    QStringList parts;
    QString rest = line;
    while (rest.size() > budget) {
        int cut = rest.lastIndexOf(QLatin1Char(' '), budget);
        if (cut <= 0) cut = budget;  // no space — hard break
        parts.append(rest.left(cut).trimmed());
        rest = rest.mid(cut).trimmed();
    }
    if (!rest.isEmpty()) parts.append(rest);
    return parts;
}

// Greedily pack lines into slide-sized pages.
QStringList packLines(const QStringList& lines, int budget)
{
    QStringList pages;
    QString cur;
    auto flush = [&]() {
        const QString t = cur.trimmed();
        if (!t.isEmpty()) pages.append(t);
        cur.clear();
    };
    for (const QString& raw : lines) {
        for (const QString& p : splitLong(raw, budget)) {
            if (cur.isEmpty())
                cur = p;
            else if (cur.size() + 1 + p.size() <= budget)
                cur += QLatin1Char('\n') + p;
            else {
                flush();
                cur = p;
            }
        }
    }
    flush();
    return pages;
}

constexpr int kSlideBudget = 260;

}  // namespace

// Impl owns two independent read-only connections. Either may be absent (data
// file missing); the other still works. Statements are default-constructed and
// prepared only once their connection opens.
struct StrongsService::Impl
{
    std::unique_ptr<db::Connection> dictConn;
    db::Statement dictLookup;
    db::Statement dictSearch;   // (data LIKE ?1 OR word LIKE ?1) AND word LIKE ?2
    db::Statement dictBrowse;   // word LIKE ?1 ORDER BY relativeOrder LIMIT ?2 OFFSET ?3

    std::unique_ptr<db::Connection> bibleConn;
    db::Statement bibleChapter;
    db::Statement bibleVerse;

    QHash<int, QString> bookNames;  // 1..66 → canonical name

    Impl()
    {
        for (const auto& b : crater::import::allCanonicalBooks())
            bookNames.insert(b.bookNumber, b.name);

        openDictionary();
        openBible();
    }

    void openDictionary()
    {
        const QString path = findStrongsDbPath(QStringLiteral("strongs-dictionary.sqlite"));
        if (path.isEmpty()) {
            qWarning() << "StrongsService: strongs-dictionary.sqlite not found — "
                          "concordance lexicon unavailable.";
            return;
        }
        try {
            dictConn = std::make_unique<db::Connection>(
                path, db::OpenMode::ReadOnly, QStringLiteral("StrongsDict"));
            dictLookup = dictConn->prepare(QStringLiteral(
                "SELECT relativeOrder, word, data FROM dictionary "
                "WHERE word = ?1 LIMIT 1"));
            dictSearch = dictConn->prepare(QStringLiteral(
                "SELECT relativeOrder, word, data FROM dictionary "
                "WHERE (data LIKE ?1 OR word LIKE ?1) AND word LIKE ?2 "
                "ORDER BY relativeOrder LIMIT 100"));
            dictBrowse = dictConn->prepare(QStringLiteral(
                "SELECT relativeOrder, word, data FROM dictionary "
                "WHERE word LIKE ?1 ORDER BY relativeOrder LIMIT ?2 OFFSET ?3"));
        } catch (const db::Error& e) {
            qWarning().noquote() << "StrongsService: dictionary open failed —" << e.message();
            dictConn.reset();
        }
    }

    void openBible()
    {
        const QString path = findStrongsDbPath(QStringLiteral("strongs-bible.sqlite"));
        if (path.isEmpty()) {
            qWarning() << "StrongsService: strongs-bible.sqlite not found — "
                          "interlinear reader unavailable.";
            return;
        }
        try {
            bibleConn = std::make_unique<db::Connection>(
                path, db::OpenMode::ReadOnly, QStringLiteral("StrongsBible"));
            bibleChapter = bibleConn->prepare(QStringLiteral(
                "SELECT verse, text FROM Bible "
                "WHERE book = ?1 AND chapter = ?2 ORDER BY verse"));
            bibleVerse = bibleConn->prepare(QStringLiteral(
                "SELECT text FROM Bible "
                "WHERE book = ?1 AND chapter = ?2 AND verse = ?3 LIMIT 1"));
        } catch (const db::Error& e) {
            qWarning().noquote() << "StrongsService: bible open failed —" << e.message();
            bibleConn.reset();
        }
    }

    // Build a fully-parsed entry from a dictionary row's three columns.
    StrongsEntry entryFromRow(db::Statement& stmt) const
    {
        StrongsEntry e;
        e.relativeOrder = stmt.columnInt(0);
        e.word          = stmt.columnText(1);
        e.html          = stmt.columnText(2);
        e.language      = languageFor(e.word);

        const QStringList lines = htmlToLines(e.html);
        e.lemma           = fieldAfter(lines, QStringLiteral("Original:"));
        e.transliteration = fieldAfter(lines, QStringLiteral("Transliteration:"));
        e.pronunciation   = fieldAfter(lines, QStringLiteral("Phonetic:"));
        e.partOfSpeech    = fieldAfter(lines, QStringLiteral("Part(s) of speech:"));
        if (e.partOfSpeech.isEmpty())
            e.partOfSpeech = fieldAfter(lines, QStringLiteral("Part of speech:"));

        // Prefer the concise "Strong's Definition"; fall back to the lexicon
        // definition, then to the first substantive line.
        e.definition = fieldAfter(lines, QStringLiteral("Strong's Definition:"));
        if (e.definition.isEmpty())
            e.definition = fieldAfter(lines, QStringLiteral("BDB Definition:"));
        if (e.definition.isEmpty())
            e.definition = fieldAfter(lines, QStringLiteral("Thayer Definition:"));
        if (e.definition.isEmpty()) {
            for (const QString& line : lines) {
                if (line.contains(QLatin1Char(':'))) continue;  // skip label rows
                e.definition = line;
                break;
            }
        }
        return e;
    }
};

StrongsService::StrongsService(QObject* parent)
    : QObject(parent)
{
    try {
        m_impl = std::make_unique<Impl>();
    } catch (const db::Error& e) {
        qCritical().noquote() << "StrongsService: init failed —" << e.message();
    }
}

StrongsService::~StrongsService() = default;

bool StrongsService::available() const
{
    return m_impl && m_impl->dictConn && m_impl->bibleConn;
}

bool StrongsService::hasDictionary() const
{
    return m_impl && m_impl->dictConn != nullptr;
}

bool StrongsService::hasBible() const
{
    return m_impl && m_impl->bibleConn != nullptr;
}

StrongsEntry StrongsService::lookup(QString word)
{
    StrongsEntry e;
    if (!m_impl || !m_impl->dictConn) return e;
    const QString w = word.trimmed().toUpper();
    if (w.isEmpty()) return e;
    try {
        auto& stmt = m_impl->dictLookup;
        stmt.reset();
        stmt.bind(1, w);
        if (stmt.step()) e = m_impl->entryFromRow(stmt);
        stmt.reset();   // release the read cursor
    } catch (const db::Error& err) {
        qWarning().noquote() << "StrongsService::lookup():" << err.message();
    }
    return e;
}

QList<StrongsEntry> StrongsService::search(QString query, QString language)
{
    const QString q = query.trimmed();
    // Empty query → the ordered browse view (matches Electron's getAllStrongs).
    if (q.isEmpty()) return browse(100, 0, language);

    // A bare Strong's number resolves to an exact lookup.
    static const QRegularExpression numRx(QStringLiteral("^[HGhg]\\d+$"));
    if (numRx.match(q).hasMatch()) {
        QList<StrongsEntry> out;
        const StrongsEntry e = lookup(q);
        if (e.valid()) out.append(e);
        return out;
    }

    QList<StrongsEntry> out;
    if (!m_impl || !m_impl->dictConn) return out;
    try {
        auto& stmt = m_impl->dictSearch;
        stmt.reset();
        stmt.bind(1, QStringLiteral("%") + q + QStringLiteral("%"));  // %kw%
        stmt.bind(2, languagePattern(language));
        while (stmt.step()) out.append(m_impl->entryFromRow(stmt));
    } catch (const db::Error& e) {
        qWarning().noquote() << "StrongsService::search():" << e.message();
    }
    return out;
}

QList<StrongsEntry> StrongsService::browse(int limit, int offset, QString language)
{
    QList<StrongsEntry> out;
    if (!m_impl || !m_impl->dictConn) return out;
    try {
        auto& stmt = m_impl->dictBrowse;
        stmt.reset();
        stmt.bind(1, languagePattern(language));
        stmt.bind(2, qint64(limit  > 0 ? limit  : 100));
        stmt.bind(3, qint64(offset > 0 ? offset : 0));
        while (stmt.step()) out.append(m_impl->entryFromRow(stmt));
    } catch (const db::Error& e) {
        qWarning().noquote() << "StrongsService::browse():" << e.message();
    }
    return out;
}

QList<StrongsSection> StrongsService::sections(QString word)
{
    QList<StrongsSection> out;
    const StrongsEntry e = lookup(word);
    if (!e.valid()) return out;

    const QStringList lines = htmlToLines(e.html);
    const QStringList pages  = packLines(lines, kSlideBudget);
    const int n = pages.size();
    for (int i = 0; i < n; ++i) {
        StrongsSection s;
        s.label = n > 1
                    ? QStringLiteral("%1 · %2/%3").arg(e.word).arg(i + 1).arg(n)
                    : e.word;
        s.content = pages.at(i);
        out.append(std::move(s));
    }
    return out;
}

QVariantMap StrongsService::resolveReference(QString input)
{
    QVariantMap out;
    out.insert(QStringLiteral("valid"), false);

    const QString trimmed = input.trimmed();
    if (trimmed.isEmpty()) return out;

    // Same grammar as BibleService::parseReference: book token, optional
    // chapter, optional verse. Chapter/verse default to 1 when omitted.
    static const QRegularExpression rx(QStringLiteral(
        R"(^\s*([1-3]\s*[a-zA-Z]+(?:\s+[a-zA-Z]+)*|[a-zA-Z]+(?:\s+[a-zA-Z]+)*)(?:\s*(\d+)(?:\s*[:\s]\s*(\d+))?)?\s*$)"));
    const auto m = rx.match(trimmed);
    if (!m.hasMatch()) return out;

    const auto meta = crater::import::lookupBook(m.captured(1));
    if (!meta.has_value()) return out;

    const QString chapCap  = m.captured(2);
    const QString verseCap = m.captured(3);
    out.insert(QStringLiteral("valid"),    true);
    out.insert(QStringLiteral("book"),     meta->bookNumber);
    out.insert(QStringLiteral("bookName"), meta->name);
    out.insert(QStringLiteral("chapter"),  chapCap.isEmpty()  ? 1 : chapCap.toInt());
    out.insert(QStringLiteral("verse"),    verseCap.isEmpty() ? 1 : verseCap.toInt());
    return out;
}

QList<StrongsBibleVerse> StrongsService::chapter(int book, int chapterNumber)
{
    QList<StrongsBibleVerse> out;
    if (!m_impl || !m_impl->bibleConn) return out;
    const QString bookName = m_impl->bookNames.value(book);
    try {
        auto& stmt = m_impl->bibleChapter;
        stmt.reset();
        stmt.bind(1, qint64(book));
        stmt.bind(2, qint64(chapterNumber));
        while (stmt.step()) {
            StrongsBibleVerse v;
            v.book     = book;
            v.bookName = bookName;
            v.chapter  = chapterNumber;
            v.verse    = stmt.columnInt(0);
            v.text     = stmt.columnText(1);
            out.append(std::move(v));
        }
    } catch (const db::Error& e) {
        qWarning().noquote() << "StrongsService::chapter():" << e.message();
    }
    return out;
}

StrongsBibleVerse StrongsService::verse(int book, int chapterNumber, int verseNumber)
{
    StrongsBibleVerse v;
    if (!m_impl || !m_impl->bibleConn) return v;
    try {
        auto& stmt = m_impl->bibleVerse;
        stmt.reset();
        stmt.bind(1, qint64(book));
        stmt.bind(2, qint64(chapterNumber));
        stmt.bind(3, qint64(verseNumber));
        if (stmt.step()) {
            v.book     = book;
            v.bookName = m_impl->bookNames.value(book);
            v.chapter  = chapterNumber;
            v.verse    = verseNumber;
            v.text     = stmt.columnText(0);
        }
        stmt.reset();   // release the read cursor
    } catch (const db::Error& e) {
        qWarning().noquote() << "StrongsService::verse():" << e.message();
    }
    return v;
}

QList<StrongsWord> StrongsService::tokenize(QString verseText)
{
    QList<StrongsWord> out;
    QString s = verseText;

    // 1. Drop footnotes and section titles outright (tag + enclosed content).
    static const QRegularExpression footnote(
        QStringLiteral("<RF[^>]*>.*?<Rf>"), QRegularExpression::DotMatchesEverythingOption);
    s.remove(footnote);
    static const QRegularExpression title(
        QStringLiteral("<TS[^>]*>.*?<Ts>"), QRegularExpression::DotMatchesEverythingOption);
    s.remove(title);

    // 2. Remove every tag EXCEPT the Strong's tags (<WH####> / <WG####>),
    //    keeping the enclosed text of formatting tags like <FI>..<Fi>.
    static const QRegularExpression nonStrongsTag(QStringLiteral("<(?!W[HG]\\d)[^>]*>"));
    s.replace(nonStrongsTag, QStringLiteral(" "));

    // 3. Walk word tokens and Strong's tags in order. A tag attaches its number
    //    to the word it immediately follows.
    static const QRegularExpression tokenRx(QStringLiteral("<W([HG])(\\d+)>|([^\\s<]+)"));
    auto it = tokenRx.globalMatch(s);
    int lastWord = -1;
    while (it.hasNext()) {
        const auto m = it.next();
        if (m.capturedStart(1) != -1) {
            // Strong's tag. First tag on a word wins.
            if (lastWord >= 0 && out[lastWord].ref.isEmpty()) {
                const QString letter = m.captured(1);
                out[lastWord].ref        = letter + m.captured(2);
                out[lastWord].language   = (letter == QStringLiteral("H"))
                                             ? QStringLiteral("hebrew")
                                             : QStringLiteral("greek");
                out[lastWord].hasStrongs = true;
            }
        } else {
            StrongsWord w;
            w.text = m.captured(3);
            out.append(w);
            lastWord = out.size() - 1;
        }
    }
    return out;
}

}  // namespace crater
