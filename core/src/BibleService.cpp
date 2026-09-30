#include "crater/BibleService.h"

#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Error.h"
#include "db/FtsQuery.h"
#include "db/Statement.h"
#include "db/Transaction.h"
#include "import/CanonicalBibleBooks.h"

#include <QDebug>
#include <QFutureWatcher>
#include <QHash>
#include <QRegularExpression>
#include <QVariantMap>
#include <QtConcurrent>

namespace crater {

namespace {

constexpr QStringView kBooksSql = u"SELECT b.name, b.abbrev, b.testament, b.book_number, "
    u"       COALESCE(MAX(v.chapter), 0) AS chapter_count "
    u"FROM books b "
    u"JOIN translations t ON t.id = b.translation_id "
    u"LEFT JOIN verses v ON v.book_id = b.id AND v.translation_id = t.id "
    u"WHERE t.code = ? "
    u"GROUP BY b.id "
    u"ORDER BY b.book_number";

constexpr QStringView kAllVersesSql = u"SELECT b.name, v.chapter, v.verse, v.text "
    u"FROM verses v "
    u"JOIN translations t ON t.id = v.translation_id "
    u"JOIN books        b ON b.id = v.book_id "
    u"WHERE t.code = ? "
    u"ORDER BY b.book_number, v.chapter, v.verse";

// Both throw db::Error; callers decide whether a failure is cached.
QList<Book> readBooks(db::Statement& stmt, const QString& code)
{
    QList<Book> out;
    stmt.reset();
    stmt.bind(1, code);
    while (stmt.step()) {
        Book b;
        b.name         = stmt.columnText(0);
        b.abbrev       = stmt.columnText(1);
        b.testament    = stmt.columnText(2);
        b.bookNumber   = stmt.columnInt(3);
        b.chapterCount = stmt.columnInt(4);
        out.append(std::move(b));
    }
    return out;
}

QList<Verse> readAllVerses(db::Statement& stmt, const QString& code)
{
    QList<Verse> out;
    stmt.reset();
    stmt.bind(1, code);
    // KJV is ~31,103 verses; reserving avoids ~20 reallocs.
    out.reserve(32000);
    QString book;
    while (stmt.step()) {
        Verse v;
        v.translationCode = code;
        // Rows arrive grouped by book, so every verse of a book can share
        // one name string instead of holding its own copy.
        const QString name = stmt.columnText(0);
        if (name != book) book = name;
        v.book    = book;
        v.chapter = stmt.columnInt(1);
        v.verse   = stmt.columnInt(2);
        v.text    = stmt.columnText(3);
        out.append(std::move(v));
    }
    return out;
}

// Every translation's verses and books, read on a worker thread when
// preloading is switched on.
struct Prefetch
{
    QHash<QString, QList<Verse>> verses;
    QHash<QString, QList<Book>>  books;
};

Prefetch prefetchAll()
{
    Prefetch p;
    try {
        // Own connection: connections never cross threads.
        db::Connection conn(db::DbPaths::biblesDbPath(), db::OpenMode::ReadOnly,
                            u"BibleService prefetch");
        db::Statement codes  = conn.prepare(u"SELECT code FROM translations ORDER BY sort_order, code");
        db::Statement books  = conn.prepare(kBooksSql);
        db::Statement verses = conn.prepare(kAllVersesSql);
        while (codes.step()) {
            const QString code = codes.columnText(0);
            p.books.insert(code, readBooks(books, code));
            p.verses.insert(code, readAllVerses(verses, code));
        }
    } catch (const db::Error& e) {
        qWarning().noquote() << "BibleService prefetch:" << e.message();
    }
    return p;
}

// Row lookup for one translation. Book names map to small ids so the verse
// key is an integer, which keeps building it to a few ms for a whole Bible.
struct VerseRows
{
    QHash<QString, quint32> bookIds;   // lowercased name
    QHash<quint64, int>     rows;

    static quint64 key(quint32 book, int chapter, int verse)
    {
        return (quint64(book) << 40) | (quint64(quint32(chapter)) << 20) | quint32(verse);
    }
};

}  // namespace

// Impl owns the connection + cached prepared statements. PIMPL keeps sqlite3
// types out of the public header.
struct BibleService::Impl
{
    db::Connection conn;

    // Cached prepared statements. SQLite re-parses prepared SQL each call to
    // sqlite3_prepare; caching here amortizes that cost across every query.
    db::Statement selectTranslations;
    db::Statement selectBooks;
    db::Statement selectVerse;
    db::Statement selectChapter;
    db::Statement selectAllVerses;
    db::Statement searchAll;
    db::Statement searchScoped;

    // Per-translation caches (see allVerses in the header). Books are a few
    // KB per translation and always kept. Verses and their row index are
    // the heavy part, bounded by `recent` unless preloadAll is on.
    QHash<QString, QList<Verse>> verses;
    QHash<QString, VerseRows>    verseRows;
    QHash<QString, QList<Book>>  books;
    QStringList                  recent;   // most recently used first
    bool                         preloadAll = false;
    QFutureWatcher<Prefetch>     prefetch;

    // Operators flip between two or three translations in a service, so
    // that many stay warm without preloading everything.
    static constexpr int kKeepRecent = 3;

    void touch(const QString& code)
    {
        recent.removeOne(code);
        recent.prepend(code);
        if (preloadAll) return;
        while (recent.size() > kKeepRecent) {
            const QString old = recent.takeLast();
            verses.remove(old);
            verseRows.remove(old);
        }
    }

    explicit Impl(const QString& path)
        : conn(path, db::OpenMode::ReadWriteCreate, QStringLiteral("BibleService"))
        , selectTranslations(conn.prepare(QStringLiteral(
            "SELECT code, name, year, description "
            "FROM translations "
            "ORDER BY sort_order, code")))
        , selectBooks(conn.prepare(kBooksSql))
        , selectVerse(conn.prepare(QStringLiteral(
            "SELECT v.text "
            "FROM verses v "
            "JOIN translations t ON t.id = v.translation_id "
            "JOIN books        b ON b.id = v.book_id "
            "WHERE t.code = ? AND b.name = ? AND v.chapter = ? AND v.verse = ? "
            "LIMIT 1")))
        , selectChapter(conn.prepare(QStringLiteral(
            "SELECT v.verse, v.text "
            "FROM verses v "
            "JOIN translations t ON t.id = v.translation_id "
            "JOIN books        b ON b.id = v.book_id "
            "WHERE t.code = ? AND b.name = ? AND v.chapter = ? "
            "ORDER BY v.verse")))
        , selectAllVerses(conn.prepare(kAllVersesSql))
        , searchAll(conn.prepare(QStringLiteral(
            "SELECT v.text, b.name, v.chapter, v.verse, t.code, bm25(verses_fts) AS score "
            "FROM verses_fts "
            "JOIN verses       v ON v.id = verses_fts.rowid "
            "JOIN books        b ON b.id = v.book_id "
            "JOIN translations t ON t.id = v.translation_id "
            "WHERE verses_fts MATCH ? "
            "ORDER BY score ASC "
            "LIMIT 100")))
        , searchScoped(conn.prepare(QStringLiteral(
            "SELECT v.text, b.name, v.chapter, v.verse, t.code, bm25(verses_fts) AS score "
            "FROM verses_fts "
            "JOIN verses       v ON v.id = verses_fts.rowid "
            "JOIN books        b ON b.id = v.book_id "
            "JOIN translations t ON t.id = v.translation_id "
            "WHERE verses_fts MATCH ? AND t.code = ? "
            "ORDER BY score ASC "
            "LIMIT 100")))
    {}
};

BibleService::BibleService(QObject* parent)
    : QObject(parent)
{
    try {
        m_impl = std::make_unique<Impl>(db::DbPaths::biblesDbPath());
    } catch (const db::Error& e) {
        qCritical().noquote() << "BibleService: failed to open DB —" << e.message();
        // Leave m_impl null; methods will return empty results.
        return;
    }
    // Anything the UI loaded while the worker ran wins. If preloading was
    // switched off meanwhile, the result is dropped.
    connect(&m_impl->prefetch, &QFutureWatcher<Prefetch>::finished, this, [this] {
        if (!m_impl->preloadAll) return;
        Prefetch p = m_impl->prefetch.result();
        for (auto it = p.verses.begin(); it != p.verses.end(); ++it) {
            if (m_impl->verses.contains(it.key())) continue;
            m_impl->verses.insert(it.key(), std::move(it.value()));
            m_impl->recent.append(it.key());
        }
        for (auto it = p.books.begin(); it != p.books.end(); ++it)
            if (!m_impl->books.contains(it.key())) m_impl->books.insert(it.key(), std::move(it.value()));
    });
}

void BibleService::setPreloadAll(bool on)
{
    if (!m_impl || m_impl->preloadAll == on) return;
    m_impl->preloadAll = on;
    if (on) {
        if (!m_impl->prefetch.isRunning())
            m_impl->prefetch.setFuture(QtConcurrent::run(prefetchAll));
        return;
    }
    // Back to the recent few. A list QML still shows stays alive through
    // its own reference, so this never pulls rows out from under the UI.
    while (m_impl->recent.size() > Impl::kKeepRecent) {
        const QString old = m_impl->recent.takeLast();
        m_impl->verses.remove(old);
        m_impl->verseRows.remove(old);
    }
}

BibleService::~BibleService() = default;

QList<Translation> BibleService::translations()
{
    QList<Translation> out;
    if (!m_impl) return out;
    try {
        auto& stmt = m_impl->selectTranslations;
        stmt.reset();
        while (stmt.step()) {
            Translation t;
            t.code        = stmt.columnText(0);
            t.name        = stmt.columnText(1);
            t.year        = stmt.columnInt(2);
            t.description = stmt.columnText(3);
            out.append(std::move(t));
        }
    } catch (const db::Error& e) {
        qWarning().noquote() << "BibleService::translations():" << e.message();
    }
    return out;
}

QList<Book> BibleService::books(QString translationCode)
{
    if (!m_impl) return {};
    if (auto it = m_impl->books.constFind(translationCode); it != m_impl->books.cend())
        return *it;
    try {
        QList<Book> out = readBooks(m_impl->selectBooks, translationCode);
        m_impl->books.insert(translationCode, out);
        return out;
    } catch (const db::Error& e) {
        qWarning().noquote() << "BibleService::books():" << e.message();
        return {};
    }
}

Verse BibleService::verse(QString translationCode, QString bookName, int chapter, int verseNumber)
{
    Verse v;
    if (!m_impl) return v;
    try {
        auto& stmt = m_impl->selectVerse;
        stmt.reset();
        stmt.bind(1, translationCode);
        stmt.bind(2, bookName);
        stmt.bind(3, qint64(chapter));
        stmt.bind(4, qint64(verseNumber));
        if (stmt.step()) {
            v.translationCode = translationCode;
            v.book            = bookName;
            v.chapter         = chapter;
            v.verse           = verseNumber;
            v.text            = stmt.columnText(0);
        }
        stmt.reset();   // close cursor: don't leave a read txn open on the
                        // bibles connection between lookups (WAL snapshot pin)
    } catch (const db::Error& e) {
        qWarning().noquote() << "BibleService::verse():" << e.message();
    }
    return v;
}

QList<Verse> BibleService::chapter(QString translationCode, QString bookName, int chapterNumber)
{
    QList<Verse> out;
    if (!m_impl) return out;
    try {
        auto& stmt = m_impl->selectChapter;
        stmt.reset();
        stmt.bind(1, translationCode);
        stmt.bind(2, bookName);
        stmt.bind(3, qint64(chapterNumber));
        while (stmt.step()) {
            Verse v;
            v.translationCode = translationCode;
            v.book            = bookName;
            v.chapter         = chapterNumber;
            v.verse           = stmt.columnInt(0);
            v.text            = stmt.columnText(1);
            out.append(std::move(v));
        }
    } catch (const db::Error& e) {
        qWarning().noquote() << "BibleService::chapter():" << e.message();
    }
    return out;
}

QList<Verse> BibleService::allVerses(QString translationCode)
{
    if (!m_impl) return {};
    if (auto it = m_impl->verses.constFind(translationCode); it != m_impl->verses.cend()) {
        QList<Verse> out = *it;
        m_impl->touch(translationCode);
        return out;
    }
    try {
        QList<Verse> out = readAllVerses(m_impl->selectAllVerses, translationCode);
        m_impl->verses.insert(translationCode, out);
        m_impl->touch(translationCode);
        return out;
    } catch (const db::Error& e) {
        qWarning().noquote() << "BibleService::allVerses():" << e.message();
        return {};
    }
}

int BibleService::verseIndex(QString translationCode, QString bookName, int chapter, int verseNumber)
{
    if (!m_impl) return -1;
    auto rows = m_impl->verseRows.constFind(translationCode);
    if (rows == m_impl->verseRows.cend()) {
        const QList<Verse> list = allVerses(translationCode);
        VerseRows index;
        index.rows.reserve(list.size());
        QString book;
        quint32 id = 0;
        for (int i = 0; i < list.size(); ++i) {
            const Verse& v = list[i];
            if (v.book != book) {
                book = v.book;
                const QString lower = book.toLower();
                id = index.bookIds.value(lower, quint32(index.bookIds.size()));
                index.bookIds.insert(lower, id);
            }
            index.rows.insert(VerseRows::key(id, v.chapter, v.verse), i);
        }
        rows = m_impl->verseRows.insert(translationCode, std::move(index));
    }
    const auto book = rows->bookIds.constFind(bookName.toLower());
    if (book == rows->bookIds.cend()) return -1;
    return rows->rows.value(VerseRows::key(*book, chapter, verseNumber), -1);
}

QVariantMap BibleService::parseReferenceRange(QString input)
{
    QVariantMap invalid;
    invalid[QStringLiteral("valid")] = false;
    const QString trimmed = input.trimmed();
    if (trimmed.isEmpty()) return invalid;

    // Four capture groups:
    //   1) book token — either "1 John" / "1John" / "Song of Solomon" / "jn"
    //   2) chapter (optional — defaults to 1 when omitted, so "exo" → Exodus 1:1)
    //   3) verse   (optional — defaults to 1 when omitted, so "John 3" → John 3:1)
    //   4) range end (optional — "John 3:16-18" → verses 16 through 18)
    // The first alternative for the book greedily handles digit-prefixed books
    // so "1 John 3:16" doesn't split as ["John", "1", "3"] with stray digits.
    // Chapter+verse are wrapped in an outer optional group so the operator
    // gets a live "Interpreted" hint after just typing a book prefix — they
    // see "Exodus 1:1" the moment "exo" resolves, before they type a chapter.
    static const QRegularExpression rx(QStringLiteral(
        R"(^\s*([1-3]\s*[a-zA-Z]+(?:\s+[a-zA-Z]+)*|[a-zA-Z]+(?:\s+[a-zA-Z]+)*)(?:\s*(\d+)(?:\s*[:\s]\s*(\d+)(?:\s*-\s*(\d+))?)?)?\s*$)"));

    const auto m = rx.match(trimmed);
    if (!m.hasMatch()) return invalid;

    const QString bookToken  = m.captured(1);
    const QString chapterCap = m.captured(2);
    const int chapterNum     = chapterCap.isEmpty() ? 1 : chapterCap.toInt();
    const QString verseCap   = m.captured(3);
    const int verseNum       = verseCap.isEmpty() ? 1 : verseCap.toInt();
    const QString endCap     = m.captured(4);
    // A backwards range ("16-12") is a typo, not an instruction to walk
    // upwards — clamp it to the opening verse rather than silently
    // staging a reversed passage.
    const int endNum         = endCap.isEmpty() ? verseNum
                                                : qMax(verseNum, endCap.toInt());

    // Try exact lookup first (canonical name / abbrev / known alias). If
    // that fails — common when the operator types a short prefix like
    // "exo" or "rev" — fall back to a case-insensitive prefix match across
    // all canonical books. This makes the reference input forgiving of
    // partial book names, mirroring how electron's parseScriptureInput
    // does prefix matching against `allBooks` (which is alphabetically
    // sorted). Alphabetical order matters for ambiguous prefixes: "e" →
    // Ecclesiastes (alpha first), not Ezra (canonical first); "j" → James,
    // not Joshua. Matches operator intuition for "what comes first when I
    // type one letter."
    auto bookMeta = crater::import::lookupBook(bookToken);
    if (!bookMeta.has_value()) {
        // Cache an alphabetical view over allCanonicalBooks() so the sort
        // is paid once at startup, not per keystroke. Held by reference so
        // the QString name fields aren't copied per scan.
        static const QList<crater::import::BibleBookMeta> alphaBooks = []() {
            QList<crater::import::BibleBookMeta> v = crater::import::allCanonicalBooks();
            std::sort(v.begin(), v.end(),
                      [](const crater::import::BibleBookMeta& a,
                         const crater::import::BibleBookMeta& b) {
                          return a.name.toLower() < b.name.toLower();
                      });
            return v;
        }();

        const QString lowerToken = bookToken.toLower().simplified();
        // Drop any internal whitespace so "1samuel" / "1 samuel" both probe
        // as "1 samuel" against canonical names (whose own normalization
        // also collapses whitespace).
        const QString probe = QString(lowerToken).replace(QRegularExpression(QStringLiteral("\\s+")),
                                                          QStringLiteral(" "));
        for (const auto& b : alphaBooks) {
            if (b.name.toLower().startsWith(probe)) {
                bookMeta = b;
                break;
            }
        }
    }
    if (!bookMeta.has_value()) return invalid;

    QVariantMap out;
    out[QStringLiteral("valid")]      = true;
    out[QStringLiteral("book")]       = bookMeta->name;
    out[QStringLiteral("chapter")]    = chapterNum;
    out[QStringLiteral("verseStart")] = verseNum;
    out[QStringLiteral("verseEnd")]   = endNum;
    return out;
}

// Thin wrapper kept for every caller that only wants the opening verse's
// row — the reference hint, Strong's lookups, the global search overlay.
// Widening the grammar above means those callers stop dying on a typed
// range: "John 3:16-18" used to fail the regex outright and yield no
// parse at all, so the input went dead the moment the operator hit the
// dash. Now it resolves to John 3:16 for them, and the range-aware
// caller asks for the span separately.
Verse BibleService::parseReference(QString input, QString translationCode)
{
    const QVariantMap r = parseReferenceRange(input);
    if (!r.value(QStringLiteral("valid")).toBool()) return Verse();
    return verse(translationCode,
                 r.value(QStringLiteral("book")).toString(),
                 r.value(QStringLiteral("chapter")).toInt(),
                 r.value(QStringLiteral("verseStart")).toInt());
}

QList<SearchHit> BibleService::search(QString query, QString translationCodeFilter)
{
    QList<SearchHit> out;
    if (!m_impl) return out;

    // Transform the raw query into a safe FTS5 MATCH expression: neutralize
    // operator chars, drop sub-3-char terms the trigram tokenizer can't match,
    // honor "phrases" / OR / -exclude. Empty → nothing searchable, bail before
    // touching FTS (an empty MATCH is itself a syntax error).
    const db::FtsQuery fts = db::buildFtsQuery(query);
    if (fts.isEmpty()) return out;

    try {
        db::Statement* stmt = translationCodeFilter.isEmpty()
                                ? &m_impl->searchAll
                                : &m_impl->searchScoped;
        stmt->reset();
        stmt->bind(1, fts.match);
        if (!translationCodeFilter.isEmpty()) {
            stmt->bind(2, translationCodeFilter);
        }
        while (stmt->step()) {
            SearchHit hit;
            hit.text            = stmt->columnText(0);
            hit.book            = stmt->columnText(1);
            hit.chapter         = stmt->columnInt(2);
            hit.verse           = stmt->columnInt(3);
            hit.translationCode = stmt->columnText(4);
            hit.score           = stmt->columnDouble(5);
            out.append(std::move(hit));
        }
    } catch (const db::Error& e) {
        // FTS MATCH syntax errors land here — common with partial user input.
        // Log at debug level (not warning), since users will trigger it constantly.
        qDebug().noquote() << "BibleService::search():" << e.message();
    }
    return out;
}

QFuture<void> BibleService::rebuildFtsIndex()
{
    return QtConcurrent::run([]() {
        try {
            // Worker thread opens its own connection — never share connections
            // across threads (SQLITE_OPEN_FULLMUTEX is belt-and-suspenders).
            db::Connection conn(db::DbPaths::biblesDbPath());
            db::Transaction tx(conn);
            // verses_fts is contentless (content=''), which rejects a plain
            // DELETE — 'delete-all' is the only clear. Verse text is
            // apostrophe-stripped on the way in (ASCII ' + curly char(8217)) so
            // the index matches the apostrophe-normalised query in
            // crater::db::buildFtsQuery. Same normalisation as the
            // ElectronDataImporter and the bibles V002 re-index migration.
            conn.exec(QStringLiteral(
                "INSERT INTO verses_fts(verses_fts) VALUES('delete-all')"));
            conn.exec(QStringLiteral(
                "INSERT INTO verses_fts (rowid, text, book_name, translation_code) "
                "SELECT v.id, "
                "       replace(replace(v.text, '''', ''), char(8217), ''), "
                "       b.name, t.code "
                "FROM verses v "
                "JOIN books        b ON b.id = v.book_id "
                "JOIN translations t ON t.id = v.translation_id"));
            tx.commit();
            qInfo() << "BibleService: FTS index rebuilt";
        } catch (const db::Error& e) {
            qCritical().noquote() << "BibleService::rebuildFtsIndex():" << e.message();
        }
    });
}

}  // namespace crater
