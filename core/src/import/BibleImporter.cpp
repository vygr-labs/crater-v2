#include "crater/BibleImporter.h"

#include "crater/ElectronDataImporter.h"
#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Error.h"
#include "db/Statement.h"
#include "db/Transaction.h"
#include "import/BibleFormats.h"
#include "import/CanonicalBibleBooks.h"

#include <QDebug>
#include <QElapsedTimer>
#include <QMutexLocker>
#include <QFileInfo>
#include <QRegularExpression>
#include <QtConcurrent>

#include <set>

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

}  // namespace

BibleImporter::BibleImporter(QObject* parent)
    : QObject(parent)
    , m_stop(std::make_shared<std::atomic_bool>(false))
{
}

BibleImporter::~BibleImporter()
{
    m_stop->store(true);
    if (m_task.isValid()) m_task.waitForFinished();
}

std::shared_ptr<const import::ParsedBible> BibleImporter::parse(const QStringList& files)
{
    {
        QMutexLocker lock(&m_parsedLock);
        if (m_parsed && m_parsedFiles == files) return m_parsed;
    }
    auto parsed = std::make_shared<const import::ParsedBible>(import::parseBibleFiles(files));
    QMutexLocker lock(&m_parsedLock);
    m_parsedFiles = files;
    m_parsed = parsed;
    return parsed;
}

QString BibleImporter::codeProblem(QString code) const
{
    code = code.trimmed();
    static const QRegularExpression valid(QStringLiteral("^[A-Za-z0-9][A-Za-z0-9-]{0,11}$"));
    if (code.isEmpty()) return tr("Give it a short code, like KJV.");
    if (!valid.match(code).hasMatch())
        return tr("Use up to 12 letters and numbers, with no spaces.");
    try {
        db::Connection conn(db::DbPaths::biblesDbPath(), db::OpenMode::ReadOnly,
                            QStringLiteral("BibleImport-check"));
        if (codeTaken(conn, code)) return tr("There's already a translation called %1.").arg(code.toUpper());
    } catch (const db::Error& e) {
        return e.message();
    }
    return {};
}

void BibleImporter::analyze(QStringList files)
{
    m_task = QtConcurrent::run([this, files]() {
        try {
            const auto parsed = parse(files);
            const import::ParsedBible& bible = *parsed;
            if (!bible.error.isEmpty()) {
                emit failed(bible.error);
                return;
            }
            db::Connection conn(db::DbPaths::biblesDbPath(), db::OpenMode::ReadOnly,
                                QStringLiteral("BibleImport-analyze"));
            emit analyzed(QVariantMap{
                { QStringLiteral("format"),          bible.format },
                { QStringLiteral("name"),            bible.name },
                { QStringLiteral("code"),            suggestCode(bible, conn) },
                { QStringLiteral("language"),        bible.language },
                { QStringLiteral("books"),           distinctBooks(bible) },
                { QStringLiteral("verses"),          int(bible.verses.size()) },
                { QStringLiteral("skippedBooks"),    bible.skippedBooks },
                { QStringLiteral("ignoredFiles"),    bible.ignoredFiles },
                { QStringLiteral("booksByPosition"), bible.booksByPosition },
            });
        } catch (const db::Error& e) {
            emit failed(e.message());
        } catch (...) {
            emit failed(QStringLiteral("Unexpected error while reading the file."));
        }
    });
}

void BibleImporter::run(QStringList files, QString code, QString name)
{
    code = code.trimmed().toUpper();
    name = name.trimmed();
    m_task = QtConcurrent::run([this, files, code, name]() {
        try {
            QElapsedTimer timer;
            timer.start();
            emit progress(0, QStringLiteral("Reading the file..."));
            const auto parsed = parse(files);
            const import::ParsedBible& bible = *parsed;
            if (!bible.error.isEmpty()) {
                emit failed(bible.error);
                return;
            }

            db::Connection conn(db::DbPaths::biblesDbPath(), db::OpenMode::ReadWrite,
                                QStringLiteral("BibleImport"));
            db::Transaction tx(conn);
            if (codeTaken(conn, code)) {
                emit failed(QStringLiteral("There's already a translation called %1.").arg(code));
                return;
            }
            emit progress(10, QStringLiteral("Adding the translation..."));

            qint64 sortOrder = 0;
            {
                auto last = conn.prepare(QStringLiteral(
                    "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM translations"));
                if (last.step()) sortOrder = last.columnInt64(0);
            }
            qint64 translationId = 0;
            {
                auto ins = conn.prepare(QStringLiteral(
                    "INSERT INTO translations (code, name, language, description, sort_order) "
                    "VALUES (?, ?, ?, ?, ?)"));
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
                const QList<import::BibleBookMeta>& canon = import::allCanonicalBooks();
                auto ins = conn.prepare(QStringLiteral(
                    "INSERT INTO books (translation_id, name, abbrev, testament, book_number) "
                    "VALUES (?, ?, ?, ?, ?)"));
                for (int n : numbers) {
                    const import::BibleBookMeta& m = canon.at(n - 1);
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
                const qsizetype total = bible.verses.size();
                int lastPercent = -1;
                for (qsizetype i = 0; i < total; ++i) {
                    const import::ParsedVerse& v = bible.verses.at(i);
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
                        emit progress(percent, QStringLiteral("Adding verses (%1 of %2)...")
                                                   .arg(i + 1).arg(total));
                    }
                }
            }

            emit progress(88, QStringLiteral("Building the search index..."));
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
            {
                QMutexLocker lock(&m_parsedLock);   // done with it
                m_parsed.reset();
                m_parsedFiles.clear();
            }
            qInfo().noquote() << QStringLiteral("BibleImport: %1 from %2 (%3): %4 verses in %5 ms%6")
                .arg(code, QFileInfo(files.first()).fileName(), bible.format)
                .arg(stored).arg(timer.elapsed())
                .arg(bible.skippedBooks.isEmpty() ? QString()
                     : QStringLiteral(", skipped ") + bible.skippedBooks.join(QStringLiteral(", ")));
            emit progress(100, QStringLiteral("Done"));
            emit completed(code, stored);
        } catch (const db::Error& e) {
            qWarning().noquote() << "BibleImport failed:" << e.message();
            emit failed(e.message());
        } catch (...) {
            emit failed(QStringLiteral("Unexpected error during the import."));
        }
    });
}

QSet<QString> BibleImporter::bundledCodes() const
{
    if (m_bundledRead) return m_bundled;
    m_bundledRead = true;
    const QString path = ElectronDataImporter::bundledBiblesPath();
    if (path.isEmpty()) return m_bundled;
    try {
        db::Connection conn(path, db::OpenMode::ReadOnly, QStringLiteral("BibleImport-bundled"));
        auto st = conn.prepare(QStringLiteral("SELECT version FROM bibles"));
        while (st.step()) m_bundled.insert(st.columnText(0).toUpper());
    } catch (const db::Error& e) {
        qWarning().noquote() << "BibleImport: couldn't read the bundled Bibles:" << e.message();
    }
    return m_bundled;
}

bool BibleImporter::isRemovable(QString code) const
{
    // Without the bundled list there's no telling what Crater shipped, so
    // nothing is offered for removal.
    const QSet<QString> bundled = bundledCodes();
    return !bundled.isEmpty() && !bundled.contains(code.trimmed().toUpper());
}

void BibleImporter::remove(QString code)
{
    if (!isRemovable(code)) {
        emit failed(QStringLiteral("%1 came with Crater and can't be removed.").arg(code));
        return;
    }
    m_task = QtConcurrent::run([this, code, stop = m_stop]() mutable {
        // The search index is contentless, so its rows can only go through
        // FTS5's 'delete' command with the exact values they were indexed
        // with, and that takes seconds for a whole Bible. So the values are
        // read first, the translation goes at once, and the index rows go
        // afterwards in short batches. Until then search can't return them:
        // it joins through verses, and verse ids are never reused.
        struct Indexed { qint64 id; QString text, book; };
        std::vector<Indexed> indexed;
        try {
            db::Connection conn(db::DbPaths::biblesDbPath(), db::OpenMode::ReadWrite,
                                QStringLiteral("BibleImport-remove"));
            // Every row goes explicitly, children first. With foreign keys
            // on, deleting each book scans every verse in the library for
            // children (verses.book_id leads no index): seconds of work for
            // nothing. Only this connection is affected, and only outside
            // a transaction can it be switched.
            conn.exec(QStringLiteral("PRAGMA foreign_keys = OFF"));
            db::Transaction tx(conn);
            qint64 id = 0;
            {
                auto find = conn.prepare(QStringLiteral(
                    "SELECT id, code FROM translations WHERE upper(code) = upper(?)"));
                find.bind(1, code);
                if (find.step()) {
                    id = find.columnInt64(0);
                    code = find.columnText(1);   // as indexed
                }
            }
            if (id == 0) {
                emit failed(QStringLiteral("%1 isn't installed.").arg(code));
                return;
            }
            {
                auto rows = conn.prepare(QStringLiteral(
                    "SELECT v.id, replace(replace(v.text, '''', ''), char(8217), ''), b.name "
                    "FROM verses v JOIN books b ON b.id = v.book_id WHERE v.translation_id = ?"));
                rows.bind(1, id);
                while (rows.step())
                    indexed.push_back({ rows.columnInt64(0), rows.columnText(1), rows.columnText(2) });
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
            emit failed(e.message());
            return;
        }
        emit removed(code);

        // Nothing below touches `this`. When Crater quits `stop` is set and
        // whatever is left stays in the index, where it is harmless.
        try {
            QElapsedTimer timer;
            timer.start();
            db::Connection conn(db::DbPaths::biblesDbPath(), db::OpenMode::ReadWrite,
                                QStringLiteral("BibleImport-unindex"));
            constexpr size_t kBatch = 2000;
            for (size_t start = 0; start < indexed.size() && !stop->load(); start += kBatch) {
                db::Transaction tx(conn);
                auto del = conn.prepare(QStringLiteral(
                    "INSERT INTO verses_fts (verses_fts, rowid, text, book_name, translation_code) "
                    "VALUES ('delete', ?, ?, ?, ?)"));
                for (size_t i = start; i < qMin(indexed.size(), start + kBatch); ++i) {
                    del.reset();
                    del.bind(1, indexed[i].id);
                    del.bind(2, indexed[i].text);
                    del.bind(3, indexed[i].book);
                    del.bind(4, code);
                    del.step();
                }
                tx.commit();
            }
            qInfo().noquote() << "BibleImport: cleared" << code << "from the search index in"
                              << timer.elapsed() << "ms";
        } catch (const db::Error& e) {
            qWarning().noquote() << "BibleImport: clearing" << code << "from the search index failed:"
                                 << e.message();
        }
    });
}

}  // namespace crater
