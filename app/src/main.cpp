#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QSurfaceFormat>

#include "crater/Version.h"

int main(int argc, char *argv[])
{
    // Hint Qt RHI toward D3D11 on Windows (HD 4000 supports FL 11.0).
    // Override at runtime with: QSG_RHI_BACKEND=opengl|vulkan|d3d11
    qputenv("QT_QUICK_CONTROLS_STYLE", "Basic");

    QGuiApplication app(argc, argv);
    QGuiApplication::setOrganizationName("Voyager Labs");
    QGuiApplication::setOrganizationDomain("voyagerlabs.tech");
    QGuiApplication::setApplicationName("Crater");
    QGuiApplication::setApplicationVersion(crater::versionString());

    QQuickStyle::setStyle(QStringLiteral("Basic"));

    QQmlApplicationEngine engine;
    QObject::connect(
        &engine,
        &QQmlApplicationEngine::objectCreationFailed,
        &app,
        []() { QCoreApplication::exit(-1); },
        Qt::QueuedConnection);

    engine.loadFromModule("Crater", "Main");

    return app.exec();
}
