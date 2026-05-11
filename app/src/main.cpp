#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFont>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlEngine>
#include <QQmlError>
#include <QQuickStyle>
#include <QStandardPaths>
#include <QTextStream>

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
    g_logFile->open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text);

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
