// BibleService verse cache and row index.
//
// A translation switch used to re-read a whole Bible and then walk it in
// QML, a visible freeze on the projector. BibleService now caches the
// verse list per translation and answers row lookups from an index. These
// tests pin down the two things that can quietly go wrong: a lookup that
// lands on the wrong row, and a cache that holds more (memory) or less
// (speed) than the operator asked for.
//
// Cache hits are observed by editing the database behind the service's
// back: a cached translation keeps its old text, a reloaded one shows the
// edit.

#include <QDir>
#include <QObject>
#include <QSignalSpy>
#include <QStandardPaths>
#include <QString>
#include <QTest>

#include "crater/BibleService.h"
#include "crater/Bootstrap.h"

#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Statement.h"

using crater::BibleService;

class TestBibleCache : public QObject
{
    Q_OBJECT

private:
    QString m_dataDir;
    const QStringList m_codes{QStringLiteral("T1"), QStringLiteral("T2"), QStringLiteral("T3"),
                              QStringLiteral("T4"), QStringLiteral("T5")};

    // Two books, three verses, text tagged with the translation code.
    void seed()
    {
        crater::db::Connection conn(crater::db::DbPaths::biblesDbPath());
        for (const QString& code : m_codes) {
            conn.prepare(u"INSERT INTO translations (code, name) VALUES (?, ?)")
                .bind(1, code).bind(2, code).step();
            const qint64 tid = conn.lastInsertRowId();
            auto book = [&](const QString& name, const QString& abbrev, const QString& testament, int number) {
                conn.prepare(u"INSERT INTO books (translation_id, name, abbrev, testament, book_number) "
                             u"VALUES (?, ?, ?, ?, ?)")
                    .bind(1, tid).bind(2, name).bind(3, abbrev).bind(4, testament).bind(5, number).step();
                return conn.lastInsertRowId();
            };
            // John inserted first so row order has to come from book_number.
            const qint64 john = book(QStringLiteral("John"), QStringLiteral("Jn"), QStringLiteral("NT"), 43);
            const qint64 gen  = book(QStringLiteral("Genesis"), QStringLiteral("Gen"), QStringLiteral("OT"), 1);
            auto verse = [&](qint64 bookId, int chapter, int number) {
                conn.prepare(u"INSERT INTO verses (translation_id, book_id, chapter, verse, text) "
                             u"VALUES (?, ?, ?, ?, ?)")
                    .bind(1, tid).bind(2, bookId).bind(3, chapter).bind(4, number)
                    .bind(5, QStringLiteral("%1 original").arg(code)).step();
            };
            verse(john, 3, 16);
            verse(gen, 1, 2);
            verse(gen, 1, 1);
        }
    }

    // Edit every verse of one translation without going through the service.
    void rewrite(const QString& code, const QString& text)
    {
        crater::db::Connection conn(crater::db::DbPaths::biblesDbPath());
        conn.prepare(u"UPDATE verses SET text = ? WHERE translation_id = "
                     u"(SELECT id FROM translations WHERE code = ?)")
            .bind(1, text).bind(2, code).step();
    }

    static QString firstText(BibleService& bible, const QString& code)
    {
        const auto verses = bible.allVerses(code);
        return verses.isEmpty() ? QString() : verses.first().text;
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
    }

    // Each test starts from the seeded text.
    void init()
    {
        for (const QString& code : m_codes) rewrite(code, code + QStringLiteral(" original"));
    }

    void cleanupTestCase()
    {
        QDir(m_dataDir).removeRecursively();
    }

    void allVersesIsCanonicalOrder()
    {
        BibleService bible;
        const auto verses = bible.allVerses(QStringLiteral("T1"));
        QCOMPARE(verses.size(), 3);
        QCOMPARE(verses[0].book, QStringLiteral("Genesis"));
        QCOMPARE(verses[0].verse, 1);
        QCOMPARE(verses[1].verse, 2);
        QCOMPARE(verses[2].book, QStringLiteral("John"));
    }

    void verseIndexFindsRows()
    {
        BibleService bible;
        QCOMPARE(bible.verseIndex(QStringLiteral("T1"), QStringLiteral("Genesis"), 1, 1), 0);
        QCOMPARE(bible.verseIndex(QStringLiteral("T1"), QStringLiteral("Genesis"), 1, 2), 1);
        // Book names from the parser and from schedule items vary in case.
        QCOMPARE(bible.verseIndex(QStringLiteral("T1"), QStringLiteral("john"), 3, 16), 2);
        QCOMPARE(bible.verseIndex(QStringLiteral("T1"), QStringLiteral("JOHN"), 3, 16), 2);
    }

    void verseIndexMisses()
    {
        BibleService bible;
        QCOMPARE(bible.verseIndex(QStringLiteral("T1"), QStringLiteral("John"), 3, 17), -1);
        QCOMPARE(bible.verseIndex(QStringLiteral("T1"), QStringLiteral("John"), 4, 16), -1);
        QCOMPARE(bible.verseIndex(QStringLiteral("T1"), QStringLiteral("Exodus"), 1, 1), -1);
        QCOMPARE(bible.verseIndex(QStringLiteral("NOPE"), QStringLiteral("John"), 3, 16), -1);
    }

    void recentTranslationsStayCached()
    {
        BibleService bible;
        for (const QString& code : {QStringLiteral("T1"), QStringLiteral("T2"), QStringLiteral("T3")})
            bible.allVerses(code);
        rewrite(QStringLiteral("T1"), QStringLiteral("edited"));
        QCOMPARE(firstText(bible, QStringLiteral("T1")), QStringLiteral("T1 original"));
    }

    void olderTranslationsAreDropped()
    {
        BibleService bible;
        for (const QString& code : {QStringLiteral("T1"), QStringLiteral("T2"),
                                    QStringLiteral("T3"), QStringLiteral("T4")})
            bible.allVerses(code);
        rewrite(QStringLiteral("T1"), QStringLiteral("edited"));
        QCOMPARE(firstText(bible, QStringLiteral("T1")), QStringLiteral("edited"));
        // The row index goes with the verses and is rebuilt on demand.
        QCOMPARE(bible.verseIndex(QStringLiteral("T1"), QStringLiteral("John"), 3, 16), 2);
    }

    void preloadKeepsEverythingUntilSwitchedOff()
    {
        BibleService bible;
        bible.setPreloadAll(true);
        // Let the worker land so its reads can't race the edits below.
        QTest::qWait(300);
        rewrite(QStringLiteral("T1"), QStringLiteral("edited"));
        rewrite(QStringLiteral("T5"), QStringLiteral("edited"));
        // Loaded by the worker, never asked for, still the original text.
        QCOMPARE(firstText(bible, QStringLiteral("T5")), QStringLiteral("T5 original"));
        for (const QString& code : {QStringLiteral("T2"), QStringLiteral("T3"), QStringLiteral("T4")})
            bible.allVerses(code);
        QCOMPARE(firstText(bible, QStringLiteral("T1")), QStringLiteral("T1 original"));

        // Most recent first: T1, T4, T3 stay, T2 and T5 go.
        bible.setPreloadAll(false);
        rewrite(QStringLiteral("T1"), QStringLiteral("edited again"));
        QCOMPARE(firstText(bible, QStringLiteral("T1")), QStringLiteral("T1 original"));
        QCOMPARE(firstText(bible, QStringLiteral("T5")), QStringLiteral("edited"));
    }

    // ── Translation order ───────────────────────────────────────────────

    static QStringList codesOf(BibleService& bible)
    {
        QStringList out;
        for (const auto& t : bible.translations()) out << t.code;
        return out;
    }

    // The library is shared; a profile only chooses its view of it.
    void viewOrdersAndHidesWithoutTouchingTheLibrary()
    {
        BibleService bible;
        QSignalSpy changed(&bible, &BibleService::translationsChanged);
        const int rev = bible.translationsRevision();

        // T9 is not installed and T3 is listed twice: both are ignored.
        // Unlisted codes follow in the library's order. Hidden is matched
        // case-insensitively.
        bible.setView({ QStringLiteral("T3"), QStringLiteral("T9"),
                        QStringLiteral("T1"), QStringLiteral("T3") },
                      { QStringLiteral("t2") });
        QCOMPARE(codesOf(bible), (QStringList{ QStringLiteral("T3"), QStringLiteral("T1"),
                                               QStringLiteral("T4"), QStringLiteral("T5") }));
        QCOMPARE(changed.count(), 1);
        QCOMPARE(bible.translationsRevision(), rev + 1);

        // allTranslations keeps the hidden one, in view order, flagged.
        const QVariantList all = bible.allTranslations();
        QCOMPARE(all.size(), 5);
        QCOMPARE(all.at(0).toMap().value(QStringLiteral("code")).toString(), QStringLiteral("T3"));
        QCOMPARE(all.at(2).toMap().value(QStringLiteral("code")).toString(), QStringLiteral("T2"));
        QVERIFY(all.at(2).toMap().value(QStringLiteral("hidden")).toBool());

        // Same view again: no signal.
        bible.setView({ QStringLiteral("T3"), QStringLiteral("T9"),
                        QStringLiteral("T1"), QStringLiteral("T3") },
                      { QStringLiteral("T2") });
        QCOMPARE(changed.count(), 1);

        // Hiding everything still leaves something to read.
        bible.setView({}, m_codes);
        QCOMPARE(codesOf(bible), m_codes);

        // A fresh service (another profile) sees the library untouched.
        BibleService other;
        QCOMPARE(codesOf(other), m_codes);
    }
};

QTEST_GUILESS_MAIN(TestBibleCache)

#include "test_bible_cache.moc"
