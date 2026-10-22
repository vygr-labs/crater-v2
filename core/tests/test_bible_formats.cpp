// Bible file import: Zefania XML, OpenSong, OSIS, USFM and USX.
//
// Each reader gets a small file with the awkward parts real files have
// (footnotes, headings, Strong's markup, combined verses, books outside the
// 66, milestone verses), and must come out with the same plain verse text.
// Then a file goes through BibleImporter into the library and is read back
// through BibleService the way the Scripture tab reads it, searched, and
// removed again.

#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QObject>
#include <QSet>
#include <QSignalSpy>
#include <QStandardPaths>
#include <QString>
#include <QTemporaryDir>
#include <QTest>

#include "crater/BibleImporter.h"
#include "crater/BibleService.h"
#include "crater/Bootstrap.h"
#include "crater/ElectronDataImporter.h"

#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Statement.h"
#include "import/BibleFormats.h"

using crater::import::ParsedBible;
using crater::import::ParsedVerse;
using crater::import::parseBibleFiles;

namespace {

const char* kZefania = R"(<?xml version="1.0" encoding="utf-8"?>
<XMLBIBLE biblename="Test Zefania" type="x-bible">
  <INFORMATION>
    <title>Zefania Test Bible</title>
    <identifier>ZTB</identifier>
    <language>ENG</language>
  </INFORMATION>
  <BIBLEBOOK bnumber="1" bname="Genesis" bsname="Gen">
    <CHAPTER cnumber="1">
      <VERS vnumber="1">In the beginning <NOTE>a translator's note</NOTE>God created<BR/>the heaven.</VERS>
      <VERS vnumber="2-3">Two verses as one.</VERS>
    </CHAPTER>
  </BIBLEBOOK>
  <BIBLEBOOK bnumber="67" bname="Tobit">
    <CHAPTER cnumber="1"><VERS vnumber="1">Tobit's words.</VERS></CHAPTER>
  </BIBLEBOOK>
  <BIBLEBOOK bnumber="43" bname="John">
    <CHAPTER cnumber="3"><VERS vnumber="16">For God so <gr str="25">loved</gr> the world.</VERS></CHAPTER>
  </BIBLEBOOK>
</XMLBIBLE>
)";

const char* kOpenSong = R"(<?xml version="1.0" encoding="UTF-8"?>
<bible>
  <b n="Genesis"><c n="1"><v n="1">In the beginning</v><v n="2">And the earth was without form</v></c></b>
  <b n="John"><c n="3"><v n="16">For God so loved the world</v></c></b>
</bible>
)";

const char* kOsis = R"(<?xml version="1.0" encoding="UTF-8"?>
<osis xmlns="http://www.bibletechnologies.net/2003/OSIS/namespace">
<osisText osisIDWork="TOSIS" xml:lang="yo">
<header><work osisWork="TOSIS"><title>OSIS Test Bible</title></work></header>
<div type="book" osisID="Gen">
  <chapter osisID="Gen.1">
    <title>The Creation</title>
    <verse osisID="Gen.1.1">In the <w lemma="strong:H7225">beginning</w><note type="study">note</note> God</verse>
    <verse osisID="Gen.1.2 Gen.1.3">Two verses as one.</verse>
  </chapter>
</div>
<div type="book" osisID="John">
  <chapter sID="John.3"/>
  <p><verse sID="John.3.16" osisID="John.3.16"/>For God<lb/>so loved<verse eID="John.3.16"/></p>
  <chapter eID="John.3"/>
</div>
<div type="book" osisID="Tob">
  <chapter osisID="Tob.1"><verse osisID="Tob.1.1">Tobit's words.</verse></chapter>
</div>
</osisText>
</osis>
)";

const char* kUsfmGenesis = R"(\id GEN Test Bible
\h Genesis
\toc1 The First Book of Moses
\mt1 Genesis
\c 1
\s1 The Creation
\p
\v 1 In the beginning\f + \fr 1:1 \ft A footnote.\f* God created
\q1 the heavens.
\v 2-3 Combined \it italic\it* text.
)";

const char* kUsfmJohn = R"(\id JHN
\c 3
\p
\v 16 For God so \w loved|strong="G25"\w* the \wj world\wj*.
\s1 A heading between verses
\p
\v 17 Not to \x - \xo 3:17 \xt Ref\x* condemn.
)";

const char* kUsfmTobit = "\\id TOB\n\\c 1\n\\p\n\\v 1 Tobit's words.\n";

const char* kUsx = R"(<?xml version="1.0" encoding="utf-8"?>
<usx version="3.0">
  <book code="JHN" style="id">Test</book>
  <para style="h">John</para>
  <chapter number="3" style="c" sid="JHN 3"/>
  <para style="p"><verse number="16" style="v" sid="JHN 3:16"/>For God so <char style="w" strong="G25">loved</char> the world<note caller="+" style="f"><char style="ft">A footnote.</char></note>.<verse eid="JHN 3:16"/></para>
  <para style="s1">A heading between verses</para>
  <para style="q1"><verse number="17" style="v"/>Not to condemn</para>
  <chapter eid="JHN 3"/>
</usx>
)";

// Twenty-seven New Testament books named in Yoruba.
QByteArray yorubaNewTestament()
{
    const QStringList names = {
        "Matiu", "Marku", "Luku", "Johanu", "Ise Awon Aposteli", "Romu", "1 Korinti",
        "2 Korinti", "Galatia", "Efesu", "Filippi", "Kolosse", "1 Tessalonika", "2 Tessalonika",
        "1 Timoteu", "2 Timoteu", "Titu", "Filemoni", "Heberu", "Jakobu", "1 Peteru", "2 Peteru",
        "1 Johanu", "2 Johanu", "3 Johanu", "Juda", "Ifihan",
    };
    QByteArray xml = "<bible>";
    for (const QString& n : names)
        xml += "<b n=\"" + n.toUtf8() + "\"><c n=\"3\"><v n=\"16\">" + n.toUtf8() + " ese</v></c></b>";
    return xml + "</bible>";
}

const ParsedVerse* find(const ParsedBible& bible, int book, int chapter, int verse)
{
    for (const ParsedVerse& v : bible.verses)
        if (v.book == book && v.chapter == chapter && v.verse == verse) return &v;
    return nullptr;
}

}  // namespace

class TestBibleFormats : public QObject
{
    Q_OBJECT

private:
    QTemporaryDir m_files;
    QString m_dataDir;

    QString write(const QString& name, const QByteArray& bytes)
    {
        const QString path = m_files.filePath(name);
        QFile f(path);
        if (!f.open(QIODevice::WriteOnly)) return {};
        f.write(bytes);
        return path;
    }

    static void expectVerse(const ParsedBible& bible, int book, int chapter, int verse,
                            const QString& text, int verseEnd = 0)
    {
        const ParsedVerse* v = find(bible, book, chapter, verse);
        QVERIFY2(v, qPrintable(QStringLiteral("no %1 %2:%3").arg(book).arg(chapter).arg(verse)));
        QCOMPARE(v->text, text);
        QCOMPARE(v->verseEnd, verseEnd ? verseEnd : verse);
    }

private slots:
    void initTestCase()
    {
        QVERIFY(m_files.isValid());
        QStandardPaths::setTestModeEnabled(true);
        m_dataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        QVERIFY(!m_dataDir.isEmpty());
        QDir(m_dataDir).removeRecursively();
        crater::runAllMigrations();
    }

    void cleanupTestCase()
    {
        QDir(m_dataDir).removeRecursively();
    }

    void zefania()
    {
        const ParsedBible b = parseBibleFiles({ write("zefania.xml", kZefania) });
        QVERIFY2(b.error.isEmpty(), qPrintable(b.error));
        QCOMPARE(b.format, QStringLiteral("Zefania XML"));
        QCOMPARE(b.name, QStringLiteral("Zefania Test Bible"));
        QCOMPARE(b.code, QStringLiteral("ZTB"));
        QCOMPARE(b.language, QStringLiteral("ENG"));
        QCOMPARE(b.verses.size(), 3);
        expectVerse(b, 1, 1, 1, QStringLiteral("In the beginning God created the heaven."));
        expectVerse(b, 1, 1, 2, QStringLiteral("Two verses as one."), 3);
        expectVerse(b, 43, 3, 16, QStringLiteral("For God so loved the world."));
        QCOMPARE(b.skippedBooks, QStringList{ QStringLiteral("Tobit") });
    }

    void openSongEnglish()
    {
        const ParsedBible b = parseBibleFiles({ write("opensong.xmm", kOpenSong) });
        QVERIFY2(b.error.isEmpty(), qPrintable(b.error));
        QCOMPARE(b.format, QStringLiteral("OpenSong"));
        QCOMPARE(b.name, QStringLiteral("opensong"));   // OpenSong names nothing; the file does
        QVERIFY(!b.booksByPosition);
        QCOMPARE(b.verses.size(), 3);
        expectVerse(b, 1, 1, 2, QStringLiteral("And the earth was without form"));
        expectVerse(b, 43, 3, 16, QStringLiteral("For God so loved the world"));
    }

    // Book names Crater can't read still land on the right books when the
    // file holds a whole testament.
    void openSongOtherLanguage()
    {
        const ParsedBible b = parseBibleFiles({ write("yoruba.xmm", yorubaNewTestament()) });
        QVERIFY2(b.error.isEmpty(), qPrintable(b.error));
        QCOMPARE(b.verses.size(), 27);
        expectVerse(b, 40, 3, 16, QStringLiteral("Matiu ese"));
        expectVerse(b, 43, 3, 16, QStringLiteral("Johanu ese"));
        expectVerse(b, 62, 3, 16, QStringLiteral("1 Johanu ese"));
        expectVerse(b, 66, 3, 16, QStringLiteral("Ifihan ese"));
    }

    void openSongUnknownPartial()
    {
        const ParsedBible b = parseBibleFiles({ write("partial.xmm",
            "<bible><b n=\"Qwxzv\"><c n=\"1\"><v n=\"1\">x</v></c></b>"
            "<b n=\"Zqxjk\"><c n=\"1\"><v n=\"1\">y</v></c></b></bible>") });
        QVERIFY(!b.error.isEmpty());
    }

    void osis()
    {
        const ParsedBible b = parseBibleFiles({ write("osis.xml", kOsis) });
        QVERIFY2(b.error.isEmpty(), qPrintable(b.error));
        QCOMPARE(b.format, QStringLiteral("OSIS"));
        QCOMPARE(b.name, QStringLiteral("OSIS Test Bible"));
        QCOMPARE(b.code, QStringLiteral("TOSIS"));
        QCOMPARE(b.language, QStringLiteral("yo"));
        QCOMPARE(b.verses.size(), 3);
        expectVerse(b, 1, 1, 1, QStringLiteral("In the beginning God"));
        expectVerse(b, 1, 1, 2, QStringLiteral("Two verses as one."), 3);
        expectVerse(b, 43, 3, 16, QStringLiteral("For God so loved"));
        QCOMPARE(b.skippedBooks, QStringList{ QStringLiteral("Tob") });
    }

    void usfm()
    {
        const QString gen = write("01-GEN.usfm", kUsfmGenesis);
        const QString jhn = write("44-JHN.usfm", kUsfmJohn);
        const QString tob = write("68-TOB.usfm", kUsfmTobit);
        // eBible's folders carry a copyright page beside the books.
        const QString copr = write("copr.htm", "<html><body>Public domain</body></html>");
        const ParsedBible b = parseBibleFiles({ gen, jhn, tob, copr });
        QVERIFY2(b.error.isEmpty(), qPrintable(b.error));
        QCOMPARE(b.format, QStringLiteral("USFM"));
        QCOMPARE(b.verses.size(), 4);
        expectVerse(b, 1, 1, 1, QStringLiteral("In the beginning God created the heavens."));
        expectVerse(b, 1, 1, 2, QStringLiteral("Combined italic text."), 3);
        expectVerse(b, 43, 3, 16, QStringLiteral("For God so loved the world."));
        expectVerse(b, 43, 3, 17, QStringLiteral("Not to condemn."));
        QCOMPARE(b.skippedBooks, QStringList{ QStringLiteral("TOB") });
        QCOMPARE(b.ignoredFiles, QStringList{ QStringLiteral("copr.htm") });
        // Named after the folder the book files are in.
        QCOMPARE(b.name, QDir(m_files.path()).dirName());
    }

    void usx()
    {
        const ParsedBible b = parseBibleFiles({ write("JHN.usx", kUsx) });
        QVERIFY2(b.error.isEmpty(), qPrintable(b.error));
        QCOMPARE(b.format, QStringLiteral("USX"));
        QCOMPARE(b.verses.size(), 2);
        expectVerse(b, 43, 3, 16, QStringLiteral("For God so loved the world."));
        expectVerse(b, 43, 3, 17, QStringLiteral("Not to condemn"));
    }

    void refusals()
    {
        QVERIFY(!parseBibleFiles({ write("notes.txt", "Just some notes, not a Bible.") }).error.isEmpty());
        QVERIFY(!parseBibleFiles({}).error.isEmpty());
        // XML formats are one file.
        QVERIFY(!parseBibleFiles({ write("a.xml", kZefania), write("b.xml", kZefania) }).error.isEmpty());
        // One Bible is one format.
        QVERIFY(!parseBibleFiles({ write("c.usfm", kUsfmJohn), write("d.usx", kUsx) }).error.isEmpty());
        // A well-formed file with nothing from the 66 books.
        QVERIFY(!parseBibleFiles({ write("tobit.usfm", kUsfmTobit) }).error.isEmpty());
    }

    // Real Bibles, when CRATER_BIBLE_SAMPLES names a folder of them: each
    // file there is one Bible, and each folder one Bible in book files.
    // Prints what came out so a reader's mistakes show in the numbers.
    void realFiles()
    {
        const QString root = qEnvironmentVariable("CRATER_BIBLE_SAMPLES");
        if (root.isEmpty()) QSKIP("Set CRATER_BIBLE_SAMPLES to a folder of Bible files");
        const QDir dir(root);
        for (const QFileInfo& entry : dir.entryInfoList(QDir::Files | QDir::Dirs | QDir::NoDotAndDotDot)) {
            QStringList files;
            if (entry.isDir()) {
                for (const QFileInfo& f : QDir(entry.filePath()).entryInfoList(QDir::Files))
                    files << f.filePath();
            } else {
                files << entry.filePath();
            }
            QElapsedTimer timer;
            timer.start();
            const ParsedBible b = parseBibleFiles(files);
            const auto text = [&b](int book, int chapter, int verse) {
                const ParsedVerse* v = find(b, book, chapter, verse);
                return v ? v->text.left(90) : QStringLiteral("(missing)");
            };
            QSet<int> books;
            for (const ParsedVerse& v : b.verses) books.insert(v.book);
            qInfo().noquote() << "\n" << entry.fileName() << "|" << b.format << "|" << b.name << "|"
                              << b.code << "|" << b.language << "|" << b.verses.size() << "verses"
                              << books.size() << "books" << timer.elapsed() << "ms"
                              << (b.booksByPosition ? "by position" : "")
                              << "\n   error:" << b.error
                              << "\n   skipped:" << b.skippedBooks.join(QStringLiteral(", "))
                              << "\n   Gen 1:1" << text(1, 1, 1)
                              << "\n   Ps 23:1" << text(19, 23, 1)
                              << "\n   John 3:16" << text(43, 3, 16)
                              << "\n   Rev 22:21" << text(66, 22, 21);
        }
    }

    // Into the library and back out the way the Scripture tab reads it.
    void importReadSearchRemove()
    {
        crater::BibleImporter importer;
        crater::BibleService bible;
        QObject::connect(&importer, &crater::BibleImporter::completed, &bible,
                         [&bible](const QString& code) { bible.libraryChanged(code); });
        QObject::connect(&importer, &crater::BibleImporter::removed, &bible,
                         [&bible](const QString& code) { bible.libraryChanged(code); });
        const QStringList files = { write("import.xml", kZefania) };

        QSignalSpy analyzed(&importer, &crater::BibleImporter::analyzed);
        QSignalSpy failed(&importer, &crater::BibleImporter::failed);
        importer.analyze(files);
        QTRY_COMPARE(analyzed.size() + failed.size(), 1);
        QCOMPARE(failed.size(), 0);
        const QVariantMap info = analyzed.first().first().toMap();
        QCOMPARE(info.value("code").toString(), QStringLiteral("ZTB"));
        QCOMPARE(info.value("books").toInt(), 2);
        QCOMPARE(info.value("verses").toInt(), 3);
        QCOMPARE(info.value("skippedBooks").toStringList(), QStringList{ QStringLiteral("Tobit") });

        // A dotted OSIS work name suggests its last part.
        analyzed.clear();
        importer.analyze({ write("dotted.osis.xml", QByteArray(kOsis).replace("\"TOSIS\"", "\"Bible.en.kjv\"")) });
        QTRY_COMPARE(analyzed.size() + failed.size(), 1);
        QCOMPARE(analyzed.first().first().toMap().value("code").toString(), QStringLiteral("KJV"));

        // A file that names no code: eBible's language-translation name
        // gives the translation part, several words give their initials.
        analyzed.clear();
        importer.analyze({ write("eng-dby_usfm.xmm", kOpenSong) });
        QTRY_COMPARE(analyzed.size() + failed.size(), 1);
        QCOMPARE(analyzed.first().first().toMap().value("name").toString(), QStringLiteral("eng-dby"));
        QCOMPARE(analyzed.first().first().toMap().value("code").toString(), QStringLiteral("DBY"));
        analyzed.clear();
        importer.analyze({ write("web.xml", QByteArray(kZefania).replace("<identifier>ZTB</identifier>", "")
                                                .replace("Zefania Test Bible", "World English Bible")) });
        QTRY_COMPARE(analyzed.size() + failed.size(), 1);
        QCOMPARE(analyzed.first().first().toMap().value("code").toString(), QStringLiteral("WEB"));

        QVERIFY(importer.codeProblem(QStringLiteral("NEW")).isEmpty());
        QVERIFY(!importer.codeProblem(QStringLiteral("two words")).isEmpty());
        QVERIFY(!importer.codeProblem(QString()).isEmpty());

        const int revision = bible.translationsRevision();
        QSignalSpy completed(&importer, &crater::BibleImporter::completed);
        importer.run(files, QStringLiteral("ztb"), QStringLiteral("Zefania Test Bible"));
        QTRY_COMPARE(completed.size() + failed.size(), 1);
        QCOMPARE(failed.size(), 0);
        QCOMPARE(completed.first().at(0).toString(), QStringLiteral("ZTB"));
        QCOMPARE(completed.first().at(1).toInt(), 4);   // 2-3 is stored under both
        QVERIFY(bible.translationsRevision() > revision);

        bool listed = false;
        for (const crater::Translation& t : bible.translations()) listed |= t.code == u"ZTB";
        QVERIFY(listed);
        QCOMPARE(bible.books(QStringLiteral("ZTB")).size(), 2);
        QCOMPARE(bible.verse(QStringLiteral("ZTB"), QStringLiteral("Genesis"), 1, 1).text,
                 QStringLiteral("In the beginning God created the heaven."));
        // The combined verse is one row spanning both.
        const crater::Verse two = bible.verse(QStringLiteral("ZTB"), QStringLiteral("Genesis"), 1, 3);
        QCOMPARE(two.verse, 2);
        QCOMPARE(two.verseEnd, 3);
        QCOMPARE(bible.allVerses(QStringLiteral("ZTB")).size(), 3);
        QCOMPARE(bible.parseReference(QStringLiteral("jn 3:16"), QStringLiteral("ZTB")).text,
                 QStringLiteral("For God so loved the world."));
        QCOMPARE(bible.search(QStringLiteral("beginning"), QStringLiteral("ZTB")).size(), 1);

        // The code is taken now, whatever its case.
        QVERIFY(!importer.codeProblem(QStringLiteral("Ztb")).isEmpty());
        importer.run(files, QStringLiteral("ZTB"), QStringLiteral("Again"));
        QTRY_COMPARE(failed.size(), 1);

        if (crater::ElectronDataImporter::bundledBiblesPath().isEmpty())
            QSKIP("No bundled bibles.sqlite to tell shipped translations apart");
        QVERIFY(importer.isRemovable(QStringLiteral("ZTB")));
        QVERIFY(!importer.isRemovable(QStringLiteral("KJV")));
        QSignalSpy removed(&importer, &crater::BibleImporter::removed);
        importer.remove(QStringLiteral("ZTB"));
        QTRY_COMPARE(removed.size() + failed.size(), 2);
        QCOMPARE(removed.size(), 1);
        for (const crater::Translation& t : bible.translations()) QVERIFY(t.code != u"ZTB");
        QVERIFY(bible.allVerses(QStringLiteral("ZTB")).isEmpty());
        QCOMPARE(bible.search(QStringLiteral("beginning")).size(), 0);
        QVERIFY(importer.codeProblem(QStringLiteral("ZTB")).isEmpty());
        // Its search index rows go too, a moment later.
        const auto indexRows = [] {
            crater::db::Connection conn(crater::db::DbPaths::biblesDbPath());
            auto st = conn.prepare(u"SELECT count(*) FROM verses_fts");
            return st.step() ? st.columnInt(0) : -1;
        };
        QTRY_COMPARE(indexRows(), 0);
    }
};

QTEST_GUILESS_MAIN(TestBibleFormats)
#include "test_bible_formats.moc"
