#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFont>
#include <QFontDatabase>
#include <QFuture>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlEngine>
#include <QQmlError>
#include <QQuickStyle>
#include <QStandardPaths>
#include <QTextStream>
#include <QtQml>

#include "crater/BibleService.h"
#include "crater/Bootstrap.h"
#include "crater/ElectronDataImporter.h"
#include "crater/MediaService.h"
#include "crater/OutputService.h"
#include "crater/ProjectionService.h"
#include "crater/ScheduleService.h"
#include "crater/SongService.h"
#include "crater/ThemeService.h"
#include "crater/Version.h"

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

// Establish the application-wide default font with a real fallback chain.
// QML's `font` value type only exposes `family` (not `families`), so we
// install fallbacks here at the QFont level. Anything that doesn't override
// `font.family` in QML inherits this and gets the same fallback behavior.
void initDefaultFont()
{
    QFont f;
    f.setFamilies({
        QStringLiteral("Segoe UI Variable Display"),
        QStringLiteral("Segoe UI"),
        QStringLiteral(".AppleSystemUIFont"),
        QStringLiteral("SF Pro Display"),
        QStringLiteral("Inter"),
        QStringLiteral("Cantarell"),
        QStringLiteral("Helvetica Neue"),
    });
    f.setPixelSize(13);
    QGuiApplication::setFont(f);
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

}  // namespace

int main(int argc, char* argv[])
{
    QGuiApplication::setOrganizationName(QStringLiteral("Voyager Labs"));
    QGuiApplication::setOrganizationDomain(QStringLiteral("voyagerlabs.tech"));
    QGuiApplication::setApplicationName(QStringLiteral("Crater"));
    QGuiApplication::setApplicationVersion(crater::versionString());

    qputenv("QT_QUICK_CONTROLS_STYLE", "Basic");

    QGuiApplication app(argc, argv);

    const QString logPath = initLogging();
    qInfo().noquote() << "──────── Crater" << crater::versionString() << "starting ────────";
    qInfo().noquote() << "Log file:" << logPath;

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
    crater::SongService       songService;
    crater::ScheduleService   scheduleService;
    crater::ThemeService      themeService;
    crater::MediaService      mediaService;
    crater::OutputService     outputService;
    crater::ProjectionService projectionService;

    // ─── Stage 4: register as QML singletons ────────────────────────────
    // Plain Q_OBJECTs registered via qmlRegisterSingletonInstance — main.cpp
    // owns the lifecycle, QML sees them as singletons under the "Crater" URI.
    qmlRegisterSingletonInstance("Crater", 1, 0, "BibleService",      &bibleService);
    qmlRegisterSingletonInstance("Crater", 1, 0, "SongService",       &songService);
    qmlRegisterSingletonInstance("Crater", 1, 0, "ScheduleService",   &scheduleService);
    qmlRegisterSingletonInstance("Crater", 1, 0, "ThemeService",      &themeService);
    qmlRegisterSingletonInstance("Crater", 1, 0, "MediaService",      &mediaService);
    qmlRegisterSingletonInstance("Crater", 1, 0, "OutputService",     &outputService);
    qmlRegisterSingletonInstance("Crater", 1, 0, "ProjectionService", &projectionService);

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

    qInfo() << "Loading QML from module Crater / Main";
    engine.loadFromModule("Crater", "Main");

    return app.exec();
}
