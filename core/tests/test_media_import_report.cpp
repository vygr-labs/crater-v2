// Media import tells the operator what it skipped (issue #24), accepts
// wmv files but not audio-only wma (issue #23), and asks before copying a
// very large folder.
//
// importPaths() runs on a worker and reports through importFinished(), so
// each case waits on that signal and reads the { name, reason } list it
// carries. Files are fakes: the sniff only reads the leading bytes.
//
// Run via CTest: `ctest --test-dir <build-dir> -R media_import_report --output-on-failure`

#include <QByteArray>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QObject>
#include <QSignalSpy>
#include <QStandardPaths>
#include <QString>
#include <QTemporaryDir>
#include <QTest>
#include <QUrl>
#include <QVariantList>
#include <QVariantMap>

#include "crater/Bootstrap.h"
#include "crater/MediaService.h"

using crater::MediaService;

namespace {

const QByteArray kPng("\x89PNG\r\n\x1a\n", 8);

// A minimal ASF header: the header object GUID, its 8-byte little-endian
// size, and one stream type GUID inside it. The sniff only reads that far.
QByteArray asfWithStream(const QByteArray& streamType)
{
    const QByteArray guid("\x30\x26\xb2\x75\x8e\x66\xcf\x11"
                          "\xa6\xd9\x00\xaa\x00\x62\xce\x6c", 16);
    QByteArray body(14, '\0');   // object count + reserved bytes
    body += streamType;
    const quint64 size = quint64(guid.size() + 8 + body.size());
    QByteArray sizeLe(8, '\0');
    for (int i = 0; i < 8; ++i) sizeLe[i] = char((size >> (8 * i)) & 0xff);
    return guid + sizeLe + body;
}
const QByteArray kWmv = asfWithStream(QByteArray("\xc0\xef\x19\xbc\x4d\x5b\xcf\x11"
                                                 "\xa8\xfd\x00\x80\x5f\x5c\x44\x2b", 16));
const QByteArray kWma = asfWithStream(QByteArray("\x40\x9e\x69\xf8\x4d\x5b\xcf\x11"
                                                 "\xa8\xfd\x00\x80\x5f\x5c\x44\x2b", 16));

bool writeFile(const QString& path, const QByteArray& bytes)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly)) return false;
    f.write(bytes);
    f.write(QByteArray(64, '\0'));   // past the 32-byte sniff window
    return true;
}

// Runs one importPaths() call to completion and returns the signal's args.
QList<QVariant> importAndWait(MediaService& media, const QStringList& paths)
{
    QSignalSpy spy(&media, &MediaService::importFinished);
    media.importPaths(paths);
    if (!spy.wait(10000)) return {};
    return spy.takeFirst();
}

QList<QVariant> importAndWaitConfirmed(MediaService& media, const QStringList& paths)
{
    QSignalSpy spy(&media, &MediaService::importFinished);
    media.importPaths(paths, true);
    if (!spy.wait(30000)) return {};
    return spy.takeFirst();
}

QStringList names(const QVariantList& skipped)
{
    QStringList out;
    for (const QVariant& v : skipped) out << v.toMap().value(QStringLiteral("name")).toString();
    return out;
}

}  // namespace

class TestMediaImportReport : public QObject
{
    Q_OBJECT

private:
    QString m_dataDir;

private slots:
    void initTestCase()
    {
        QStandardPaths::setTestModeEnabled(true);
        m_dataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        QVERIFY(!m_dataDir.isEmpty());
        QDir(m_dataDir).removeRecursively();
        QDir().mkpath(m_dataDir);
        crater::runAllMigrations();
    }

    void cleanupTestCase()
    {
        QDir(m_dataDir).removeRecursively();
    }

    void wmvImportsAsVideo()
    {
        QTemporaryDir tmp;
        const QString src = tmp.filePath(QStringLiteral("worship-loop.wmv"));
        QVERIFY(writeFile(src, kWmv));

        MediaService media;
        const qint64 id = media.importPathSync(src);
        QVERIFY2(id > 0, qPrintable(media.lastImportError()));
        QCOMPARE(media.byId(id).type, QStringLiteral("video"));
    }

    // Same container, no video stream: it would play as a black screen.
    void audioOnlyWmaIsRefused()
    {
        QTemporaryDir tmp;
        const QString src = tmp.filePath(QStringLiteral("hymn.wma"));
        QVERIFY(writeFile(src, kWma));

        MediaService media;
        QCOMPARE(media.importPathSync(src), qint64(0));
    }

    void skippedFilesAreNamedWithAReason()
    {
        QTemporaryDir tmp;
        const QString good = tmp.filePath(QStringLiteral("good.png"));
        const QString text = tmp.filePath(QStringLiteral("notes.txt"));
        const QString big  = tmp.filePath(QStringLiteral("huge.png"));
        QVERIFY(writeFile(good, kPng));
        QVERIFY(writeFile(text, QByteArray("just some words")));
        QVERIFY(writeFile(big, kPng + QByteArray(4096, 'x')));

        MediaService media;
        media.setSizeCapBytes(1024);
        const auto args = importAndWait(media, { good, text, big,
                                                 tmp.filePath(QStringLiteral("missing.png")) });
        QCOMPARE(args.size(), 3);
        QCOMPARE(args.at(0).toInt(), 1);
        QCOMPARE(args.at(1).toInt(), 3);

        const QVariantList skipped = args.at(2).toList();
        QCOMPARE(names(skipped),
                 (QStringList{ QStringLiteral("notes.txt"), QStringLiteral("huge.png"),
                               QStringLiteral("missing.png") }));
        for (const QVariant& v : skipped)
            QVERIFY(!v.toMap().value(QStringLiteral("reason")).toString().isEmpty());
        QCOMPARE(skipped.at(0).toMap().value(QStringLiteral("reason")).toString(),
                 QStringLiteral("unsupported format"));
    }

    void droppedFolderImportsItsFiles()
    {
        QTemporaryDir tmp;
        const QString folder = tmp.filePath(QStringLiteral("Backgrounds"));
        QVERIFY(writeFile(folder + QStringLiteral("/a.png"), kPng));
        QVERIFY(writeFile(folder + QStringLiteral("/nested/b.wmv"), kWmv));
        QVERIFY(writeFile(folder + QStringLiteral("/readme.txt"), QByteArray("hi")));

        MediaService media;
        const auto args = importAndWait(media, { QUrl::fromLocalFile(folder).toString() });
        QCOMPARE(args.size(), 3);
        QCOMPARE(args.at(0).toInt(), 2);
        QCOMPARE(names(args.at(2).toList()), QStringList{ QStringLiteral("readme.txt") });
    }

    void largeFolderAsksBeforeImporting()
    {
        QTemporaryDir tmp;
        const QString folder = tmp.filePath(QStringLiteral("Pictures"));
        const int count = MediaService::kLargeFolderImport + 1;
        for (int i = 0; i < count; ++i)
            QVERIFY(writeFile(folder + QStringLiteral("/p%1.png").arg(i), kPng));

        MediaService media;
        const int before = int(media.allMedia().size());
        QSignalSpy pending(&media, &MediaService::largeImportPending);
        QSignalSpy finished(&media, &MediaService::importFinished);
        media.importPaths({ folder });
        QVERIFY(pending.wait(10000));
        QCOMPARE(pending.first().at(1).toInt(), count);
        QCOMPARE(finished.size(), 0);
        QCOMPARE(int(media.allMedia().size()), before);

        // Confirmed, the same paths go through.
        const auto args = importAndWaitConfirmed(media, pending.first().at(0).toStringList());
        QCOMPARE(args.size(), 3);
        QCOMPARE(args.at(0).toInt(), count);
    }
};

int main(int argc, char* argv[])
{
    QGuiApplication app(argc, argv);
    TestMediaImportReport tc;
    return QTest::qExec(&tc, argc, argv);
}

#include "test_media_import_report.moc"
