// Tests for .craterheme v2 bundle format (ARCHITECTURE.md §10).
//
// Two layers covered:
//   1. Bundle wrapper      — crater::bundle::ZipWriter / ZipReader (no DB,
//                            no services). Cheap, fast, isolated.
//   2. Full bundle pipeline — ThemeService::exportTheme +
//                            importThemeFile + media + font wiring,
//                            against real SQLite (test-mode AppDataLocation).
//
// Run via CTest: `ctest --test-dir <build-dir> -R theme_bundle --output-on-failure`
// Or directly:   `./test_theme_bundle` from the build output dir.

#include <QByteArray>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QObject>
#include <QStandardPaths>
#include <QString>
#include <QTemporaryDir>
#include <QTest>

#include "crater/Bootstrap.h"
#include "crater/FontService.h"
#include "crater/MediaService.h"
#include "crater/ThemeService.h"
#include "crater/ThemeTokens.h"
#include "crater/value/ThemeImportReport.h"

#include "bundle/Zip.h"

using crater::FontService;
using crater::MediaService;
using crater::ThemeImportReport;
using crater::ThemeService;
using crater::bundle::ZipReader;
using crater::bundle::ZipWriter;

namespace {

// A 29-byte synthetic PNG: real magic bytes followed by arbitrary payload.
// MediaService::importPathSync sniffs the leading bytes to classify the
// file (§5.1) and doesn't further validate the PNG body, so this slips
// through end-to-end while being byte-identifiable in round-trip checks.
QByteArray fakeImage(const QByteArray& tag)
{
    QByteArray b("\x89PNG\r\n\x1a\n", 8);
    b += tag;
    return b;
}

// A synthetic MP4: a valid ISO-BMFF 'ftyp' box header (so
// MediaService::sniffMediaType classifies it "video" via its
// matchAt(4,"ftyp",4) rule) followed by an arbitrary payload. crater-core
// never decodes video — it only sniffs magic bytes and copies the file
// (decode/thumbnailing is the app-side VideoThumbnailer's job) — so a fake
// like this round-trips through export/import identically to a real clip,
// without dragging a multi-MB binary fixture into the repo. The four leading
// bytes are appended individually to dodge the C++ \x escape swallowing the
// following 'f' as a hex digit.
QByteArray fakeVideo(const QByteArray& tag)
{
    QByteArray b;
    b.append('\x00').append('\x00').append('\x00').append('\x18'); // ftyp box size
    b.append("ftypisom", 8);                                       // 'ftyp' + major brand
    b += tag;
    return b;
}

// Minimal valid v2 token map referencing one media id. We hand-craft this
// rather than going through the editor because the test owns the
// invariant we care about (refs round-trip correctly) and bypassing the
// editor keeps the test independent of editor refactors.
QVariantMap makeTokensWithMediaId(qint64 mediaId, const QString& fontFamily = QStringLiteral("Funnel Sans"))
{
    QVariantMap containerStyle;
    containerStyle["x"] = 0;       containerStyle["y"] = 0;
    containerStyle["width"] = 100; containerStyle["height"] = 100;
    containerStyle["z"] = 0;       containerStyle["opacity"] = 1;
    containerStyle["backgroundColor"] = QStringLiteral("#0a0a0d");

    QVariantMap containerData;
    containerData["layerName"]    = QStringLiteral("Background");
    containerData["mediaId"]      = QVariant(mediaId);
    containerData["bgOpacity"]    = 1;
    containerData["overlayColor"] = QVariant::fromValue(nullptr);

    QVariantMap container;
    container["id"] = QStringLiteral("bg");
    container["kind"] = QStringLiteral("container");
    container["style"] = containerStyle;
    container["data"] = containerData;

    QVariantMap textStyle;
    textStyle["x"] = 5;  textStyle["y"] = 35;
    textStyle["width"] = 90; textStyle["height"] = 30;
    textStyle["z"] = 10; textStyle["opacity"] = 1;
    textStyle["color"]         = QStringLiteral("#f5f5f0");
    textStyle["fontFamily"]    = fontFamily;
    textStyle["fontPixelSize"] = 64;
    textStyle["fontWeight"]    = 500;

    QVariantMap textData;
    textData["layerName"]   = QStringLiteral("Verse");
    textData["linkage"]     = QStringLiteral("scriptureText");
    textData["autoResize"]  = true;
    textData["maxFontSize"] = 220;

    QVariantMap textNode;
    textNode["id"]   = QStringLiteral("txt");
    textNode["kind"] = QStringLiteral("text");
    textNode["style"] = textStyle;
    textNode["data"]  = textData;

    QVariantList nodes;
    nodes.append(container);
    nodes.append(textNode);

    QVariantMap canvas;
    canvas["width"] = 1920;
    canvas["height"] = 1080;

    // Deliberately authored as v2, the shape every theme in an existing
    // install has. ThemeService upgrades it to v3 on write, so leaving this
    // at v2 means the whole bundle suite also exercises that upgrade rather
    // than only ever seeing tokens that were born current.
    QVariantMap tokens;
    tokens["version"] = 2;
    tokens["canvas"]  = canvas;
    tokens["nodes"]   = nodes;
    return tokens;
}

// Every node in a theme, flattened across layouts. Tokens reach these
// helpers in either shape: the fixture below authors v2 (one top-level
// `nodes` array) and ThemeService upgrades it to v3 (`layouts[].nodes`) on
// the way into the database, so a test that reads only one of the two
// silently stops checking anything the moment the other is in play.
// crater::tokens::layoutsOf normalises both.
QVariantList allNodesIn(const QVariantMap& tokens)
{
    QVariantList out;
    for (const QVariant& l : crater::tokens::layoutsOf(tokens))
        out += l.toMap().value(QStringLiteral("nodes")).toList();
    return out;
}

// Walks a tokens map and returns the mediaId from the first container
// node. Returns 0 when there isn't one — used to verify post-import
// rewrite produced a non-zero new id.
qint64 firstMediaIdIn(const QVariantMap& tokens)
{
    const QVariantList nodes = allNodesIn(tokens);
    for (const QVariant& n : nodes) {
        const QVariantMap node = n.toMap();
        if (node.value(QStringLiteral("kind")).toString() == QLatin1String("container")) {
            const QVariantMap data = node.value(QStringLiteral("data")).toMap();
            bool ok = false;
            const qint64 v = data.value(QStringLiteral("mediaId")).toLongLong(&ok);
            if (ok) return v;
        }
    }
    return 0;
}

}  // namespace

class TestThemeBundle : public QObject
{
    Q_OBJECT

private:
    QString m_dataDir;

    // Nuke + recreate the test AppDataLocation between sub-tests so each
    // starts from a clean DB. setTestModeEnabled redirects to a Qt-test
    // folder under ~/.qttest, so this never touches a user's real data.
    void resetState()
    {
        QDir(m_dataDir).removeRecursively();
        QDir().mkpath(m_dataDir);
    }

private slots:
    void initTestCase()
    {
        QStandardPaths::setTestModeEnabled(true);
        m_dataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        QVERIFY(!m_dataDir.isEmpty());
    }

    void cleanupTestCase()
    {
        QDir(m_dataDir).removeRecursively();
    }

    // ── Layer 1: zip wrapper round-trip ─────────────────────────────────
    void testZipRoundTrip()
    {
        QTemporaryDir tmp;
        QVERIFY(tmp.isValid());
        const QString zipPath = tmp.filePath(QStringLiteral("a.zip"));

        const QByteArray helloBytes("hello world");
        const QByteArray emptyJson("{}");
        const QByteArray binaryBlob = QByteArray::fromHex(
            "deadbeef0102030405060708ffaa55aa55aa");

        {
            ZipWriter w(zipPath);
            QVERIFY(w.isOpen());
            QVERIFY(w.addEntry(QStringLiteral("manifest.json"), emptyJson));
            QVERIFY(w.addEntry(QStringLiteral("hello.txt"), helloBytes));
            QVERIFY(w.addEntry(QStringLiteral("media/blob.bin"), binaryBlob));
            QVERIFY(w.commit());
        }

        ZipReader r(zipPath);
        QVERIFY(r.isOpen());
        const QStringList names = r.entryNames();
        QCOMPARE(names.size(), 3);
        QVERIFY(r.hasEntry(QStringLiteral("manifest.json")));
        QVERIFY(r.hasEntry(QStringLiteral("media/blob.bin")));
        QCOMPARE(r.readEntry(QStringLiteral("manifest.json")), emptyJson);
        QCOMPARE(r.readEntry(QStringLiteral("hello.txt")), helloBytes);
        QCOMPARE(r.readEntry(QStringLiteral("media/blob.bin")), binaryBlob);
    }

    // CRC-32 must reject corruption inside an entry. We flip one byte in
    // the file at a known offset (the payload of the first entry) and
    // expect the reader to return empty for that entry.
    void testZipCrcDetectsCorruption()
    {
        QTemporaryDir tmp;
        QVERIFY(tmp.isValid());
        const QString zipPath = tmp.filePath(QStringLiteral("b.zip"));

        const QByteArray payload("integrity-check-payload");
        {
            ZipWriter w(zipPath);
            QVERIFY(w.isOpen());
            QVERIFY(w.addEntry(QStringLiteral("data.bin"), payload));
            QVERIFY(w.commit());
        }

        // The data payload sits at offset 30 + sizeof("data.bin") = 30 + 8.
        // Flip one byte inside it.
        QFile f(zipPath);
        QVERIFY(f.open(QIODevice::ReadWrite));
        f.seek(38 + 5);
        const char before = char(f.read(1).at(0));
        f.seek(38 + 5);
        QVERIFY(f.write(QByteArray(1, char(before ^ 0x55))) == 1);
        f.close();

        ZipReader r(zipPath);
        QVERIFY(r.isOpen());
        const QByteArray result = r.readEntry(QStringLiteral("data.bin"));
        QVERIFY(result.isEmpty());   // CRC mismatch → reader refuses
    }

    // ── Layer 2: full bundle pipeline ───────────────────────────────────
    void testV1FileIsRefused()
    {
        resetState();
        crater::runAllMigrations();
        ThemeService ts;

        // Synthesize a v1 file (JSON only). Per §10.2 import must refuse
        // these with a clear "re-export" message rather than silently
        // half-importing.
        QTemporaryDir tmp;
        QVERIFY(tmp.isValid());
        const QString legacyPath = tmp.filePath(QStringLiteral("old.craterheme"));
        const QByteArray v1Json =
            R"({"kind":"craterheme","formatVersion":1,"themeKind":"song",)"
            R"("name":"Old","tokens":{}})";
        {
            QFile f(legacyPath);
            QVERIFY(f.open(QIODevice::WriteOnly));
            f.write(v1Json);
        }

        const ThemeImportReport report = ts.importThemeFile(legacyPath);
        QCOMPARE(report.themeId, qint64(0));
        QVERIFY(report.errorMessage.contains(
            QStringLiteral("older version"), Qt::CaseInsensitive));
    }

    // The defining round-trip: export a theme that references a media
    // file, "reset" by deleting the theme, then import the bundle and
    // verify the new theme points at a media row whose bytes are
    // byte-for-byte identical to the original. This is the load-bearing
    // invariant — "import a theme with media flawlessly" — that
    // motivated the whole feature.
    void testBundleRoundTrip()
    {
        resetState();
        crater::runAllMigrations();
        MediaService media;
        FontService  fonts;
        ThemeService ts;
        ts.setMediaService(&media);
        ts.setFontService(&fonts);

        QTemporaryDir tmp;
        QVERIFY(tmp.isValid());

        // Stage a fake PNG for MediaService to import.
        const QByteArray originalBytes = fakeImage("round-trip-source");
        const QString stagePath = tmp.filePath(QStringLiteral("source.png"));
        {
            QFile f(stagePath);
            QVERIFY(f.open(QIODevice::WriteOnly));
            f.write(originalBytes);
        }
        const qint64 origMediaId = media.importPathSync(stagePath);
        QVERIFY2(origMediaId > 0,
                 qPrintable(media.lastImportError()));

        // Build + create a theme referencing that media id.
        const qint64 themeId = ts.create(QStringLiteral("scripture"),
                                         QStringLiteral("Round Trip Test"),
                                         makeTokensWithMediaId(origMediaId));
        QVERIFY(themeId > 0);

        // Export.
        const QString bundlePath = tmp.filePath(QStringLiteral("rt.craterheme"));
        QVERIFY2(ts.exportTheme(themeId, bundlePath, {}),
                 qPrintable(ts.lastExportError()));
        QVERIFY(QFile::exists(bundlePath));

        // Verify the bundle is a real zip with the expected entries.
        {
            ZipReader r(bundlePath);
            QVERIFY(r.isOpen());
            QVERIFY(r.hasEntry(QStringLiteral("manifest.json")));
            QVERIFY(r.hasEntry(QStringLiteral("theme.json")));
            bool foundMedia = false;
            for (const QString& n : r.entryNames())
                if (n.startsWith(QStringLiteral("media/"))) { foundMedia = true; break; }
            QVERIFY(foundMedia);
        }

        // "Reset" — destroy the theme. Leave the media row alone so we
        // can verify the import creates a SECOND media row (new id, same
        // bytes) rather than reusing the old one.
        ts.destroy(themeId);

        const ThemeImportReport report = ts.importThemeFile(bundlePath);
        QCOMPARE(report.errorMessage, QString());
        QVERIFY(report.themeId > 0);
        QCOMPARE(report.mediaWarnings.size(), 0);
        QCOMPARE(report.fontWarnings.size(), 0);

        const crater::Theme imported = ts.theme(report.themeId);
        QCOMPARE(imported.kind, QStringLiteral("scripture"));
        QVERIFY(imported.name.startsWith(QStringLiteral("Round Trip Test")));

        const qint64 importedMediaId = firstMediaIdIn(imported.tokens);
        QVERIFY(importedMediaId > 0);
        QVERIFY(importedMediaId != origMediaId);

        const crater::MediaItem mi = media.byId(importedMediaId);
        QVERIFY(mi.id > 0);

        QFile newFile(mi.path);
        QVERIFY(newFile.open(QIODevice::ReadOnly));
        const QByteArray newBytes = newFile.readAll();
        QCOMPARE(newBytes, originalBytes);
    }

    // The video counterpart of testBundleRoundTrip: the feature has to
    // round-trip video backgrounds as flawlessly as images. Same invariant
    // — export a theme that references a video, reset, import, and verify
    // the new media row holds byte-identical content and is still classified
    // "video". This is the case the user explicitly cares about; video media
    // travels through the exact same bundle path as images (content-addressed
    // entry under media/<sha256>.<ext>), so a green here means both work.
    void testBundleRoundTripVideo()
    {
        resetState();
        crater::runAllMigrations();
        MediaService media;
        FontService  fonts;
        ThemeService ts;
        ts.setMediaService(&media);
        ts.setFontService(&fonts);

        QTemporaryDir tmp;
        QVERIFY(tmp.isValid());

        // Stage a fake MP4 for MediaService to import + classify as video.
        const QByteArray originalBytes = fakeVideo("round-trip-video-source");
        const QString stagePath = tmp.filePath(QStringLiteral("source.mp4"));
        {
            QFile f(stagePath);
            QVERIFY(f.open(QIODevice::WriteOnly));
            f.write(originalBytes);
        }
        const qint64 origMediaId = media.importPathSync(stagePath);
        QVERIFY2(origMediaId > 0, qPrintable(media.lastImportError()));
        // Confirm the boundary actually classified it as video, not image —
        // otherwise this test would silently degenerate into the PNG case.
        QCOMPARE(media.byId(origMediaId).type, QStringLiteral("video"));

        const qint64 themeId = ts.create(QStringLiteral("scripture"),
                                         QStringLiteral("Video Round Trip"),
                                         makeTokensWithMediaId(origMediaId));
        QVERIFY(themeId > 0);

        const QString bundlePath = tmp.filePath(QStringLiteral("rtv.craterheme"));
        QVERIFY2(ts.exportTheme(themeId, bundlePath, {}),
                 qPrintable(ts.lastExportError()));

        // The bundle must carry a media/ entry for the video.
        {
            ZipReader r(bundlePath);
            QVERIFY(r.isOpen());
            bool foundMedia = false;
            for (const QString& n : r.entryNames())
                if (n.startsWith(QStringLiteral("media/"))) { foundMedia = true; break; }
            QVERIFY(foundMedia);
        }

        ts.destroy(themeId);

        const ThemeImportReport report = ts.importThemeFile(bundlePath);
        QCOMPARE(report.errorMessage, QString());
        QVERIFY(report.themeId > 0);
        QCOMPARE(report.mediaWarnings.size(), 0);
        QCOMPARE(report.fontWarnings.size(), 0);

        const crater::Theme imported = ts.theme(report.themeId);
        const qint64 importedMediaId = firstMediaIdIn(imported.tokens);
        QVERIFY(importedMediaId > 0);
        QVERIFY(importedMediaId != origMediaId);

        const crater::MediaItem mi = media.byId(importedMediaId);
        QVERIFY(mi.id > 0);
        QCOMPARE(mi.type, QStringLiteral("video"));

        QFile newFile(mi.path);
        QVERIFY(newFile.open(QIODevice::ReadOnly));
        QCOMPARE(newFile.readAll(), originalBytes);
    }

    // Regression: an imported theme must survive an app RESTART with its
    // custom styling intact. ThemeService runs the lazy v1->v2 token rewrite
    // (migrateRowsToV2) in its constructor, selecting every row with
    // tokens_version < 2. A create()/import INSERT that omitted tokens_version
    // left the row at the column DEFAULT of 1, so the next launch re-ran the
    // v1->v2 converter over already-v2 JSON and blanked it to the default
    // theme. The in-process round-trip tests above can't see this because the
    // migration only runs at construction — so we explicitly open a SECOND
    // ThemeService on the same DB to stand in for a restart.
    void testImportedThemeSurvivesRestart()
    {
        resetState();
        crater::runAllMigrations();

        QTemporaryDir tmp;
        QVERIFY(tmp.isValid());

        qint64       importedId = 0;
        QVariantMap  tokensBeforeRestart;
        const QByteArray originalBytes = fakeImage("survives-restart");

        // ── Session 1: import a theme that references media ──────────────
        {
            MediaService media;
            FontService  fonts;
            ThemeService ts;
            ts.setMediaService(&media);
            ts.setFontService(&fonts);

            const QString stagePath = tmp.filePath(QStringLiteral("src.png"));
            {
                QFile f(stagePath);
                QVERIFY(f.open(QIODevice::WriteOnly));
                f.write(originalBytes);
            }
            const qint64 mid = media.importPathSync(stagePath);
            QVERIFY2(mid > 0, qPrintable(media.lastImportError()));

            const qint64 srcThemeId = ts.create(QStringLiteral("scripture"),
                                                QStringLiteral("Restart Source"),
                                                makeTokensWithMediaId(mid));
            QVERIFY(srcThemeId > 0);

            const QString bundlePath = tmp.filePath(QStringLiteral("restart.craterheme"));
            QVERIFY2(ts.exportTheme(srcThemeId, bundlePath, {}),
                     qPrintable(ts.lastExportError()));
            ts.destroy(srcThemeId);

            const ThemeImportReport report = ts.importThemeFile(bundlePath);
            QVERIFY(report.themeId > 0);
            importedId = report.themeId;

            tokensBeforeRestart = ts.theme(importedId).tokens;
            // Precondition: the fresh import really does carry custom nodes
            // and a resolved media id, so a post-restart regression is visible.
            QVERIFY(allNodesIn(tokensBeforeRestart).size() >= 2);
            QVERIFY(firstMediaIdIn(tokensBeforeRestart) > 0);
        }
        // ts/media/fonts destroyed here — connections closed, like app exit.

        // ── Session 2: "restart" — a new service re-runs migrateRowsToV2 ──
        {
            ThemeService ts2;
            const crater::Theme after = ts2.theme(importedId);
            QCOMPARE(after.id, importedId);
            // Custom layout must persist: same node count, same media ref.
            // Pre-fix this collapsed to the 2-node blank default with a null
            // mediaId, so these comparisons are the teeth of the test.
            QCOMPARE(allNodesIn(after.tokens).size(),
                     allNodesIn(tokensBeforeRestart).size());
            QCOMPARE(firstMediaIdIn(after.tokens), firstMediaIdIn(tokensBeforeRestart));
            QVERIFY(firstMediaIdIn(after.tokens) > 0);
        }
    }

    // Tampering with a bundled media file must surface as a per-asset
    // WARNING (best-effort, D2) — the theme still imports, but the
    // affected node has mediaId = null and the report carries a
    // diagnostic. NOT a catastrophic abort.
    void testTamperedMediaIsWarning()
    {
        resetState();
        crater::runAllMigrations();
        MediaService media;
        FontService  fonts;
        ThemeService ts;
        ts.setMediaService(&media);
        ts.setFontService(&fonts);

        QTemporaryDir tmp;
        QVERIFY(tmp.isValid());

        const QString stagePath = tmp.filePath(QStringLiteral("src.png"));
        const QByteArray bytes = fakeImage("tamper-target");
        {
            QFile f(stagePath);
            QVERIFY(f.open(QIODevice::WriteOnly));
            f.write(bytes);
        }
        const qint64 mid = media.importPathSync(stagePath);
        QVERIFY(mid > 0);
        const qint64 themeId = ts.create(QStringLiteral("song"),
                                         QStringLiteral("Tampered Test"),
                                         makeTokensWithMediaId(mid));
        QVERIFY(themeId > 0);

        const QString bundlePath = tmp.filePath(QStringLiteral("t.craterheme"));
        QVERIFY(ts.exportTheme(themeId, bundlePath, {}));
        ts.destroy(themeId);

        // Find the media entry's local-file-header data offset by
        // reading the zip back ourselves, then flip a byte in the
        // middle of the entry payload. The zip's CRC-32 will catch
        // this (returning empty from readEntry), which the importer
        // surfaces as a warning per §10.4.
        //
        // Simpler approach: open the file, scan for "PNG" magic in
        // the body (only inside the media entry), flip the byte
        // immediately after it. The Local File Header's filename
        // ends just before the payload, so this lands inside payload.
        {
            QFile f(bundlePath);
            QVERIFY(f.open(QIODevice::ReadWrite));
            const QByteArray all = f.readAll();
            const int pngOff = all.indexOf("\x89PNG", 0);
            QVERIFY(pngOff > 0);
            f.seek(pngOff + 8);   // past the PNG signature
            const char b = char(f.read(1).at(0));
            f.seek(pngOff + 8);
            f.write(QByteArray(1, char(b ^ 0xA5)));
        }

        const ThemeImportReport report = ts.importThemeFile(bundlePath);
        QCOMPARE(report.errorMessage, QString());
        QVERIFY(report.themeId > 0);
        QCOMPARE(report.mediaWarnings.size(), 1);

        // The theme imported; the container's mediaId should be null,
        // not a stale or fabricated id.
        const crater::Theme imported = ts.theme(report.themeId);
        QCOMPARE(firstMediaIdIn(imported.tokens), qint64(0));
    }
};

// QFontDatabase's runtime requires a QGuiApplication, so we can't use
// QTEST_GUILESS_MAIN here. QGuiApplication is enough — we don't need
// the Widgets-derived QApplication.
int main(int argc, char* argv[])
{
    QGuiApplication app(argc, argv);
    TestThemeBundle tc;
    return QTest::qExec(&tc, argc, argv);
}

#include "test_theme_bundle.moc"
