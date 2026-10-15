// EasyWorship 2009 song import.
//
// EasyWorship 2007/2009 keep songs in a Paradox table (Songs.DB) with the
// lyrics in its memo file (Songs.MB). Moving such a library into EasyWorship 7
// can leave the lyrics behind, so Crater reads 2009 directly. These tests
// write a small library byte by byte, the way EasyWorship lays it out, and
// check the reader and the full import against it: a memo in its own block, a
// memo in a shared block, a stale pointer, Windows-1252 text and a missing
// memo file.
//
// Run via CTest: `ctest --test-dir <build-dir> -R easyworship_2009 --output-on-failure`

#include <QByteArray>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QObject>
#include <QSignalSpy>
#include <QStandardPaths>
#include <QString>
#include <QTemporaryDir>
#include <QTest>

#include "crater/Bootstrap.h"
#include "crater/EasyWorshipImporter.h"
#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Statement.h"
#include "import/ParadoxTable.h"

namespace {

struct FieldSpec { const char* name; int type; int size; };

// The six fields the importer reads, in a realistic order. 0x01 is alpha,
// 0x0C memo (10-byte .MB pointer at the end, inline copy before it).
const FieldSpec kFields[] = {
    { "Title", 0x01, 50 }, { "Author", 0x01, 50 }, { "Copyright", 0x01, 100 },
    { "Administrator", 0x01, 50 }, { "Words", 0x0C, 30 }, { "Song Number", 0x01, 10 },
};
constexpr int kFieldCount = 6;
constexpr int kRecordSize = 50 + 50 + 100 + 50 + 30 + 10;
constexpr int kWordsAt    = 50 + 50 + 100 + 50;

struct Song
{
    QByteArray title, author, copyright, admin, number;
    quint32 memoPointer = 0;   // .MB offset, low byte = slot
    quint32 memoLength  = 0;
};

void put16(QByteArray& b, int at, int v) { b[at] = char(v & 0xFF); b[at + 1] = char((v >> 8) & 0xFF); }
void put32(QByteArray& b, int at, quint32 v) { for (int i = 0; i < 4; ++i) b[at + i] = char((v >> (8 * i)) & 0xFF); }
void putText(QByteArray& b, int at, const QByteArray& s) { for (int i = 0; i < s.size(); ++i) b[at + i] = s.at(i); }

// Songs.DB: a 0x800 header and one 1 KB data block holding every record.
QByteArray buildTable(const QList<Song>& songs)
{
    QByteArray db(0x800 + 1024, '\0');
    put16(db, 0, kRecordSize);
    put16(db, 2, 0x800);
    db[5] = 1;                          // block size in KB
    put32(db, 6, quint32(songs.size()));
    put16(db, 33, kFieldCount);
    int at = 120;
    for (const FieldSpec& f : kFields) { db[at++] = char(f.type); db[at++] = char(f.size); }
    at += 4 + 4 * kFieldCount + 261;    // table-name pointer, name pointers, table name
    for (const FieldSpec& f : kFields) { putText(db, at, f.name); at += int(qstrlen(f.name)) + 1; }

    const int block = 0x800;
    put16(db, block, 0);                                     // no next block
    put16(db, block + 4, (int(songs.size()) - 1) * kRecordSize);
    for (int r = 0; r < songs.size(); ++r) {
        const Song& s = songs.at(r);
        const int rec = block + 6 + r * kRecordSize;
        putText(db, rec, s.title);
        putText(db, rec + 50, s.author);
        putText(db, rec + 100, s.copyright);
        putText(db, rec + 200, s.admin);
        put32(db, rec + kWordsAt + 30 - 10, s.memoPointer);
        put32(db, rec + kWordsAt + 30 - 6, s.memoLength);
        putText(db, rec + kWordsAt + 30, s.number);
    }
    return db;
}

const QByteArray kRtfOwn =
    "{\\rtf1\\ansi{\\fonttbl{\\f0 Arial;}}Verse 1\\par Amazing grace\\par\\par "
    "Chorus\\par How sweet the sound\\par}";
const QByteArray kRtfShared =
    "{\\rtf1\\ansi Verse 1\\par Caf\\'e9 hymn\\par}";

// Songs.MB: a type-2 block at 0x1000 holding one memo, a type-3 block at
// 0x2000 sharing out slots, and a free (type-4) block at 0x3000.
QByteArray buildMemo()
{
    QByteArray mb(0x4000, '\0');
    mb[0x1000] = 2;
    putText(mb, 0x1000 + 9, kRtfOwn);
    mb[0x2000] = 3;
    mb[0x2000 + 12 + 5 * 1] = char(0x10);     // slot 1 starts 16 * 16 bytes in
    putText(mb, 0x2000 + 0x100, kRtfShared);
    mb[0x3000] = 4;
    return mb;
}

QList<Song> sampleSongs()
{
    Song own{ "Amazing Grace", "John Newton", "Public Domain", "", "22025",
              0x1000, quint32(kRtfOwn.size()) };
    Song shared{ "Caf\xe9 Song", "", "", "Integrity Music", "",
                 0x2000 | 1, quint32(kRtfShared.size()) };
    Song stale{ "Stale Pointer", "", "", "", "", 0x3000, 40 };
    return { own, shared, stale };
}

bool writeFile(const QString& path, const QByteArray& data)
{
    QFile f(path);
    return f.open(QIODevice::WriteOnly) && f.write(data) == data.size();
}

}  // namespace

class TestEasyWorship2009 : public QObject
{
    Q_OBJECT

private:
    QString        m_dataDir;
    QTemporaryDir  m_lib;
    QString        m_dbPath;

private slots:
    void initTestCase()
    {
        QStandardPaths::setTestModeEnabled(true);
        m_dataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        QVERIFY(!m_dataDir.isEmpty());
        QDir(m_dataDir).removeRecursively();
        QDir().mkpath(m_dataDir);
        crater::runAllMigrations();

        QVERIFY(m_lib.isValid());
        m_dbPath = m_lib.filePath(QStringLiteral("Songs.DB"));
        QVERIFY(writeFile(m_dbPath, buildTable(sampleSongs())));
        QVERIFY(writeFile(m_lib.filePath(QStringLiteral("Songs.MB")), buildMemo()));
    }

    void cleanupTestCase()
    {
        QDir(m_dataDir).removeRecursively();
    }

    void readsFieldsAndBothMemoKinds()
    {
        QVERIFY(crater::paradox::Table::looksLikeTable(m_dbPath));
        QString err;
        const auto t = crater::paradox::Table::open(m_dbPath, &err);
        QVERIFY2(t.has_value(), qPrintable(err));
        QCOMPARE(t->recordCount(), 3);

        const int title = t->fieldIndex(QStringLiteral("title"));   // case-insensitive
        const int words = t->fieldIndex(QStringLiteral("Words"));
        QVERIFY(title >= 0 && words >= 0);
        QCOMPARE(t->fieldIndex(QStringLiteral("Not A Field")), -1);

        QCOMPARE(t->text(0, title), QStringLiteral("Amazing Grace"));
        QCOMPARE(t->text(1, title), QStringLiteral("Caf\u00e9 Song"));   // Windows-1252
        QCOMPARE(t->memo(0, words), kRtfOwn);      // its own block
        QCOMPARE(t->memo(1, words), kRtfShared);   // a shared block
        QVERIFY(t->memo(2, words).isEmpty());      // points at a free block
        QVERIFY(t->text(0, words).isEmpty());      // not an alpha field
    }

    void sqliteFileIsNotATable()
    {
        QVERIFY(!crater::paradox::Table::looksLikeTable(crater::db::DbPaths::songsDbPath()));
    }

    void missingMemoFileIsReported()
    {
        QTemporaryDir dir;
        const QString db = dir.filePath(QStringLiteral("Songs.DB"));
        QVERIFY(writeFile(db, buildTable(sampleSongs())));
        QString err;
        QVERIFY(!crater::paradox::Table::open(db, &err).has_value());
        QVERIFY2(err.contains(QStringLiteral("Songs.MB")), qPrintable(err));
    }

    void importsTheLibrary()
    {
        crater::EasyWorshipImporter importer;

        // Songs.MB selected alongside Songs.DB must not get in the way.
        const QStringList picked{ m_lib.filePath(QStringLiteral("Songs.MB")), m_dbPath };
        QSignalSpy analyzed(&importer, &crater::EasyWorshipImporter::analyzed);
        QSignalSpy failed(&importer, &crater::EasyWorshipImporter::failed);
        importer.analyze(picked);
        QTRY_COMPARE_WITH_TIMEOUT(analyzed.size() + failed.size(), 1, 10000);
        QVERIFY2(failed.isEmpty(), failed.isEmpty() ? "" : qPrintable(failed.first().first().toString()));
        QCOMPARE(analyzed.first().at(0).toInt(), 3);   // total
        QCOMPARE(analyzed.first().at(1).toInt(), 0);   // duplicates

        QSignalSpy completed(&importer, &crater::EasyWorshipImporter::completed);
        importer.run(picked, true);
        QTRY_COMPARE_WITH_TIMEOUT(completed.size() + failed.size(), 1, 10000);
        QVERIFY(failed.isEmpty());
        QCOMPARE(completed.first().at(0).toInt(), 3);

        crater::db::Connection c(crater::db::DbPaths::songsDbPath(), crater::db::OpenMode::ReadOnly);
        auto song = c.prepare(QStringLiteral(
            "SELECT id, author, copyright, ccli FROM songs WHERE title = ?"));
        song.bind(1, QStringLiteral("Amazing Grace"));
        QVERIFY(song.step());
        const qint64 id = song.columnInt64(0);
        QCOMPARE(song.columnText(1), QStringLiteral("John Newton"));
        QCOMPARE(song.columnText(2), QStringLiteral("Public Domain"));
        QCOMPARE(song.columnText(3), QStringLiteral("22025"));

        auto sections = c.prepare(QStringLiteral(
            "SELECT label, kind, lines_json FROM song_sections WHERE song_id = ? ORDER BY sort_order"));
        sections.bind(1, id);
        QVERIFY(sections.step());
        QCOMPARE(sections.columnText(0), QStringLiteral("Verse 1"));
        QCOMPARE(sections.columnText(2), QStringLiteral("[\"Amazing grace\"]"));
        QVERIFY(sections.step());
        QCOMPARE(sections.columnText(1), QStringLiteral("chorus"));
        QCOMPARE(sections.columnText(2), QStringLiteral("[\"How sweet the sound\"]"));
        QVERIFY(!sections.step());

        // The administrator has no field of its own, so it joins copyright.
        song.reset();
        song.bind(1, QStringLiteral("Caf\u00e9 Song"));
        QVERIFY(song.step());
        QCOMPARE(song.columnText(2), QStringLiteral("Administered by Integrity Music"));

        // Importing again with skip-duplicates on adds nothing.
        QSignalSpy again(&importer, &crater::EasyWorshipImporter::completed);
        importer.run(picked, true);
        QTRY_COMPARE_WITH_TIMEOUT(again.size(), 1, 10000);
        QCOMPARE(again.first().at(0).toInt(), 0);
        QCOMPARE(again.first().at(1).toInt(), 3);
    }
};

int main(int argc, char** argv)
{
    QGuiApplication app(argc, argv);
    TestEasyWorship2009 tc;
    return QTest::qExec(&tc, argc, argv);
}

#include "test_easyworship_2009.moc"
