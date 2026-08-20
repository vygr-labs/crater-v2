#include <QApplication>
#include <QDateTime>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>

#include <cstdio>
#include <QFont>
#include <QFontDatabase>
#include <QFuture>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QQmlEngine>
#include <QQmlError>
#include <QQuickStyle>
#include <QStandardPaths>
#include <QTextStream>
#include <QtQml>

#ifdef Q_OS_WIN
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  ifndef NOMINMAX
#    define NOMINMAX
#  endif
#  include <windows.h>
#endif

#include "BrowserCastService.h"  // BrowserCast (removable feature)
#include "ClipboardService.h"
#include "FileDialogService.h"
#include "LogReportService.h"
#include "MediaPlaybackService.h"
#include "NdiRenderer.h"
#include "NdiService.h"
#include "PdfPageImageProvider.h"
#include "RichTextHelper.h"
#include "TranslationService.h"
#include "WindowChrome.h"
#include "VideoThumbnailer.h"

#include "crater/BibleService.h"
#include "crater/StrongsService.h"
#include "crater/CollectionService.h"
#include "crater/Bootstrap.h"
#include "crater/EasyWorshipImporter.h"
#include "crater/ElectronDataImporter.h"
#include "crater/LyricsService.h"
#include "crater/FontService.h"
#include "crater/MediaService.h"
#include "crater/OutputService.h"
#include "crater/ProjectionService.h"
#include "crater/ScheduleService.h"
#include "crater/NarrationService.h"
#include "crater/SettingsService.h"
#include "crater/SongService.h"
#include "crater/ThemeService.h"
// NDI lives in the app layer (not crater-core) because pixel capture
// requires Qt6::Quick — see qt/app/src/NdiService.h header comment.
#include "crater/Version.h"
#include "crater/WorkingTheme.h"

namespace {

QFile* g_logFile = nullptr;

void messageHandler(QtMsgType type, const QMessageLogContext& /*ctx*/, const QString& msg)
{
    const char* label = "    ";
    switch (type) {
    case QtDebugMsg:    label = "DEBUG"; break;
    case QtInfoMsg:     label = "INFO "; break;
    case QtWarningMsg:  label = "WARN "; break;
    case QtCriticalMsg: label = "CRIT "; break;
    case QtFatalMsg:    label = "FATAL"; break;
    }

    const QString line = QStringLiteral("[%1] %2 %3")
                             .arg(QDateTime::currentDateTime().toString(Qt::ISODateWithMs),
                                  QString::fromLatin1(label),
                                  msg);

    if (g_logFile && g_logFile->isOpen()) {
        QTextStream ts(g_logFile);
        ts << line << "\n";
        g_logFile->flush();
    }

    if (type == QtFatalMsg) {
        abort();
    }
}

// Walk up from the executable's directory looking for the project root
// (signaled by a sibling `qt/CMakeLists.txt` or `electron/` folder).
// If found, log to <repo>/personal/ so dev iterations have logs at hand.
// Otherwise — production install — log to per-user AppDataLocation.
QString resolveLogDir()
{
    QDir d(QCoreApplication::applicationDirPath());
    for (int hop = 0; hop < 6; ++hop) {
        const bool looksLikeRepo = d.exists(QStringLiteral("qt/CMakeLists.txt"))
                                || d.exists(QStringLiteral("electron"));
        if (looksLikeRepo) {
            QDir personal(d.absoluteFilePath(QStringLiteral("personal")));
            if (!personal.exists()) {
                personal.mkpath(QStringLiteral("."));
            }
            return personal.absolutePath();
        }
        if (!d.cdUp()) {
            break;
        }
    }

    QDir prod(QStandardPaths::writableLocation(QStandardPaths::AppDataLocation));
    if (!prod.exists()) {
        prod.mkpath(QStringLiteral("."));
    }
    return prod.absolutePath();
}

QString initLogging()
{
    const QString dir  = resolveLogDir();
    const QString path = QDir(dir).filePath(QStringLiteral("crater.log"));

    g_logFile = new QFile(path);
    if (!g_logFile->open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text)) {
        // Logging to stderr at least; not fatal.
        fprintf(stderr, "Crater: could not open log file %s\n", qPrintable(path));
    }

    qInstallMessageHandler(messageHandler);
    return path;
}

// Milliseconds the process spent in the OS loader BEFORE main() ran —
// mapping crater.exe and every linked DLL (Qt Quick, Multimedia, Network,
// the FFmpeg set, the NDI runtime…), running C++ static initializers, and
// any antivirus on-access scan. On a cold disk cache — or when the working
// directory sits inside a OneDrive-synced folder — this phase routinely
// dwarfs every in-process startup cost, yet no other log line can see it.
// Computed from the Win32 process creation time; returns -1 off Windows.
qint64 loaderMsBeforeMain()
{
#ifdef Q_OS_WIN
    FILETIME created {}, exited {}, kernelT {}, userT {};
    if (GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernelT, &userT)) {
        ULARGE_INTEGER c {};
        c.LowPart  = created.dwLowDateTime;
        c.HighPart = created.dwHighDateTime;
        FILETIME nowFt {};
        GetSystemTimeAsFileTime(&nowFt);
        ULARGE_INTEGER n {};
        n.LowPart  = nowFt.dwLowDateTime;
        n.HighPart = nowFt.dwHighDateTime;
        // FILETIME ticks are 100 ns; /10000 converts to milliseconds.
        return static_cast<qint64>((n.QuadPart - c.QuadPart) / 10000);
    }
#endif
    return -1;
}

// Establish the application-wide default font with a real fallback chain.
// QML's `font` value type only exposes `family` (not `families`), so we
// install fallbacks here at the QFont level. Anything that doesn't override
// `font.family` in QML inherits this and gets the same fallback behavior.
//
// Funnel Sans is registered first so it wins on every platform — the rest
// remain as graceful degradation for environments where the bundled font
// failed to load (e.g. resource stripped, registration error).
void initDefaultFont()
{
    QFont f;
    f.setFamilies({
        QStringLiteral("Funnel Sans"),
        QStringLiteral("Segoe UI Variable Display"),
        QStringLiteral("Segoe UI"),
        QStringLiteral(".AppleSystemUIFont"),
        QStringLiteral("SF Pro Display"),
        QStringLiteral("Inter"),
        QStringLiteral("Cantarell"),
        QStringLiteral("Helvetica Neue"),
    });
    f.setPixelSize(13);
    QApplication::setFont(f);
}

// Bundle Lucide as our icon font. AppIcon.qml renders glyphs by codepoint
// from this font; LucideIcons.qml maps human-readable names to codepoints.
void registerIconFont()
{
    const int id = QFontDatabase::addApplicationFont(QStringLiteral(":/fonts/lucide.ttf"));
    if (id < 0) {
        qWarning() << "Failed to load Lucide icon font from qrc:/fonts/lucide.ttf";
        return;
    }
    const QStringList families = QFontDatabase::applicationFontFamilies(id);
    qInfo().noquote() << "Lucide font registered as:" << families.join(", ");
}

// Bundle Funnel Sans as the body font — matches the electron renderer.
// Registered before initDefaultFont() runs so the variable font is on the
// QFontDatabase by the time the default QFont is constructed.
void registerBodyFont()
{
    const int id = QFontDatabase::addApplicationFont(
        QStringLiteral(":/fonts/FunnelSans-VariableFont_wght.ttf"));
    if (id < 0) {
        qWarning() << "Failed to load Funnel Sans from qrc:/fonts/FunnelSans-VariableFont_wght.ttf"
                   << "— body text will fall back to the system UI font.";
        return;
    }
    const QStringList families = QFontDatabase::applicationFontFamilies(id);
    qInfo().noquote() << "Funnel Sans registered as:" << families.join(", ");
}

}  // namespace

int main(int argc, char* argv[])
{
    // Wall clock from the first instruction of main(). Every "[startup]"
    // marker below logs elapsed() against this, so a single launch's log
    // reads top-to-bottom as a cost breakdown of the startup pipeline.
    QElapsedTimer startupClock;
    startupClock.start();

    // Early bootstrap trace — writes to a fixed file beside the exe BEFORE
    // any Qt code runs. If the main log is empty but this file exists, the
    // exe loaded fine and the crash is inside Qt initialization. If even
    // this file doesn't appear, the binary failed to load (most often a
    // missing DLL on Windows — check QtWidgets.dll deployment).
    if (FILE* boot = std::fopen("crater-bootstrap.log", "w")) {
        std::fprintf(boot, "main() entered (argc=%d)\n", argc);
        std::fflush(boot);
        std::fclose(boot);
    }

    QApplication::setOrganizationName(QStringLiteral("Voyager Labs"));
    QApplication::setOrganizationDomain(QStringLiteral("voyagerlabs.tech"));
    QApplication::setApplicationName(QStringLiteral("Crater"));
    QApplication::setApplicationVersion(crater::versionString());

    qputenv("QT_QUICK_CONTROLS_STYLE", "Basic");

    // Force the FFmpeg multimedia backend. Qt 6.7+ picks it by default on
    // Windows, but earlier 6.x versions ship the WMF (Windows Media
    // Foundation) backend which has weaker HW-decode coverage for HEVC
    // profiles and VP9. Setting this explicitly removes the version
    // sensitivity. If FFmpeg isn't present in the runtime, Qt silently
    // falls back to the native backend — so this is safe to set.
    qputenv("QT_MEDIA_BACKEND", "ffmpeg");

    QApplication app(argc, argv);

    // Brand mark for every Qt-managed window surface (title bar, taskbar
    // while running, alt-tab, dock on macOS). Loaded from the qrc-bundled
    // ICO — the same source asset the Windows .rc embeds into crater.exe
    // for pre-launch surfaces (File Explorer, start-menu shortcut), kept
    // in lockstep at build time by both pointing at qt/packaging/crater.ico.
    QApplication::setWindowIcon(QIcon(QStringLiteral(":/brand/crater.ico")));

    // Second bootstrap marker — confirms QApplication constructed without
    // dying. Anything past this point logs to the normal log file via
    // qInstallMessageHandler in initLogging().
    if (FILE* boot = std::fopen("crater-bootstrap.log", "a")) {
        std::fprintf(boot, "QApplication constructed\n");
        std::fclose(boot);
    }

    const QString logPath = initLogging();
    qInfo().noquote() << "──────── Crater" << crater::versionString() << "starting ────────";
    qInfo().noquote() << "Log file:" << logPath;

    // ─── Startup cost breakdown ─────────────────────────────────────────
    // The pre-main() figure is the OS loader cost — see loaderMsBeforeMain().
    // It is invisible to every other measurement we have, and on a cold
    // launch it is typically the largest single slice of perceived startup.
    {
        const qint64 preMain = loaderMsBeforeMain();
        if (preMain >= 0) {
            qInfo().noquote() << "[startup] OS loader + static init before main():"
                              << preMain << "ms";
        }
    }
    qInfo().noquote() << "[startup] Qt init + logging ready: +"
                      << startupClock.elapsed() << "ms";

    // Order: register the font face on QFontDatabase first so the default
    // QFont we build next can pick it up immediately.
    registerBodyFont();
    initDefaultFont();
    registerIconFont();
    QQuickStyle::setStyle(QStringLiteral("Basic"));

    // ─── Stage 1: run schema migrations ─────────────────────────────────
    // Each DB is created on demand inside AppDataLocation; migrations are
    // idempotent so this is safe to call every launch.
    try {
        crater::runAllMigrations();
    } catch (const std::exception& e) {
        qCritical().noquote() << "Migration failed:" << e.what();
        return -1;
    }
    qInfo().noquote() << "[startup] schema migrations done: +"
                      << startupClock.elapsed() << "ms";

    // ─── Stage 2: one-time data import ──────────────────────────────────
    // First launch: copy bible verses from electron's bundled DB into our
    // fresh schemas. Idempotent (writes a sentinel file). Future polish:
    // a SplashWindow.qml showing progress instead of blocking silently.
    {
        crater::ElectronDataImporter importer;
        if (importer.needsImport() && importer.legacyAvailable()) {
            qInfo() << "Running first-run data import (this can take a few seconds)...";
            QObject::connect(&importer, &crater::ElectronDataImporter::progress,
                             [](int percent, const QString& stage) {
                                 qInfo().noquote() << "  import:" << percent << "%" << stage;
                             });
            auto future = importer.run();
            future.waitForFinished();
            qInfo() << "Data import complete.";
        } else if (!importer.legacyAvailable() && importer.needsImport()) {
            qWarning() << "No legacy bibles.sqlite found — Bible DB will be empty "
                          "until a copy is placed under <exe>/legacy/ or the electron "
                          "repo is reachable from the working directory.";
        }
    }

    // ─── Stage 3: construct services ────────────────────────────────────
    // Order matters lightly: ThemeService and ScheduleService both touch
    // app.sqlite but use separate connections, so order is irrelevant. Each
    // service opens its own SQLite connection in its constructor.
    crater::BibleService      bibleService;
    // Strong's concordance. Opens two READ-ONLY bundled DBs (dictionary +
    // KJV-with-Strong's) in its ctor; if either is absent the service reports
    // it unavailable and the tab shows a "data not found" state. No deps.
    crater::StrongsService    strongsService;
    crater::SongService       songService;
    // Song collections — named groupings over songs.sqlite (its own connection,
    // separate from SongService's). No construction-order dependency.
    crater::CollectionService collectionService;
    crater::ScheduleService   scheduleService;
    crater::ThemeService      themeService;
    crater::MediaService      mediaService;
    // FontService must come BEFORE QML loads so user-imported fonts get
    // re-registered with QFontDatabase on this session's first paint;
    // see FontService.h's Lifecycle note. No service deps.
    crater::FontService       fontService;
    // Wire ThemeService -> MediaService/FontService for bundle export and
    // import (ARCHITECTURE.md §10). Construction order above already put
    // both downstream services first.
    themeService.setMediaService(&mediaService);
    themeService.setFontService(&fontService);
    // Clean up any .import-staging/ leftovers from a process kill in a
    // prior session (§10.4). Idempotent.
    crater::ThemeService::sweepImportStaging();
    // Reclaim any orphaned files in managed media storage — files whose
    // DB rows were deleted but whose on-disk file was held by a Windows
    // file lock or other transient failure during remove(). Synchronous
    // and racing-write-free: this runs before any QML loads and before
    // any import path can fire, so the (id, path) snapshot it reads is
    // authoritative for the duration of the sweep. Idempotent: empty
    // libraries are a no-op.
    mediaService.sweepOrphans();
    crater::OutputService     outputService;
    // Hand OutputService a ThemeService reference so its one-shot legacy
    // migration (Settings/themeIdFor* → Outputs/<id>/themes) can look up
    // each pinned theme's kind. Migration is scheduled on the next event
    // loop tick — order between this call and QML load doesn't matter.
    outputService.attachThemeService(&themeService);
    crater::ProjectionService projectionService;
    // SettingsService is constructed BEFORE QML loads so Theme.uiScale +
    // any other early bindings have a populated source. No service deps;
    // it owns its own QSettings instance.
    crater::SettingsService   settingsService;
    // NDI sender. Dynamic-loads Processing.NDI.Lib.x64.dll at construction;
    // if absent, NdiService.available stays false and the dialog reflects
    // that. Source window is wired from Main.qml's Component.onCompleted.
    crater::NdiService        ndiService;
    crater::FileDialogService fileDialogService;
    // Thin QtGui clipboard shim — lets QML copy scripture text to the system
    // clipboard. Stateless, no deps; see ClipboardService.h for why it's in
    // the app target rather than crater-core.
    crater::ClipboardService  clipboardService;
    // LogReportService uploads crater.log to voyagerlabs.tech on an explicit
    // operator action (Settings > Diagnostics) — see ARCHITECTURE.md §11. It
    // takes the path main.cpp logs to so it reports the exact file in use.
    crater::LogReportService  logReportService(logPath);
    // VideoThumbnailer takes &mediaService — it queries allMedia(), writes
    // probed durations back via setVideoMeta(), and uses thumbsDir() for
    // the on-disk layout. Must come after mediaService is constructed.
    crater::VideoThumbnailer  videoThumbnailer(&mediaService);
    // MediaPlaybackService owns one QMediaPlayer per active source URL,
    // refcounted across Preview / Live / Projection subscribers. No
    // dependencies on other services — it's a pure caching player pool.
    crater::MediaPlaybackService mediaPlaybackService;
    // LyricsService is a stateless QML-callable wrapper around the pure
    // crater::lyrics DSL functions (parse / serialize / HTML / palette).
    // Used by NodeRenderer to render formatted lyric/scripture text via
    // Text { textFormat: Text.RichText }, and by the song editor toolbar.
    crater::LyricsService     lyricsService;
    // RichTextHelper drives the song editor's formatting toolbar — bold /
    // italic / underline / color toggles operate on the live QTextCursor
    // of the WYSIWYG TextEdit instance the toolbar targets. Lives in the
    // app target because it depends on QQuickTextDocument (Qt6::Quick),
    // which crater-core can't link per ARCHITECTURE.md §1.
    crater::RichTextHelper    richTextHelper;
    // EasyWorship song-library importer. A one-shot operation object, not a
    // service — the Songs tab's import dialog drives it through signals. It
    // holds no state between runs, so one instance serves every import.
    crater::EasyWorshipImporter easyWorshipImporter;
    // BrowserCast (removable feature) — serves the live projection to a TV's
    // web browser over the LAN. Reads projectionService to choose MJPEG vs
    // native-video delivery; its capture source item is wired in Main.qml.
    crater::BrowserCastService browserCastService(&projectionService);
    // AI scripture narration (docs/narration.md). Constructing it does NOT
    // open the microphone — capture starts only on an explicit operator
    // arm() and there is no setting that changes that (§8). It takes
    // bibleService to validate that a heard reference actually exists,
    // projectionService to suppress re-sending what is already on screen,
    // and settingsService for the trust mode and model path.
    crater::NarrationService  narrationService(&bibleService, &projectionService,
                                               &settingsService);
    qInfo().noquote() << "[startup] crater-core services constructed: +"
                      << startupClock.elapsed() << "ms";

    // ─── Stage 4: register as QML singletons ────────────────────────────
    // Plain Q_OBJECTs registered via qmlRegisterSingletonInstance — main.cpp
    // owns the lifecycle, QML sees them as singletons under the "Crater" URI.
    qmlRegisterSingletonInstance("Crater", 1, 0, "BibleService",       &bibleService);
    qmlRegisterSingletonInstance("Crater", 1, 0, "StrongsService",     &strongsService);
    qmlRegisterSingletonInstance("Crater", 1, 0, "SongService",        &songService);
    qmlRegisterSingletonInstance("Crater", 1, 0, "CollectionService",  &collectionService);
    qmlRegisterSingletonInstance("Crater", 1, 0, "ScheduleService",    &scheduleService);
    qmlRegisterSingletonInstance("Crater", 1, 0, "ThemeService",       &themeService);
    qmlRegisterSingletonInstance("Crater", 1, 0, "MediaService",       &mediaService);
    qmlRegisterSingletonInstance("Crater", 1, 0, "FontService",        &fontService);
    qmlRegisterSingletonInstance("Crater", 1, 0, "OutputService",      &outputService);
    qmlRegisterSingletonInstance("Crater", 1, 0, "ProjectionService",  &projectionService);
    qmlRegisterSingletonInstance("Crater", 1, 0, "SettingsService",    &settingsService);
    qmlRegisterSingletonInstance("Crater", 1, 0, "NarrationService",   &narrationService);
    qmlRegisterSingletonInstance("Crater", 1, 0, "NdiService",         &ndiService);
    qmlRegisterSingletonInstance("Crater", 1, 0, "FileDialogService",     &fileDialogService);
    qmlRegisterSingletonInstance("Crater", 1, 0, "ClipboardService",      &clipboardService);
    qmlRegisterSingletonInstance("Crater", 1, 0, "LogReportService",      &logReportService);
    qmlRegisterSingletonInstance("Crater", 1, 0, "VideoThumbnailer",      &videoThumbnailer);
    qmlRegisterSingletonInstance("Crater", 1, 0, "MediaPlaybackService",  &mediaPlaybackService);
    qmlRegisterSingletonInstance("Crater", 1, 0, "LyricsService",         &lyricsService);
    qmlRegisterSingletonInstance("Crater", 1, 0, "RichTextHelper",        &richTextHelper);
    qmlRegisterSingletonInstance("Crater", 1, 0, "EasyWorshipImporter",   &easyWorshipImporter);
    qmlRegisterSingletonInstance("Crater", 1, 0, "BrowserCastService",    &browserCastService);  // BrowserCast (removable feature)
    // BrowserCast (removable feature) — the LAN server is started on demand
    // by the operator toggle in Settings > Remote Control, not at launch.

    // After every successful import, backfill thumbs for the new videos.
    // The ensureForAllVideos() walk is cheap when nothing is missing, so we
    // also call it once at startup to cover rows imported in prior sessions
    // (e.g. before this feature shipped, or after a thumbs/ dir wipe).
    QObject::connect(&mediaService, &crater::MediaService::importFinished,
                     &videoThumbnailer,
                     [&](int /*imported*/, int /*skipped*/) {
                         videoThumbnailer.ensureForAllVideos();
                     });
    videoThumbnailer.ensureForAllVideos();

    // When an EasyWorship import finishes, refresh SongService so the Songs
    // tab reflects the new songs immediately. The importer wrote songs.sqlite
    // directly on a worker thread, bypassing SongService's in-memory cache —
    // reload() drops that cache and emits allSongsChanged().
    QObject::connect(&easyWorshipImporter, &crater::EasyWorshipImporter::completed,
                     &songService,
                     [&songService](int /*imported*/, int /*skipped*/) {
                         songService.reload();
                     });

    // Warm up pdfium on a worker thread now so the operator's first PDF
    // view doesn't pay its multi-second one-time global init. No-op when
    // the library has no PDF — see MediaService::prewarmPdf.
    //
    // The before/after elapsed bracket measures only what prewarmPdf()
    // costs the MAIN thread (queuing a QtConcurrent::run task). pdfium's
    // actual cold init runs on the worker and is deliberately NOT counted
    // here — if this delta isn't tiny, the warm-up isn't as off-thread as
    // the design assumes, and that's the bug to chase.
    const qint64 beforePrewarm = startupClock.elapsed();
    mediaService.prewarmPdf();
    qInfo().noquote() << "[startup] pdfium prewarm dispatched (main-thread cost"
                      << (startupClock.elapsed() - beforePrewarm) << "ms): +"
                      << startupClock.elapsed() << "ms";

    // WorkingTheme is per-instance (one per open editor), not a singleton —
    // each invocation of the theme editor creates a fresh one in QML.
    qmlRegisterType<crater::WorkingTheme>("Crater", 1, 0, "WorkingTheme");

    // ─── Stage 5: launch QML ────────────────────────────────────────────
    QQmlApplicationEngine engine;

    QObject::connect(&engine, &QQmlEngine::warnings,
                     [](const QList<QQmlError>& warnings) {
                         for (const QQmlError& w : warnings) {
                             qWarning().noquote() << "QML:" << w.toString();
                         }
                     });

    QObject::connect(
        &engine,
        &QQmlApplicationEngine::objectCreationFailed,
        &app,
        []() {
            qCritical() << "QML object creation failed — see warnings above. Exiting.";
            QCoreApplication::exit(-1);
        },
        Qt::QueuedConnection);

    // ─── UI language ────────────────────────────────────────────────────
    // Install the operator's chosen translation catalog BEFORE loadFromModule
    // so the very first paint is already localized (no retranslate needed
    // pre-load). TranslationService also owns the LIVE switch: writing
    // SettingsService.language — or calling TranslationService.setLanguage() —
    // swaps the QTranslator and calls engine.retranslate(), re-evaluating every
    // qsTr() binding across the console with no restart. Must come after the
    // engine exists (it holds the engine to retranslate) and before QML loads
    // (so the singleton resolves and the catalog is already installed).
    crater::TranslationService translationService(&app, &engine, &settingsService);
    translationService.applyPersistedLanguage();
    qmlRegisterSingletonInstance("Crater", 1, 0, "TranslationService", &translationService);

    // Register the PDF image provider BEFORE loading QML so any binding
    // hit during component creation can already resolve image://pdfpage/...
    // URLs. The engine takes ownership of the provider (per Qt docs) — we
    // hand off a heap-allocated instance and never delete it ourselves.
    engine.addImageProvider(QStringLiteral("pdfpage"),
                            new crater::PdfPageImageProvider(&mediaService));

    qInfo() << "Loading QML from module Crater / Main";
    engine.loadFromModule("Crater", "Main");
    qInfo().noquote() << "[startup] QML loaded, main window realized: +"
                      << startupClock.elapsed() << "ms";

    // Hand the operator console back to the Windows shell. Must come after
    // loadFromModule — the HWND does not exist until the root Window is
    // realized — and it is scoped to that one window on purpose: the
    // projection window owns its own fullscreen/windowed chrome and must
    // not be given a resize frame. See WindowChrome.h for why the frameless
    // hint costs us Win+Arrow in the first place.
    if (!engine.rootObjects().isEmpty()) {
        if (auto* consoleWindow =
                qobject_cast<QQuickWindow*>(engine.rootObjects().constFirst())) {
            crater::installNativeWindowChrome(consoleWindow);
        }
    }

    // ─── Stage 6: wire the headless NDI renderer ────────────────────────
    // Must come AFTER loadFromModule — the renderer shares the engine to
    // resolve the Crater singletons (ProjectionService, SettingsService,
    // AppState, etc.). Loading Main.qml first ensures the Crater module
    // is registered so the inline scene QML in NdiRenderer can `import
    // Crater`. NdiService.start() picks the headless path when
    // SettingsService.useHeadlessNdi is true and this renderer's start()
    // succeeds; otherwise it falls back to the legacy grabToImage path.
    // The renderer instance lives for the app's lifetime — start/stop is
    // gated by NdiService.
    crater::NdiRenderer ndiRenderer(&engine);
    ndiService.setRenderer(&ndiRenderer);
    qInfo().noquote() << "[startup] NDI renderer ready, entering event loop: +"
                      << startupClock.elapsed() << "ms";

    return app.exec();
}
