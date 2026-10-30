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
// of its name ("World English Bible" -> "WEB").
QString baseCode(const import::ParsedBible& bible)
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
    return base;
}

// baseCode, made unique with a number.
QString suggestCode(const QString& base, db::Connection& conn)
{
    QString code = base;
    for (int n = 2; codeTaken(conn, code) && n < 100; ++n)
        code = base.left(8 - QString::number(n).size()) + QString::number(n);
    return code;
}

// The row a replace would take over.
struct ReplaceTarget
{
    qint64  id = 0;
    QString code, name, source, replacedFrom;
    qint64  sortOrder = 0;
    bool    found = false;

    // Added from a file, or an old copy an import replaced.
    bool removable() const { return found && (source == u"file" || !replacedFrom.isEmpty()); }
};

ReplaceTarget replaceTarget(db::Connection& conn, const QString& code)
{
    ReplaceTarget t;
    auto st = conn.prepare(QStringLiteral(
        "SELECT id, code, name, source, COALESCE(replaced_from, ''), sort_order "
        "FROM translations WHERE upper(code) = upper(?)"));
    st.bind(1, code);
    if (st.step()) {
        t.id           = st.columnInt64(0);
        t.code         = st.columnText(1);
        t.name         = st.columnText(2);
        t.source       = st.columnText(3);
        t.replacedFrom = st.columnText(4);
        t.sortOrder    = st.columnInt64(5);
        t.found        = true;
    }
    return t;
}

// KJV-OLD, then KJV-OLD2 and so on, cut to fit the 12 a code may hold. Empty
// if somehow all of them are taken.
QString retiredCodeFor(db::Connection& conn, const QString& code)
{
    for (int n = 1; n < 100; ++n) {
        const QString suffix = n == 1 ? QStringLiteral("-OLD") : QStringLiteral("-OLD%1").arg(n);
        const QString retired = code.left(12 - suffix.size()) + suffix;
        if (!codeTaken(conn, retired)) return retired;
    }
    return {};
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
        return replaceTarget(conn, code).removable();
    } catch (const db::Error& e) {
        qWarning().noquote() << "BibleImport: isRemovable:" << e.message();
        return false;
    }
}

bool BibleImporter::canReplace(QString code) const
{
    code = code.trimmed();
    if (code.isEmpty()) return false;
    try {
        db::Connection conn(db::DbPaths::biblesDbPath(), db::OpenMode::ReadOnly,
                            QStringLiteral("BibleImport-check"));
        const ReplaceTarget t = replaceTarget(conn, code);
        return t.found && t.replacedFrom.isEmpty();
    } catch (const db::Error& e) {
        qWarning().noquote() << "BibleImport: canReplace:" << e.message();
        return false;
    }
}

QVariantMap BibleImporter::replaceInfo(QString code) const
{
    code = code.trimmed();
    if (code.isEmpty()) return {};
    try {
        db::Connection conn(db::DbPaths::biblesDbPath(), db::OpenMode::ReadOnly,
                            QStringLiteral("BibleImport-check"));
        const ReplaceTarget t = replaceTarget(conn, code);
        if (!t.found || !t.replacedFrom.isEmpty()) return {};
        auto count = conn.prepare(QStringLiteral("SELECT COUNT(*) FROM verses WHERE translation_id = ?"));
        count.bind(1, t.id);
        return {
            { QStringLiteral("code"),        t.code },
            { QStringLiteral("name"),        t.name },
            { QStringLiteral("verses"),      count.step() ? count.columnInt(0) : 0 },
            { QStringLiteral("retiredCode"), retiredCodeFor(conn, t.code) },
        };
    } catch (const db::Error& e) {
        qWarning().noquote() << "BibleImport: replaceInfo:" << e.message();
        return {};
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
            const QString base = baseCode(bible);
            const ReplaceTarget existing = replaceTarget(conn, base);
            emit analyzed(request, QVariantMap{
                { QStringLiteral("format"),          bible.format },
                { QStringLiteral("name"),            bible.name },
                { QStringLiteral("code"),            suggestCode(base, conn) },
                { QStringLiteral("existingCode"),    existing.found && existing.replacedFrom.isEmpty()
                                                         ? existing.code : QString() },
                { QStringLiteral("language"),        bible.language },
                { QStringLiteral("books"),           distinctBooks(bible) },
                { QStringLiteral("verses"),          verseCount(bible) },
                { QStringLiteral("skippedBooks"),    bible.skippedBooks },
                { QStringLiteral("ignoredFiles"),    bible.ignoredFiles },
                { QStringLiteral("files"),           bible.fileCount },
                { QStringLiteral("otherFormats"),    bible.otherFormats },
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
    return startImport(std::move(files), std::move(code), std::move(name), false);
}

int BibleImporter::replace(QStringList files, QString code, QString name)
{
    return startImport(std::move(files), std::move(code), std::move(name), true);
}

int BibleImporter::startImport(QStringList files, QString code, QString name, bool replacing)
{
    const int request = m_nextRequest++;
    code = code.trimmed().toUpper();
    name = name.trimmed();
    m_pool.start([this, request, files, code, name, replacing, stop = m_stop]() mutable {
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
            const ReplaceTarget existing = replaceTarget(conn, code);
            if (existing.found && !replacing) {
                emit failed(request, tr("There's already a translation called %1.").arg(code));
                return;
            }
            if (existing.found && !existing.replacedFrom.isEmpty()) {
                emit failed(request, tr("%1 is an old copy and can't be replaced. Switch it back or remove it first.")
                                         .arg(existing.code));
                return;
            }
            emit progress(request, 10, tr("Adding the translation..."));

            qint64 sortOrder = 0;
            {
                auto last = conn.prepare(QStringLiteral(
                    "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM translations"));
                if (last.step()) sortOrder = last.columnInt64(0);
            }
            // The old copy moves aside and to the end of the list, and the
            // new one takes its code and place. Its rows in the search index
            // stay valid: search joins through verses for the code, and the
            // verses aren't touched.
            QString retiredCode;
            if (existing.found) {
                retiredCode = retiredCodeFor(conn, existing.code);
                if (retiredCode.isEmpty()) {
                    emit failed(request, tr("There are too many old copies of %1. Remove one first.")
                                             .arg(existing.code));
                    return;
                }
                auto move = conn.prepare(QStringLiteral(
                    "UPDATE translations SET code = ?, replaced_from = ?, sort_order = ? WHERE id = ?"));
                move.bind(1, retiredCode);
                move.bind(2, existing.code);
                move.bind(3, sortOrder);
                move.bind(4, existing.id);
                move.step();
                code = existing.code;
                sortOrder = existing.sortOrder;
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
            if (retiredCode.isEmpty()) emit completed(request, code, stored);
            else emit replaced(request, code, retiredCode, stored);
        } catch (const db::Error& e) {
            qWarning().noquote() << "BibleImport failed:" << e.message();
            emit failed(request, userMessage(e));
        } catch (...) {
            emit failed(request, tr("Something went wrong during the import."));
        }
    });
    return request;
}

int BibleImporter::switchBack(QString retiredCode)
{
    const int request = m_nextRequest++;
    retiredCode = retiredCode.trimmed();
    m_pool.start([this, request, retiredCode]() {
        QString code, oldCode;
        try {
            db::Connection conn(db::DbPaths::biblesDbPath(), db::OpenMode::ReadWrite,
                                QStringLiteral("BibleImport-switch"));
            db::Transaction tx(conn, db::Transaction::Begin::Immediate);
            const ReplaceTarget old = replaceTarget(conn, retiredCode);
            if (!old.found || old.replacedFrom.isEmpty()) {
                emit failed(request, tr("%1 isn't an old copy of another translation.").arg(retiredCode));
                return;
            }
            code = old.replacedFrom;
            oldCode = old.code;
            const ReplaceTarget current = replaceTarget(conn, code);
            auto set = conn.prepare(QStringLiteral(
                "UPDATE translations SET code = ?, replaced_from = NULLIF(?, ''), sort_order = ? WHERE id = ?"));
            const auto apply = [&set](const QString& newCode, const QString& from, qint64 order, qint64 id) {
                set.reset();
                set.bind(1, newCode);
                set.bind(2, from);
                set.bind(3, order);
                set.bind(4, id);
                set.step();
            };
            // Codes are unique, so the current copy steps out of the way
            // through a name no code can have.
            if (current.found) apply(QStringLiteral("~switching"), QString(), current.sortOrder, current.id);
            apply(code, QString(), current.found ? current.sortOrder : old.sortOrder, old.id);
            if (current.found) apply(oldCode, code, old.sortOrder, current.id);
            tx.commit();
            qInfo().noquote() << "BibleImport: switched" << oldCode << "back to" << code;
        } catch (const db::Error& e) {
            qWarning().noquote() << "BibleImport: switching" << retiredCode << "back failed:" << e.message();
            emit failed(request, userMessage(e));
            return;
        }
        emit switchedBack(request, code, oldCode);
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
            const ReplaceTarget target = replaceTarget(conn, code);
            const qint64 id = target.id;
            if (!target.found) {
                emit failed(request, tr("%1 isn't installed.").arg(code));
                return;
            }
            code = target.code;
            if (!target.removable()) {
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
