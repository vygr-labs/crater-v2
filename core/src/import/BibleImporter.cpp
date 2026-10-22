#include "crater/BibleImporter.h"

#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Error.h"
#include "db/Statement.h"
#include "db/Transaction.h"
#include "import/BibleFormats.h"
#include "import/CanonicalBibleBooks.h"

#include <QDateTime>
#include <QDebug>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QLocale>
#include <QMutexLocker>
#include <QRegularExpression>
#include <QThread>
#include <QTimer>

#include <set>
#include <vector>

namespace crater {

namespace {

bool codeTaken(db::Connection& conn, const QString& code)
{
    auto st = conn.prepare(QStringLiteral("SELECT 1 FROM translations WHERE upper(code) = upper(?)"));
    st.bind(1, code);
    const bool taken = st.step();
    st.reset();
    return taken;
}

// Letters, digits and hyphens, up to 12, starting with a letter or digit.
// Empty when `code` has that shape, otherwise why not.
QString codeShapeProblem(const QString& code)
{
    static const QRegularExpression valid(QStringLiteral("^[A-Za-z0-9][A-Za-z0-9-]{0,11}$"));
    if (code.isEmpty()) return BibleImporter::tr("Give it a short code, like KJV.");
    if (!valid.match(code).hasMatch())
        return BibleImporter::tr("Use up to 12 letters, numbers or hyphens, with no spaces.");
    return {};
}

bool isBusy(const db::Error& e)
{
    // SQLITE_BUSY and SQLITE_LOCKED, with their extended codes.
    const int primary = e.sqliteCode() & 0xff;
    return primary == 5 || primary == 6;
}

QString userMessage(const db::Error& e)
{
    if (isBusy(e))
        return BibleImporter::tr("Crater was busy with another change to the Bibles. Try again in a moment.");
    return e.message();
}

// Letters and digits from the file's own code ("KJV"), else the initials
// of its name ("World English Bible" -> "WEB"), made unique with a number.
QString suggestCode(const import::ParsedBible& bible, db::Connection& conn)
{
    static const QRegularExpression notCode(QStringLiteral("[^A-Za-z0-9]"));
    // OSIS works are often dotted ("Bible.en.kjv"): the last part is the code.
    static const QRegularExpression separator(QStringLiteral("[.:]"));
    const QStringList parts = bible.code.split(separator, Qt::SkipEmptyParts);
    QString base = parts.isEmpty() ? QString() : parts.last();
    base.remove(notCode);
    if (base.isEmpty()) {
        // A folder of book files is named after the download: eBible's
        // "eng-web_usfm" is language, translation, format.
        static const QRegularExpression formatSuffix(
            QStringLiteral("[\\s_.-]*(usfm|usx|osis|zefania|opensong|xml)$"),
            QRegularExpression::CaseInsensitiveOption);
        static const QRegularExpression ebibleId(QStringLiteral("^[a-z]{2,3}[-_]([A-Za-z0-9]+)$"));
        static const QRegularExpression wordBreak(QStringLiteral("[\\s_-]+"));
        QString name = bible.name.trimmed();
        name.remove(formatSuffix);
        if (const auto m = ebibleId.match(name); m.hasMatch()) {
            base = m.captured(1);
        } else {
            const QStringList words = name.split(wordBreak, Qt::SkipEmptyParts);
            if (words.size() == 1) {
                base = words.first();   // "Darby" stays a word, not "D"
            } else {
                for (const QString& word : words) {
                    const QChar c = word.front();
                    if (c.isLetterOrNumber() && c.unicode() < 128) base += c;
                }
            }
        }
        base.remove(notCode);
    }
    base = base.toUpper().left(8);
    if (base.isEmpty()) base = QStringLiteral("BIBLE");
    QString code = base;
    for (int n = 2; codeTaken(conn, code) && n < 100; ++n)
        code = base.left(8 - QString::number(n).size()) + QString::number(n);
    return code;
}

int distinctBooks(const import::ParsedBible& bible)
{
    std::set<int> books;
    for (const import::ParsedVerse& v : bible.verses) books.insert(v.book);
    return int(books.size());
}

// Verses as they'll be stored: a combined one ("1-2") under each number, so
// the count before the import matches the one after.
int verseCount(const import::ParsedBible& bible)
{
    int n = 0;
    for (const import::ParsedVerse& v : bible.verses) n += v.verseEnd - v.verse + 1;
    return n;
}

// Clears the search index rows a removal left in verses_fts_pending_delete
// (see db/BibleExtras.h), a batch per transaction so an import or
// a search never waits long behind it. Finding the library busy, it tries
// again up to `busyRetries` times; then, or on a quit, the rest waits for
// the next time. Before an import or removal the operator is waiting on,
// that is no retry at all.
//
// A row is only deleted while the index still has it. An older Crater knows
// nothing of the pending table, so one that rebuilt the index meanwhile left
// the table full of rows the new index never had, and deleting a row a
// contentless index doesn't hold corrupts it.
void clearPendingIndexRows(const std::atomic_bool& stop, int busyRetries)
{
    QElapsedTimer timer;
    timer.start();
    int cleared = 0;
    constexpr int kBatch = 2000;
    // Opening the connection can find the library busy too (another
    // connection starting up at launch), so the retry covers everything.
    // Batches already committed stay done; a retry carries on from there.
    for (int retried = 0; !stop.load(); ) {
        try {
            db::Connection conn(db::DbPaths::biblesDbPath(), db::OpenMode::ReadWrite,
                                QStringLiteral("BibleImport-unindex"));
            while (!stop.load()) {
                struct Row { qint64 id; QString text, book, code; };
                std::vector<Row> rows;
                {
                    auto sel = conn.prepare(QStringLiteral(
                        "SELECT verse_id, text, book_name, translation_code "
                        "FROM verses_fts_pending_delete LIMIT ?"));
                    sel.bind(1, qint64(kBatch));
                    while (sel.step())
                        rows.push_back({ sel.columnInt64(0), sel.columnText(1), sel.columnText(2),
                                         sel.columnText(3) });
                }
                if (rows.empty()) break;
                db::Transaction tx(conn, db::Transaction::Begin::Immediate);
                auto indexed = conn.prepare(QStringLiteral("SELECT 1 FROM verses_fts WHERE rowid = ?"));
                auto del = conn.prepare(QStringLiteral(
                    "INSERT INTO verses_fts (verses_fts, rowid, text, book_name, translation_code) "
                    "VALUES ('delete', ?, ?, ?, ?)"));
                auto done = conn.prepare(QStringLiteral(
                    "DELETE FROM verses_fts_pending_delete WHERE verse_id = ?"));
                for (const Row& r : rows) {
                    indexed.reset();
                    indexed.bind(1, r.id);
                    if (indexed.step()) {
                        indexed.reset();
                        del.reset();
                        del.bind(1, r.id);
                        del.bind(2, r.text);
                        del.bind(3, r.book);
                        del.bind(4, r.code);
                        del.step();
                    }
                    done.reset();
                    done.bind(1, r.id);
                    done.step();
                }
                tx.commit();
                cleared += int(rows.size());
                retried = 0;
            }
            break;
        } catch (const db::Error& e) {
            if (isBusy(e) && ++retried <= busyRetries) {
                for (int slept = 0; slept < 250 && !stop.load(); slept += 50) QThread::msleep(50);
                continue;
            }
            qWarning().noquote() << "BibleImport: clearing removed verses from the search index stopped:"
                                 << e.message();
            break;
        }
    }
    if (cleared > 0)
        qInfo().noquote() << "BibleImport: cleared" << cleared << "removed verses from the search index in"
                          << timer.elapsed() << "ms";
}

}  // namespace

BibleImporter::BibleImporter(QObject* parent)
    : QObject(parent)
    , m_stop(std::make_shared<std::atomic_bool>(false))
{
    m_pool.setMaxThreadCount(1);
    // Finish any search index clean-up a quit interrupted last time, once
    // startup is over: a write connection opening while the other services
    // open theirs can find the library busy. Imports and removals also
    // finish it first, whenever they come.
    QTimer::singleShot(10'000, this, [this] {
        m_pool.start([stop = m_stop] { clearPendingIndexRows(*stop, 20); });
    });
}

BibleImporter::~BibleImporter()
{
    m_stop->store(true);
    m_pool.waitForDone();
}

std::shared_ptr<const import::ParsedBible> BibleImporter::parse(const QStringList& files)
{
    const int generation = m_parseGeneration.load();
    QString key;
    for (const QString& f : files) {
        const QFileInfo info(f);
        key += f + u'|' + QString::number(info.size()) + u'|'
             + QString::number(info.lastModified().toMSecsSinceEpoch()) + u'\n';
    }
    {
        QMutexLocker lock(&m_parsedLock);
        if (m_parsed && m_parsedKey == key) return m_parsed;
    }
    auto parsed = std::make_shared<const import::ParsedBible>(import::parseBibleFiles(files));
    QMutexLocker lock(&m_parsedLock);
    // Not kept if discardAnalysis() ran meanwhile: the dialog that asked is
    // gone.
    if (parsed->error.isEmpty() && generation == m_parseGeneration.load()) {
        m_parsedKey = key;
        m_parsed = parsed;
    }
    return parsed;
}

void BibleImporter::discardAnalysis()
{
    ++m_parseGeneration;
    QMutexLocker lock(&m_parsedLock);
    m_parsed.reset();
    m_parsedKey.clear();
}

QString BibleImporter::codeProblem(QString code) const
{
    code = code.trimmed();
    if (const QString shape = codeShapeProblem(code); !shape.isEmpty()) return shape;
    try {
        db::Connection conn(db::DbPaths::biblesDbPath(), db::OpenMode::ReadOnly,
                            QStringLiteral("BibleImport-check"));
        if (codeTaken(conn, code)) return tr("There's already a translation called %1.").arg(code.toUpper());
    } catch (const db::Error& e) {
        return userMessage(e);
    }
    return {};
}

bool BibleImporter::isRemovable(QString code) const
{
    code = code.trimmed();
    if (code.isEmpty()) return false;
    try {
        db::Connection conn(db::DbPaths::biblesDbPath(), db::OpenMode::ReadOnly,
                            QStringLiteral("BibleImport-check"));
        auto st = conn.prepare(QStringLiteral(
            "SELECT source FROM translations WHERE upper(code) = upper(?)"));
        st.bind(1, code);
        return st.step() && st.columnText(0) == u"file";
    } catch (const db::Error& e) {
        qWarning().noquote() << "BibleImport: isRemovable:" << e.message();
        return false;
    }
}

int BibleImporter::analyze(QStringList files)
{
    const int request = m_nextRequest++;
    m_pool.start([this, request, files]() {
        try {
            const auto parsed = parse(files);
            const import::ParsedBible& bible = *parsed;
            if (!bible.error.isEmpty()) {
                emit failed(request, bible.error);
                return;
            }
            db::Connection conn(db::DbPaths::biblesDbPath(), db::OpenMode::ReadOnly,
                                QStringLiteral("BibleImport-analyze"));
            emit analyzed(request, QVariantMap{
                { QStringLiteral("format"),          bible.format },
                { QStringLiteral("name"),            bible.name },
                { QStringLiteral("code"),            suggestCode(bible, conn) },
                { QStringLiteral("language"),        bible.language },
                { QStringLiteral("books"),           distinctBooks(bible) },
                { QStringLiteral("verses"),          verseCount(bible) },
                { QStringLiteral("skippedBooks"),    bible.skippedBooks },
                { QStringLiteral("ignoredFiles"),    bible.ignoredFiles },
                { QStringLiteral("warnings"),        bible.warnings },
                { QStringLiteral("booksByPosition"), bible.booksByPosition },
            });
        } catch (const db::Error& e) {
            emit failed(request, userMessage(e));
        } catch (...) {
            emit failed(request, tr("Something went wrong reading the file."));
        }
    });
    return request;
}

int BibleImporter::run(QStringList files, QString code, QString name)
{
    const int request = m_nextRequest++;
    code = code.trimmed().toUpper();
    name = name.trimmed();
    m_pool.start([this, request, files, code, name, stop = m_stop]() {
        if (const QString shape = codeShapeProblem(code); !shape.isEmpty()) {
            emit failed(request, shape);
            return;
        }
        emit progress(request, 0, tr("Reading the file..."));
        clearPendingIndexRows(*stop, 0);
        try {
            QElapsedTimer timer;
            timer.start();
            const auto parsed = parse(files);
            const import::ParsedBible& bible = *parsed;
            if (!bible.error.isEmpty()) {
                emit failed(request, bible.error);
                return;
            }

            db::Connection conn(db::DbPaths::biblesDbPath(), db::OpenMode::ReadWrite,
                                QStringLiteral("BibleImport"));
            db::Transaction tx(conn, db::Transaction::Begin::Immediate);
            if (codeTaken(conn, code)) {
                emit failed(request, tr("There's already a translation called %1.").arg(code));
                return;
            }
            emit progress(request, 10, tr("Adding the translation..."));

            qint64 sortOrder = 0;
            {
                auto last = conn.prepare(QStringLiteral(
                    "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM translations"));
                if (last.step()) sortOrder = last.columnInt64(0);
            }
            qint64 translationId = 0;
            {
                auto ins = conn.prepare(QStringLiteral(
                    "INSERT INTO translations (code, name, language, description, sort_order, source) "
                    "VALUES (?, ?, ?, ?, ?, 'file')"));
                ins.bind(1, code);
                ins.bind(2, name.isEmpty() ? code : name);
                ins.bind(3, bible.language.isEmpty() ? QStringLiteral("en") : bible.language.toLower());
                ins.bind(4, name.isEmpty() ? code : name);
                ins.bind(5, sortOrder);
                ins.step();
                translationId = conn.lastInsertRowId();
            }

            // Canonical English book names, as every bundled Bible has, so a
            // reference typed or saved in one translation finds the verse in
            // this one.
            QHash<int, qint64> bookIds;
            {
                std::set<int> numbers;
                for (const import::ParsedVerse& v : bible.verses) numbers.insert(v.book);
                auto ins = conn.prepare(QStringLiteral(
                    "INSERT INTO books (translation_id, name, abbrev, testament, book_number) "
                    "VALUES (?, ?, ?, ?, ?)"));
                for (int n : numbers) {
                    const import::BibleBookMeta* book = import::bookByNumber(n);
                    if (!book) continue;   // the readers only produce books Crater holds
                    const import::BibleBookMeta& m = *book;
                    ins.reset();
                    ins.bind(1, translationId);
                    ins.bind(2, m.name);
                    ins.bind(3, m.abbrev);
                    ins.bind(4, m.testament);
                    ins.bind(5, qint64(m.bookNumber));
                    ins.step();
                    bookIds.insert(n, conn.lastInsertRowId());
                }
            }

            // A combined verse ("1-2") is stored under each number it
            // covers, as the bundled Bibles do. BibleService shows such
            // neighbours as one row.
            {
                auto ins = conn.prepare(QStringLiteral(
                    "INSERT OR IGNORE INTO verses (translation_id, book_id, chapter, verse, text) "
                    "VALUES (?, ?, ?, ?, ?)"));
                const QLocale locale;
                const qsizetype total = bible.verses.size();
                int lastPercent = -1;
                for (qsizetype i = 0; i < total; ++i) {
                    // Quitting: the transaction rolls back, nothing is added.
                    if ((i & 1023) == 0 && stop->load()) return;
                    const import::ParsedVerse& v = bible.verses.at(i);
                    if (!bookIds.contains(v.book)) continue;   // a book with no row above
                    for (int n = v.verse; n <= v.verseEnd; ++n) {
                        ins.reset();
                        ins.bind(1, translationId);
                        ins.bind(2, bookIds.value(v.book));
                        ins.bind(3, qint64(v.chapter));
                        ins.bind(4, qint64(n));
                        ins.bind(5, v.text);
                        ins.step();
                    }
                    const int percent = 10 + int(75 * (i + 1) / qMax<qsizetype>(1, total));
                    if (percent != lastPercent) {
                        lastPercent = percent;
                        emit progress(request, percent, tr("Adding verses (%1 of %2)...")
                                                            .arg(locale.toString(i + 1), locale.toString(total)));
                    }
                }
            }

            emit progress(request, 88, tr("Building the search index..."));
            // Same index shape and apostrophe stripping as the first-run
            // importer, BibleService::rebuildFtsIndex and mergeBibles.
            {
                auto fts = conn.prepare(QStringLiteral(
                    "INSERT INTO verses_fts (rowid, text, book_name, translation_code) "
                    "SELECT v.id, replace(replace(v.text, '''', ''), char(8217), ''), b.name, t.code "
                    "FROM verses v JOIN books b ON b.id = v.book_id "
                    "JOIN translations t ON t.id = v.translation_id WHERE v.translation_id = ?"));
                fts.bind(1, translationId);
                fts.step();
            }
            int stored = 0;
            {
                auto count = conn.prepare(QStringLiteral("SELECT COUNT(*) FROM verses WHERE translation_id = ?"));
                count.bind(1, translationId);
                if (count.step()) stored = count.columnInt(0);
            }
            tx.commit();
            discardAnalysis();   // done with it
            qInfo().noquote() << QStringLiteral("BibleImport: %1 from %2 (%3): %4 verses in %5 ms%6")
                .arg(code, QFileInfo(files.first()).fileName(), bible.format)
                .arg(stored).arg(timer.elapsed())
                .arg(bible.skippedBooks.isEmpty() ? QString()
                     : QStringLiteral(", skipped ") + bible.skippedBooks.join(QStringLiteral(", ")));
            emit progress(request, 100, tr("Done"));
            emit completed(request, code, stored);
        } catch (const db::Error& e) {
            qWarning().noquote() << "BibleImport failed:" << e.message();
            emit failed(request, userMessage(e));
        } catch (...) {
            emit failed(request, tr("Something went wrong during the import."));
        }
    });
    return request;
}

int BibleImporter::remove(QString code)
{
    const int request = m_nextRequest++;
    code = code.trimmed();
    m_pool.start([this, request, code, stop = m_stop]() mutable {
        clearPendingIndexRows(*stop, 0);
        try {
            db::Connection conn(db::DbPaths::biblesDbPath(), db::OpenMode::ReadWrite,
                                QStringLiteral("BibleImport-remove"));
            // Every row goes explicitly, children first. With foreign keys
            // on, deleting each book scans every verse in the library for
            // children (verses.book_id leads no index): seconds of work for
            // nothing. Only this connection is affected, and only outside
            // a transaction can it be switched.
            conn.exec(QStringLiteral("PRAGMA foreign_keys = OFF"));
            db::Transaction tx(conn, db::Transaction::Begin::Immediate);
            qint64 id = 0;
            QString source;
            {
                auto find = conn.prepare(QStringLiteral(
                    "SELECT id, code, source FROM translations WHERE upper(code) = upper(?)"));
                find.bind(1, code);
                if (find.step()) {
                    id = find.columnInt64(0);
                    code = find.columnText(1);
                    source = find.columnText(2);
                }
            }
            if (id == 0) {
                emit failed(request, tr("%1 isn't installed.").arg(code));
                return;
            }
            if (source != u"file") {
                emit failed(request, tr("%1 came with Crater and can't be removed. Untick it to hide it.").arg(code));
                return;
            }
            // The index rows can only be deleted with the values they were
            // indexed with, which go with the verses. They're kept for the
            // clean-up below (see db/BibleExtras.h).
            {
                auto keep = conn.prepare(QStringLiteral(
                    "INSERT OR REPLACE INTO verses_fts_pending_delete "
                    "(verse_id, text, book_name, translation_code) "
                    "SELECT v.id, replace(replace(v.text, '''', ''), char(8217), ''), b.name, t.code "
                    "FROM verses v JOIN books b ON b.id = v.book_id "
                    "JOIN translations t ON t.id = v.translation_id WHERE v.translation_id = ?"));
                keep.bind(1, id);
                keep.step();
            }
            for (const char* sql : { "DELETE FROM verses WHERE translation_id = ?",
                                     "DELETE FROM books WHERE translation_id = ?",
                                     "DELETE FROM translations WHERE id = ?" }) {
                auto del = conn.prepare(QString::fromLatin1(sql));
                del.bind(1, id);
                del.step();
            }
            tx.commit();
            qInfo().noquote() << "BibleImport: removed" << code;
        } catch (const db::Error& e) {
            qWarning().noquote() << "BibleImport: removing" << code << "failed:" << e.message();
            emit failed(request, userMessage(e));
            return;
        }
        emit removed(request, code);
        clearPendingIndexRows(*stop, 20);
    });
    return request;
}

}  // namespace crater
