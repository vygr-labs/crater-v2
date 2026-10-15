#include "SingleInstance.h"

#include "StartupGuard.h"

#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDebug>
#include <QDir>
#include <QElapsedTimer>
#include <QGuiApplication>
#include <QLocalServer>
#include <QLocalSocket>
#include <QLockFile>
#include <QPointer>
#include <QThread>
#include <QWindow>

#include <cstring>
#include <memory>

#ifdef Q_OS_WIN
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  ifndef NOMINMAX
#    define NOMINMAX
#  endif
#  include <windows.h>
#endif

namespace crater::instance {

namespace {

// Held for the life of the process. The OS drops it when the process ends,
// however it ends, so a crashed Crater never locks the next one out.
std::unique_ptr<QLockFile> g_lock;
QPointer<QWindow> g_console;

// How long a relaunch Crater made itself waits for the old process to let
// go. Closing normally takes well under a second; a slow disk or a large
// schedule save can take a few.
constexpr int kRelaunchWaitMs = 20000;
// How long a second launch keeps trying to reach the running one. The
// running one listens right after QApplication exists, so this only matters
// when both were started at the same moment.
constexpr int kReachMs = 5000;

QString lockPath()
{
    return QDir(startup::stateDirectory()).filePath(QStringLiteral("crater.lock"));
}

// Named after the lock's folder, which is per user, so two users on one PC
// (or a test copy pointed at its own folder) never reach each other.
QString serverName()
{
    const QByteArray key = QDir::cleanPath(startup::stateDirectory()).toLower().toUtf8();
    return QStringLiteral("crater-")
           + QString::fromLatin1(QCryptographicHash::hash(key, QCryptographicHash::Sha1).toHex().left(16));
}

bool isRelaunch(int argc, char* argv[])
{
    if (qEnvironmentVariableIsSet("CRATER_STARTUP_RETRY")) return true;   // graphics restart
    for (int i = 1; i < argc; ++i)
        if (std::strncmp(argv[i], "--profile=", 10) == 0) return true;   // profile switch
    return false;
}

// Asks the running Crater to show its console. Best effort: if it can't be
// reached it is still starting, and its console will appear on its own.
void askRunningToShow(int argc, char* argv[])
{
    QCoreApplication app(argc, argv);

#ifdef Q_OS_WIN
    // This launch came from the user, so Windows lets it hand the right to
    // take the foreground on to the running Crater. Without this the
    // console would only flash in the taskbar.
    qint64 pid = 0;
    QString host, appName;
    if (g_lock && g_lock->getLockInfo(&pid, &host, &appName) && pid > 0)
        AllowSetForegroundWindow(static_cast<DWORD>(pid));
#endif

    QElapsedTimer clock;
    clock.start();
    QLocalSocket socket;
    while (clock.elapsed() < kReachMs) {
        socket.connectToServer(serverName());
        if (socket.waitForConnected(500)) {
            socket.write("show\n");
            socket.waitForBytesWritten(1000);
            socket.disconnectFromServer();
            return;
        }
        QThread::msleep(100);
    }
}

void showConsole()
{
    QWindow* window = g_console.data();
    if (!window) return;
    qInfo().noquote() << "Another launch of Crater: bringing the console to the front";
#ifdef Q_OS_WIN
    if (QGuiApplication::platformName() == QLatin1String("windows")) {
        auto hwnd = reinterpret_cast<HWND>(window->winId());
        // SW_RESTORE puts a minimized console back the way it was,
        // maximized included, where showNormal() would un-maximize it.
        if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
        SetForegroundWindow(hwnd);
        return;
    }
#endif
    window->setWindowStates(window->windowStates() & ~Qt::WindowMinimized);
    window->show();
    window->raise();
    window->requestActivate();
}

}  // namespace

bool claim(int argc, char* argv[])
{
    QDir().mkpath(startup::stateDirectory());
    g_lock = std::make_unique<QLockFile>(lockPath());
    // Only a lock whose owner has exited is stale, however long it was held.
    g_lock->setStaleLockTime(0);

    if (g_lock->tryLock(isRelaunch(argc, argv) ? kRelaunchWaitMs : 0)) return true;

    // A folder that can't be written can't hold a lock either. Starting
    // unguarded is better than not starting.
    if (g_lock->error() != QLockFile::LockFailedError) {
        g_lock.reset();
        return true;
    }

    askRunningToShow(argc, argv);
    g_lock.reset();
    return false;
}

void listen()
{
    if (!g_lock) return;   // unguarded launch: nothing to answer for
    auto* server = new QLocalServer(QCoreApplication::instance());
    server->setSocketOptions(QLocalServer::UserAccessOption);
    // We hold the lock, so a socket left by a Crater that crashed is stale.
    QLocalServer::removeServer(serverName());
    if (!server->listen(serverName())) {
        qWarning().noquote() << "SingleInstance: could not listen:" << server->errorString();
        return;
    }
    QObject::connect(server, &QLocalServer::newConnection, server, [server] {
        while (QLocalSocket* socket = server->nextPendingConnection()) {
            QObject::connect(socket, &QLocalSocket::disconnected, socket, &QObject::deleteLater);
            QObject::connect(socket, &QLocalSocket::readyRead, socket, [socket] {
                if (socket->readAll().contains("show")) showConsole();
            });
        }
    });
}

void setConsole(QWindow* window)
{
    g_console = window;
}

}  // namespace crater::instance
