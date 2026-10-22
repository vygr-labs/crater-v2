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
        QCOMPARE(b.skippedBooks, QStringList{ QStringLiteral("Tobit") });   // by name, not "Tob"
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
        QCOMPARE(b.skippedBooks, QStringList{ QStringLiteral("Tobit") });   // by name, not "TOB"
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

    // Book names in another script say nothing, and a fuzzy guess at a
    // short one (Иов, 诗篇) must not land it on Psalms or Revelation. A
    // whole Bible in such names goes by order.
    void openSongOtherScript()
    {
        QByteArray xml = "<bible>";
        for (int i = 1; i <= 66; ++i) {
            const QByteArray name = i == 18 ? QByteArray("Иов") : i == 19 ? QByteArray("诗篇")
                                  : "Книга " + QByteArray::number(i);
            xml += "<b n=\"" + name + "\"><c n=\"1\"><v n=\"1\">book " + QByteArray::number(i) + "</v></c></b>";
        }
        const ParsedBible b = parseBibleFiles({ write("russian.xmm", xml + "</bible>") });
        QVERIFY2(b.error.isEmpty(), qPrintable(b.error));
        QCOMPARE(b.verses.size(), 66);
        expectVerse(b, 1, 1, 1, QStringLiteral("book 1"));
        expectVerse(b, 18, 1, 1, QStringLiteral("book 18"));
        expectVerse(b, 66, 1, 1, QStringLiteral("book 66"));
    }

    // Books named by number, and Beblia's <book number> layout.
    void openSongNumbersAndBeblia()
    {
        const ParsedBible n = parseBibleFiles({ write("numbers.xmm",
            "<bible><b n=\"1\"><c n=\"1\"><v n=\"1\">Genesis one</v></c></b>"
            "<b n=\"43\"><c n=\"3\"><v n=\"16\">John three</v></c></b></bible>") });
        QVERIFY2(n.error.isEmpty(), qPrintable(n.error));
        expectVerse(n, 1, 1, 1, QStringLiteral("Genesis one"));
        expectVerse(n, 43, 3, 16, QStringLiteral("John three"));

        const ParsedBible b = parseBibleFiles({ write("beblia.xml",
            "<bible translation=\"Beblia Test\"><testament name=\"Old\">"
            "<book number=\"1\"><chapter number=\"1\"><verse number=\"1\">In the beginning</verse></chapter></book>"
            "</testament><testament name=\"New\">"
            "<book number=\"43\"><chapter number=\"3\"><verse number=\"16\">For God so loved</verse></chapter></book>"
            "</testament></bible>") });
        QVERIFY2(b.error.isEmpty(), qPrintable(b.error));
        QCOMPARE(b.name, QStringLiteral("Beblia Test"));
        expectVerse(b, 1, 1, 1, QStringLiteral("In the beginning"));
        expectVerse(b, 43, 3, 16, QStringLiteral("For God so loved"));
    }

    // A Zefania book with no number is matched by name, and a deuterocanon
    // name must not be taken for a canonical book it resembles.
    void zefaniaNamesOnly()
    {
        const ParsedBible b = parseBibleFiles({ write("names.xml",
            "<XMLBIBLE biblename=\"Names\">"
            "<BIBLEBOOK bname=\"Tobit\"><CHAPTER cnumber=\"1\"><VERS vnumber=\"1\">Tobit's words.</VERS></CHAPTER></BIBLEBOOK>"
            "<BIBLEBOOK bname=\"Obadiah\"><CHAPTER cnumber=\"1\"><VERS vnumber=\"1\">The vision of Obadiah.</VERS></CHAPTER></BIBLEBOOK>"
            "<BIBLEBOOK bname=\"Ecclesiasticus\"><CHAPTER cnumber=\"1\"><VERS vnumber=\"1\">All wisdom.</VERS></CHAPTER></BIBLEBOOK>"
            "</XMLBIBLE>") });
        QVERIFY2(b.error.isEmpty(), qPrintable(b.error));
        QCOMPARE(b.verses.size(), 1);
        expectVerse(b, 31, 1, 1, QStringLiteral("The vision of Obadiah."));
        QCOMPARE(b.skippedBooks, (QStringList{ QStringLiteral("Tobit"), QStringLiteral("Ecclesiasticus") }));
    }

    // A file that breaks partway is read up to the damage, and says so.
    void damagedXml()
    {
        QByteArray xml(kZefania);
        xml.replace("<BIBLEBOOK bnumber=\"43\"", "&nbsp;<BIBLEBOOK bnumber=\"43\"");
        const ParsedBible b = parseBibleFiles({ write("damaged.xml", xml) });
        QVERIFY2(b.error.isEmpty(), qPrintable(b.error));
        QVERIFY(find(b, 1, 1, 1));
        QVERIFY(!find(b, 43, 3, 16));
        QCOMPARE(b.warnings.size(), 1);
        QVERIFY(b.warnings.first().contains(QStringLiteral("damaged.xml")));
    }

    // USFM 3 milestones, Chinese words with no spaces between them, Psalm
    // 119's acrostic heading, an unclosed footnote, an en dash range, a
    // verse split in two.
    void usfmHarder()
    {
        const QByteArray usfm =
            "\\id GEN\n\\c 1\n\\p\n"
            "\\v 1 \\w \xe8\xb5\xb7\xe5\x88\x9d|strong=\"H7225\"\\w*\\w \xe7\xa5\x9e|strong=\"H430\"\\w*\n"
            "\\v 2 \\qt-s |who=\"God\"\\*Let there be light.\\qt-e\\* \\ts\\*\n"
            "\\v 3 The earth\\f + \\ft unclosed note\n"
            "\\v 4\xe2\x80\x93" "5 Two verses.\n"
            "\\id PSA\n\\c 119\n\\qa Aleph\n\\q1\n\\v 8 I will keep your statutes.\n\\qa Beth\n\\q1\n\\v 9 How can a young man\n"
            "\\c 120\n\\p\n\\v 1 Part one\n\\v 1b part two.\n";
        const ParsedBible b = parseBibleFiles({ write("harder.usfm", usfm) });
        QVERIFY2(b.error.isEmpty(), qPrintable(b.error));
        expectVerse(b, 1, 1, 1, QString::fromUtf8("\xe8\xb5\xb7\xe5\x88\x9d\xe7\xa5\x9e"));
        expectVerse(b, 1, 1, 2, QStringLiteral("Let there be light."));
        expectVerse(b, 1, 1, 3, QStringLiteral("The earth"));
        expectVerse(b, 1, 1, 4, QStringLiteral("Two verses."), 5);
        expectVerse(b, 19, 119, 8, QStringLiteral("I will keep your statutes."));
        expectVerse(b, 19, 119, 9, QStringLiteral("How can a young man"));
        expectVerse(b, 19, 120, 1, QStringLiteral("Part one part two."));
    }

    // Old 8-bit files are Windows-1252 (curly quotes at 0x93/0x94), and
    // USFM can be UTF-16.
    void encodings()
    {
        const ParsedBible cp = parseBibleFiles({ write("cp1252.usfm",
            "\\id JHN\n\\c 3\n\\p\n\\v 16 \x93" "For God so loved the world\x94.\n") });
        QVERIFY2(cp.error.isEmpty(), qPrintable(cp.error));
        expectVerse(cp, 43, 3, 16, QString::fromUtf8("\xe2\x80\x9c" "For God so loved the world" "\xe2\x80\x9d."));

        const QString text = QStringLiteral("\\id JHN\n\\c 3\n\\p\n\\v 16 For God so loved the world.\n");
        QByteArray utf16("\xff\xfe", 2);
        utf16.append(reinterpret_cast<const char*>(text.utf16()), text.size() * 2);
        const ParsedBible u = parseBibleFiles({ write("utf16.usfm", utf16) });
        QVERIFY2(u.error.isEmpty(), qPrintable(u.error));
        expectVerse(u, 43, 3, 16, QStringLiteral("For God so loved the world."));
    }

    // OSIS: a self-closing verse with no sID is a milestone, and a psalm's
    // canonical title inside its verse is part of it.
    void osisHarder()
    {
        const ParsedBible b = parseBibleFiles({ write("osis2.xml",
            "<osis><osisText osisIDWork=\"X\"><div type=\"book\" osisID=\"Ps\"><chapter osisID=\"Ps.3\">"
            "<verse osisID=\"Ps.3.1\"><title type=\"psalm\" canonical=\"true\">A psalm of David.</title>"
            "LORD, how they are increased</verse>"
            "<verse osisID=\"Ps.3.2\"/>Many there be<verse osisID=\"Ps.3.3\"/>But thou, O LORD"
            "</chapter></div></osisText></osis>") });
        QVERIFY2(b.error.isEmpty(), qPrintable(b.error));
        expectVerse(b, 19, 3, 1, QStringLiteral("A psalm of David. LORD, how they are increased"));
        expectVerse(b, 19, 3, 2, QStringLiteral("Many there be"));
        expectVerse(b, 19, 3, 3, QStringLiteral("But thou, O LORD"));
    }

    // Into the library and back out the way the Scripture tab reads it.
    void importReadSearchRemove()
    {
        crater::BibleImporter importer;
        crater::BibleService bible;
        QObject::connect(&importer, &crater::BibleImporter::completed, &bible,
                         [&bible](int, const QString& code) { bible.libraryChanged(code); });
        QObject::connect(&importer, &crater::BibleImporter::removed, &bible,
                         [&bible](int, const QString& code) { bible.libraryChanged(code); });
        const QStringList files = { write("import.xml", kZefania) };

        QSignalSpy analyzed(&importer, &crater::BibleImporter::analyzed);
        QSignalSpy failed(&importer, &crater::BibleImporter::failed);
        const int first = importer.analyze(files);
        QTRY_COMPARE(analyzed.size() + failed.size(), 1);
        QCOMPARE(failed.size(), 0);
        QCOMPARE(analyzed.first().at(0).toInt(), first);   // answers carry their request
        const QVariantMap info = analyzed.first().at(1).toMap();
        QCOMPARE(info.value("code").toString(), QStringLiteral("ZTB"));
        QCOMPARE(info.value("books").toInt(), 2);
        QCOMPARE(info.value("verses").toInt(), 3);
        QCOMPARE(info.value("skippedBooks").toStringList(), QStringList{ QStringLiteral("Tobit") });

        const auto suggested = [&](const QString& name, const QByteArray& bytes) {
            analyzed.clear();
            const int request = importer.analyze({ write(name, bytes) });
            if (!QTest::qWaitFor([&] { return analyzed.size() + failed.size() > 0; })) return QVariantMap();
            return analyzed.isEmpty() || analyzed.first().at(0).toInt() != request
                ? QVariantMap() : analyzed.first().at(1).toMap();
        };
        // A dotted OSIS work name suggests its last part.
        QCOMPARE(suggested("dotted.osis.xml", QByteArray(kOsis).replace("\"TOSIS\"", "\"Bible.en.kjv\""))
                     .value("code").toString(), QStringLiteral("KJV"));
        // A file that names no code: eBible's language-translation name
        // gives the translation part, several words give their initials.
        const QVariantMap dby = suggested("eng-dby_usfm.xmm", kOpenSong);
        QCOMPARE(dby.value("name").toString(), QStringLiteral("eng-dby"));
        QCOMPARE(dby.value("code").toString(), QStringLiteral("DBY"));
        QCOMPARE(suggested("web.xml", QByteArray(kZefania).replace("<identifier>ZTB</identifier>", "")
                                           .replace("Zefania Test Bible", "World English Bible"))
                     .value("code").toString(), QStringLiteral("WEB"));

        QVERIFY(importer.codeProblem(QStringLiteral("NEW")).isEmpty());
        QVERIFY(importer.codeProblem(QStringLiteral("NEW-2")).isEmpty());
        QVERIFY(!importer.codeProblem(QStringLiteral("two words")).isEmpty());
        QVERIFY(!importer.codeProblem(QString()).isEmpty());

        const int revision = bible.translationsRevision();
        QSignalSpy completed(&importer, &crater::BibleImporter::completed);
        importer.run(files, QStringLiteral("ztb"), QStringLiteral("Zefania Test Bible"));
        QTRY_COMPARE(completed.size() + failed.size(), 1);
        QCOMPARE(failed.size(), 0);
        QCOMPARE(completed.first().at(1).toString(), QStringLiteral("ZTB"));
        QCOMPARE(completed.first().at(2).toInt(), 4);   // 2-3 is stored under both
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

        // Only a Bible added from a file can be removed. One installed any
        // other way (a bundle, an older release's bundle) can't.
        {
            crater::db::Connection conn(crater::db::DbPaths::biblesDbPath());
            conn.exec(u"INSERT INTO translations (code, name) VALUES ('OLD', 'Shipped by an older release')");
        }
        QVERIFY(importer.isRemovable(QStringLiteral("ZTB")));
        QVERIFY(importer.isRemovable(QStringLiteral("ztb")));
        QVERIFY(!importer.isRemovable(QStringLiteral("OLD")));
        QVERIFY(!importer.isRemovable(QString()));
        QSignalSpy removed(&importer, &crater::BibleImporter::removed);
        importer.remove(QStringLiteral("OLD"));
        QTRY_COMPARE(failed.size(), 2);

        const int removal = importer.remove(QStringLiteral("ZTB"));
        QTRY_COMPARE(removed.size() + failed.size(), 3);
        QCOMPARE(removed.size(), 1);
        QCOMPARE(removed.first().at(0).toInt(), removal);
        for (const crater::Translation& t : bible.translations()) QVERIFY(t.code != u"ZTB");
        QVERIFY(bible.allVerses(QStringLiteral("ZTB")).isEmpty());
        QCOMPARE(bible.search(QStringLiteral("beginning")).size(), 0);
        QVERIFY(importer.codeProblem(QStringLiteral("ZTB")).isEmpty());
        // Its search index rows go too, a moment later, and nothing is left
        // waiting.
        const auto count = [](QStringView sql) {
            crater::db::Connection conn(crater::db::DbPaths::biblesDbPath());
            auto st = conn.prepare(sql);
            return st.step() ? st.columnInt(0) : -1;
        };
        QTRY_COMPARE(count(u"SELECT count(*) FROM verses_fts"), 0);
        QTRY_COMPARE(count(u"SELECT count(*) FROM verses_fts_pending_delete"), 0);
    }

    // Removal clean-up a quit cut short is finished by the next import or
    // removal (or ten seconds after launch).
    void pendingCleanupResumes()
    {
        crater::BibleImporter importer;
        QSignalSpy completed(&importer, &crater::BibleImporter::completed);
        importer.run({ write("resume.xml", kZefania) }, QStringLiteral("RES"), QStringLiteral("Resume"));
        QTRY_COMPARE(completed.size(), 1);
        {
            // What remove() does before its clean-up, then a quit.
            crater::db::Connection conn(crater::db::DbPaths::biblesDbPath());
            conn.exec(u"PRAGMA foreign_keys = OFF");
            conn.exec(u"INSERT INTO verses_fts_pending_delete (verse_id, text, book_name, translation_code) "
                      u"SELECT v.id, replace(replace(v.text, '''', ''), char(8217), ''), b.name, t.code "
                      u"FROM verses v JOIN books b ON b.id = v.book_id "
                      u"JOIN translations t ON t.id = v.translation_id WHERE t.code = 'RES'");
            conn.exec(u"DELETE FROM verses WHERE translation_id = (SELECT id FROM translations WHERE code = 'RES')");
            conn.exec(u"DELETE FROM books WHERE translation_id = (SELECT id FROM translations WHERE code = 'RES')");
            conn.exec(u"DELETE FROM translations WHERE code = 'RES'");
        }
        crater::BibleImporter next;
        QSignalSpy failed(&next, &crater::BibleImporter::failed);
        next.remove(QStringLiteral("NOPE"));   // finishes the clean-up first
        QTRY_COMPARE(failed.size(), 1);
        const auto count = [](QStringView sql) {
            crater::db::Connection conn(crater::db::DbPaths::biblesDbPath());
            auto st = conn.prepare(sql);
            return st.step() ? st.columnInt(0) : -1;
        };
        QTRY_COMPARE(count(u"SELECT count(*) FROM verses_fts_pending_delete"), 0);
        QTRY_COMPARE(count(u"SELECT count(*) FROM verses_fts"), 0);
    }
};

QTEST_GUILESS_MAIN(TestBibleFormats)
#include "test_bible_formats.moc"
