#include "crater/BibleService.h"

#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Error.h"
#include "db/Statement.h"
#include "db/Transaction.h"
#include "import/CanonicalBibleBooks.h"

#include <QDebug>
#include <QRegularExpression>
#include <QtConcurrent>

namespace crater {

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

    explicit Impl(const QString& path)
        : conn(path)
        , selectTranslations(conn.prepare(QStringLiteral(
            "SELECT code, name, year, description "
            "FROM translations "
            "ORDER BY sort_order, code")))
        , selectBooks(conn.prepare(QStringLiteral(
            "SELECT b.name, b.abbrev, b.testament, b.book_number, "
            "       COALESCE(MAX(v.chapter), 0) AS chapter_count "
            "FROM books b "
            "JOIN translations t ON t.id = b.translation_id "
            "LEFT JOIN verses v ON v.book_id = b.id AND v.translation_id = t.id "
            "WHERE t.code = ? "
            "GROUP BY b.id "
            "ORDER BY b.book_number")))
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
        , selectAllVerses(conn.prepare(QStringLiteral(
            "SELECT b.name, v.chapter, v.verse, v.text "
            "FROM verses v "
            "JOIN translations t ON t.id = v.translation_id "
            "JOIN books        b ON b.id = v.book_id "
            "WHERE t.code = ? "
            "ORDER BY b.book_number, v.chapter, v.verse")))
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
    QList<Book> out;
    if (!m_impl) return out;
    try {
        auto& stmt = m_impl->selectBooks;
        stmt.reset();
        stmt.bind(1, translationCode);
        while (stmt.step()) {
            Book b;
            b.name         = stmt.columnText(0);
            b.abbrev       = stmt.columnText(1);
            b.testament    = stmt.columnText(2);
            b.bookNumber   = stmt.columnInt(3);
            b.chapterCount = stmt.columnInt(4);
            out.append(std::move(b));
        }
    } catch (const db::Error& e) {
        qWarning().noquote() << "BibleService::books():" << e.message();
    }
    return out;
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
    QList<Verse> out;
    if (!m_impl) return out;
    try {
        auto& stmt = m_impl->selectAllVerses;
        stmt.reset();
        stmt.bind(1, translationCode);

        // Pre-allocate. KJV is ~31,103 verses; reserving avoids ~20 reallocs
        // during the append loop. Other translations are similar in size.
        out.reserve(32000);

        while (stmt.step()) {
            Verse v;
            v.translationCode = translationCode;
            v.book    = stmt.columnText(0);
            v.chapter = stmt.columnInt(1);
            v.verse   = stmt.columnInt(2);
            v.text    = stmt.columnText(3);
            out.append(std::move(v));
        }
    } catch (const db::Error& e) {
        qWarning().noquote() << "BibleService::allVerses():" << e.message();
    }
    return out;
}

Verse BibleService::parseReference(QString input, QString translationCode)
{
    Verse invalid;  // text stays empty — sentinel for "no parse"
    const QString trimmed = input.trimmed();
    if (trimmed.isEmpty()) return invalid;

    // Three capture groups:
    //   1) book token — either "1 John" / "1John" / "Song of Solomon" / "jn"
    //   2) chapter (required digit run after the book)
    //   3) verse (optional digit run after ':' or whitespace)
    // The first alternative for the book greedily handles digit-prefixed books
    // so "1 John 3:16" doesn't split as ["John", "1", "3"] with stray digits.
    static const QRegularExpression rx(QStringLiteral(
        R"(^\s*([1-3]\s*[a-zA-Z]+(?:\s+[a-zA-Z]+)*|[a-zA-Z]+(?:\s+[a-zA-Z]+)*)\s*(\d+)(?:\s*[:\s]\s*(\d+))?\s*$)"));

    const auto m = rx.match(trimmed);
    if (!m.hasMatch()) return invalid;

    const QString bookToken = m.captured(1);
    const int chapterNum    = m.captured(2).toInt();
    const QString verseCap  = m.captured(3);
    const int verseNum      = verseCap.isEmpty() ? 1 : verseCap.toInt();  // "John 3" → John 3:1

    const auto bookMeta = crater::import::lookupBook(bookToken);
    if (!bookMeta.has_value()) return invalid;

    return verse(translationCode, bookMeta->name, chapterNum, verseNum);
}

QList<SearchHit> BibleService::search(QString query, QString translationCodeFilter)
{
    QList<SearchHit> out;
    if (!m_impl) return out;
    if (query.trimmed().isEmpty()) return out;

    try {
        db::Statement* stmt = translationCodeFilter.isEmpty()
                                ? &m_impl->searchAll
                                : &m_impl->searchScoped;
        stmt->reset();
        stmt->bind(1, query);
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
            conn.exec(QStringLiteral("DELETE FROM verses_fts"));
            conn.exec(QStringLiteral(
                "INSERT INTO verses_fts (rowid, text, book_name, translation_code) "
                "SELECT v.id, v.text, b.name, t.code "
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
