// Paragraph translations in BibleService.
//
// The Message is written in paragraphs, and the importer stores a paragraph
// under every verse number it covers. BibleService turns each run of
// neighbouring verses with the same text into one row spanning them, so the
// verse list, lookups and search show the paragraph once, as "16-18".

#include <QDir>
#include <QObject>
#include <QStandardPaths>
#include <QString>
#include <QTest>

#include "crater/BibleService.h"
#include "crater/Bootstrap.h"

#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Statement.h"

using crater::BibleService;

namespace {
const QString kCode      = QStringLiteral("P1");
const QString kParagraph = QStringLiteral("This is how much God loved the world paragraph");
const QString kRefrain   = QStringLiteral("Oh that men would praise the refrain");
}  // namespace

class TestBibleParagraphs : public QObject
{
    Q_OBJECT

private:
    QString m_dataDir;

    void seed()
    {
        crater::db::Connection conn(crater::db::DbPaths::biblesDbPath());
        conn.prepare(u"INSERT INTO translations (code, name) VALUES (?, ?)")
            .bind(1, kCode).bind(2, kCode).step();
        const qint64 tid = conn.lastInsertRowId();
        auto book = [&](const QString& name, int number) {
            conn.prepare(u"INSERT INTO books (translation_id, name, abbrev, testament, book_number) "
                         u"VALUES (?, ?, ?, ?, ?)")
                .bind(1, tid).bind(2, name).bind(3, name.left(3)).bind(4, QStringLiteral("OT"))
                .bind(5, number).step();
            return conn.lastInsertRowId();
        };
        const qint64 psalms = book(QStringLiteral("Psalms"), 19);
        const qint64 john   = book(QStringLiteral("John"), 43);
        auto verse = [&](qint64 bookId, int chapter, int number, const QString& text) {
            conn.prepare(u"INSERT INTO verses (translation_id, book_id, chapter, verse, text) "
                         u"VALUES (?, ?, ?, ?, ?)")
                .bind(1, tid).bind(2, bookId).bind(3, chapter).bind(4, number).bind(5, text).step();
        };
        // A repeated line that is not a paragraph: the same words in verses
        // that aren't neighbours stay separate.
        verse(psalms, 107, 8,  kRefrain);
        verse(psalms, 107, 9,  QStringLiteral("For he satisfieth the longing soul"));
        verse(psalms, 107, 15, kRefrain);
        verse(john, 3, 15, QStringLiteral("Whoever believes"));
        verse(john, 3, 16, kParagraph);
        verse(john, 3, 17, kParagraph);
        verse(john, 3, 18, kParagraph);
        verse(john, 3, 19, QStringLiteral("This is the crisis"));
        // Same text either side of a chapter break is not one paragraph.
        verse(john, 3, 36, QStringLiteral("Same words both sides of a chapter"));
        verse(john, 4, 1,  QStringLiteral("Same words both sides of a chapter"));
    }

    static QString spans(const QList<crater::Verse>& rows)
    {
        QStringList out;
        for (const auto& v : rows) out << v.reference();
        return out.join(QStringLiteral(", "));
    }

private slots:
    void initTestCase()
    {
        QStandardPaths::setTestModeEnabled(true);
        m_dataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        QVERIFY(!m_dataDir.isEmpty());
        QDir(m_dataDir).removeRecursively();
        crater::runAllMigrations();
        seed();
        BibleService().rebuildFtsIndex().waitForFinished();
    }

    void cleanupTestCase()
    {
        QDir(m_dataDir).removeRecursively();
    }

    void allVersesListsAParagraphOnce()
    {
        BibleService bible;
        QCOMPARE(spans(bible.allVerses(kCode)),
                 QStringLiteral("Psalms 107:8, Psalms 107:9, Psalms 107:15, John 3:15, "
                                "John 3:16-18, John 3:19, John 3:36, John 4:1"));
    }

    void chapterListsAParagraphOnce()
    {
        BibleService bible;
        QCOMPARE(spans(bible.chapter(kCode, QStringLiteral("John"), 3)),
                 QStringLiteral("John 3:15, John 3:16-18, John 3:19, John 3:36"));
    }

    void everyVerseOfAParagraphFindsItsRow()
    {
        BibleService bible;
        const int row = bible.verseIndex(kCode, QStringLiteral("John"), 3, 16);
        QCOMPARE(row, 4);
        QCOMPARE(bible.verseIndex(kCode, QStringLiteral("John"), 3, 17), row);
        QCOMPARE(bible.verseIndex(kCode, QStringLiteral("john"), 3, 18), row);
        QCOMPARE(bible.verseIndex(kCode, QStringLiteral("John"), 3, 19), row + 1);
    }

    // Uncached (one chapter read) and cached (row index) give the same row.
    void verseInsideAParagraphReturnsTheParagraph()
    {
        BibleService fresh;
        const auto a = fresh.verse(kCode, QStringLiteral("John"), 3, 17);
        QCOMPARE(a.reference(), QStringLiteral("John 3:16-18"));
        QCOMPARE(a.text, kParagraph);

        BibleService cached;
        cached.allVerses(kCode);
        const auto b = cached.verse(kCode, QStringLiteral("John"), 3, 18);
        QCOMPARE(b.verse, 16);
        QCOMPARE(b.verseEnd, 18);

        const auto plain = cached.verse(kCode, QStringLiteral("John"), 3, 19);
        QCOMPARE(plain.verse, 19);
        QCOMPARE(plain.verseEnd, 0);
        QVERIFY(cached.verse(kCode, QStringLiteral("John"), 3, 20).text.isEmpty());
    }

    void parseReferenceInsideAParagraph()
    {
        BibleService bible;
        QCOMPARE(bible.parseReference(QStringLiteral("jn 3 17"), kCode).reference(),
                 QStringLiteral("John 3:16-18"));
    }

    void searchReturnsAParagraphOnce()
    {
        BibleService bible;
        const auto hits = bible.search(QStringLiteral("loved the world"), kCode);
        QCOMPARE(hits.size(), 1);
        QCOMPARE(hits[0].reference(), QStringLiteral("John 3:16-18"));
    }

    void searchKeepsRepeatedLinesApart()
    {
        BibleService bible;
        const auto hits = bible.search(QStringLiteral("praise the refrain"), kCode);
        QCOMPARE(hits.size(), 2);
    }
};

QTEST_GUILESS_MAIN(TestBibleParagraphs)
#include "test_bible_paragraphs.moc"
