#include "crater/ElectronDataImporter.h"

#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Error.h"
#include "db/Statement.h"
#include "db/Transaction.h"
#include "import/CanonicalBibleBooks.h"

#include <QCoreApplication>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QPair>
#include <QString>
#include <QtConcurrent>

#include <functional>

namespace crater {

namespace {

// Walks up from the EXE looking for a legacy bibles.sqlite. Production layout
// expects it under <exe>/legacy/; dev falls back to the electron repo's copy.
QString findLegacyBibleDbPath()
{
    QDir d(QCoreApplication::applicationDirPath());
    for (int hop = 0; hop < 8; ++hop) {
        const QString prod = d.absoluteFilePath(QStringLiteral("legacy/bibles.sqlite"));
        if (QFile::exists(prod)) return prod;

        const QString dev = d.absoluteFilePath(
            QStringLiteral("electron/src/assets/default/databases/bibles.sqlite"));
        if (QFile::exists(dev)) return dev;

        if (!d.cdUp()) break;
    }
    return {};
}

// "1" -> [1]; "1-3" -> [1, 2, 3]; "1,3" -> [1, 3]; bad input -> [].
QList<int> parseVerseRange(const QString& s)
{
    QList<int> out;
    const QString trimmed = s.trimmed();
    if (trimmed.isEmpty()) return out;

    if (trimmed.contains(QChar(','))) {
        for (const auto& part : trimmed.split(QChar(','), Qt::SkipEmptyParts)) {
            out.append(parseVerseRange(part));
        }
        return out;
    }

    const int dash = trimmed.indexOf(QChar('-'));
    if (dash >= 0) {
        bool okA = false, okB = false;
        const int a = trimmed.left(dash).toInt(&okA);
        const int b = trimmed.mid(dash + 1).toInt(&okB);
        if (okA && okB && a <= b && (b - a) < 200) {  // sanity cap on range size
            for (int v = a; v <= b; ++v) out.append(v);
        }
        return out;
    }

    bool ok = false;
    const int n = trimmed.toInt(&ok);
    if (ok) out.append(n);
    return out;
}

void importBibleData(db::Connection& legacy,
                     db::Connection& target,
                     std::function<void(int, QString)> progress)
{
    // 1. Translations.
    QHash<qint64, qint64> legacyTransToOurs;  // legacy bibles.id -> our translations.id
    progress(2, QStringLiteral("Reading translations..."));
    {
        auto sel  = legacy.prepare(QStringLiteral(
            "SELECT id, version, description FROM bibles ORDER BY id"));
        auto ins  = target.prepare(QStringLiteral(
            "INSERT OR IGNORE INTO translations (code, name, description, sort_order) "
            "VALUES (?, ?, ?, ?)"));
        auto find = target.prepare(QStringLiteral(
            "SELECT id FROM translations WHERE code = ?"));

        int sortOrder = 0;
        while (sel.step()) {
            const qint64 legacyId = sel.columnInt64(0);
            const QString code    = sel.columnText(1);
            const QString desc    = sel.columnText(2);

            ins.reset();
            ins.bind(1, code);
            ins.bind(2, code);  // electron didn't have a "full name" column; fall back to code
            ins.bind(3, desc);
            ins.bind(4, qint64(sortOrder++));
            ins.step();

            qint64 ourId = target.lastInsertRowId();
            if (target.changes() == 0) {
                // Row already existed (re-run after partial import); look it up.
                find.reset();
                find.bind(1, code);
                if (find.step()) ourId = find.columnInt64(0);
                find.reset();   // close cursor: this reads `target` mid-loop,
                                // so leaving it open pins the snapshot and the
                                // next ins.step() write can fail with 517
            }
            legacyTransToOurs.insert(legacyId, ourId);
        }
    }
    progress(5, QStringLiteral("Translations imported"));

    // 2. Resolve canonical book metadata for every distinct book_name in the legacy DB.
    QHash<QString, import::BibleBookMeta> metaByLegacyName;
    {
        auto sel = legacy.prepare(QStringLiteral(
            "SELECT DISTINCT book_name FROM scriptures ORDER BY rowid"));
        while (sel.step()) {
            const QString legacyName = sel.columnText(0);
            const auto meta = import::lookupBook(legacyName);
            if (!meta) {
                qWarning().noquote()
                    << "Importer: unknown book name (skipping):" << legacyName;
                continue;
            }
            metaByLegacyName.insert(legacyName, *meta);
        }
    }
    progress(7, QStringLiteral("Resolving books..."));

    // 3. Insert per-translation book rows; remember the FK mapping.
    QHash<QPair<qint64, QString>, qint64> bookLookup;  // (legacyTransId, legacyName) -> our books.id
    {
        auto ins = target.prepare(QStringLiteral(
            "INSERT OR IGNORE INTO books (translation_id, name, abbrev, testament, book_number) "
            "VALUES (?, ?, ?, ?, ?)"));
        auto find = target.prepare(QStringLiteral(
            "SELECT id FROM books WHERE translation_id = ? AND book_number = ?"));

        for (auto t = legacyTransToOurs.begin(); t != legacyTransToOurs.end(); ++t) {
            const qint64 legacyTrans = t.key();
            const qint64 ourTrans    = t.value();

            for (auto b = metaByLegacyName.begin(); b != metaByLegacyName.end(); ++b) {
                const QString&             legacyName = b.key();
                const import::BibleBookMeta& m        = b.value();

                ins.reset();
                ins.bind(1, ourTrans);
                ins.bind(2, m.name);
                ins.bind(3, m.abbrev);
                ins.bind(4, m.testament);
                ins.bind(5, qint64(m.bookNumber));
                ins.step();

                qint64 ourBookId = target.lastInsertRowId();
                if (target.changes() == 0) {
                    find.reset();
                    find.bind(1, ourTrans);
                    find.bind(2, qint64(m.bookNumber));
                    if (find.step()) ourBookId = find.columnInt64(0);
                    find.reset();   // close cursor before subsequent ins writes
                }
                bookLookup.insert({legacyTrans, legacyName}, ourBookId);
            }
        }
    }
    progress(10, QStringLiteral("Books indexed"));

    // 4. Count verses for progress reporting.
    qint64 totalVerses = 0;
    {
        auto stmt = legacy.prepare(QStringLiteral("SELECT COUNT(*) FROM scriptures"));
        stmt.step();
        totalVerses = stmt.columnInt64(0);
    }

    // 5. Bulk import verses. One large transaction is dramatically faster
    //    than per-row commits (~100x) because WAL commit cost dominates.
    progress(12, QStringLiteral("Importing verses..."));
    {
        db::Transaction tx(target);
        auto sel = legacy.prepare(QStringLiteral(
            "SELECT bible_id, book_name, chapter, verse, text FROM scriptures"));
        auto ins = target.prepare(QStringLiteral(
            "INSERT OR IGNORE INTO verses (translation_id, book_id, chapter, verse, text) "
            "VALUES (?, ?, ?, ?, ?)"));

        qint64 processed   = 0;
        int    lastPercent = 12;
        while (sel.step()) {
            const qint64 legacyTrans = sel.columnInt64(0);
            const QString legacyBook = sel.columnText(1);
            const int     chapter    = sel.columnInt(2);
            const QString verseStr   = sel.columnText(3);
            const QString text       = sel.columnText(4);

            const qint64 ourTrans = legacyTransToOurs.value(legacyTrans, 0);
            const qint64 ourBook  = bookLookup.value({legacyTrans, legacyBook}, 0);
            if (ourTrans == 0 || ourBook == 0) {
                ++processed;
                continue;
            }

            for (int v : parseVerseRange(verseStr)) {
                ins.reset();
                ins.bind(1, ourTrans);
                ins.bind(2, ourBook);
                ins.bind(3, qint64(chapter));
                ins.bind(4, qint64(v));
                ins.bind(5, text);
                ins.step();
            }

            ++processed;
            const int percent = totalVerses > 0
                                  ? 12 + int(75 * processed / totalVerses)
                                  : 12;
            if (percent != lastPercent) {
                lastPercent = percent;
                progress(percent, QStringLiteral("Importing verses (%1/%2)...")
                                      .arg(processed).arg(totalVerses));
            }
        }
        tx.commit();
    }
    progress(88, QStringLiteral("Building search index..."));

    // 6. Populate FTS5 from the now-fully-imported verses table.
    {
        db::Transaction tx(target);
        target.exec(QStringLiteral("DELETE FROM verses_fts"));
        target.exec(QStringLiteral(
            "INSERT INTO verses_fts (rowid, text, book_name, translation_code) "
            "SELECT v.id, v.text, b.name, t.code "
            "FROM verses v "
            "JOIN books b        ON b.id = v.book_id "
            "JOIN translations t ON t.id = v.translation_id"));
        tx.commit();
    }
    progress(100, QStringLiteral("Done"));
}

void writeSentinel()
{
    QFile f(db::DbPaths::importSentinelPath());
    if (!f.open(QIODevice::WriteOnly)) {
        throw db::Error(QStringLiteral("Could not write import sentinel: %1").arg(f.fileName()));
    }
    f.write("v1\n");
    f.close();
}

}  // namespace

ElectronDataImporter::ElectronDataImporter(QObject* parent)
    : QObject(parent)
{}

bool ElectronDataImporter::needsImport() const
{
    return !QFile::exists(db::DbPaths::importSentinelPath());
}

bool ElectronDataImporter::legacyAvailable() const
{
    return !findLegacyBibleDbPath().isEmpty();
}

QFuture<bool> ElectronDataImporter::run()
{
    return QtConcurrent::run([this]() -> bool {
        try {
            const QString legacyPath = findLegacyBibleDbPath();
            if (legacyPath.isEmpty()) {
                qWarning() << "ElectronDataImporter: no legacy bibles.sqlite found "
                              "(production looks for <exe>/legacy/, dev looks for "
                              "electron/src/assets/default/databases/). Skipping; "
                              "Bible DB will be empty until the file is placed.";
                emit failed(QStringLiteral(
                    "Legacy Bible database not found. Place bibles.sqlite under "
                    "<exe-dir>/legacy/ and re-launch to import."));
                return false;
            }
            qInfo().noquote() << "Importer: using legacy DB at" << legacyPath;

            db::Connection legacy(legacyPath, db::OpenMode::ReadOnly);
            db::Connection target(db::DbPaths::biblesDbPath());

            importBibleData(legacy, target,
                            [this](int p, const QString& s) { emit progress(p, s); });

            writeSentinel();
            emit completed();
            return true;
        } catch (const db::Error& e) {
            qCritical().noquote() << "Importer failed:" << e.message();
            emit failed(e.message());
            return false;
        } catch (const std::exception& e) {
            qCritical() << "Importer failed (std::exception):" << e.what();
            emit failed(QString::fromUtf8(e.what()));
            return false;
        } catch (...) {
            qCritical() << "Importer failed: unknown exception";
            emit failed(QStringLiteral("Unknown error during import"));
            return false;
        }
    });
}

}  // namespace crater
