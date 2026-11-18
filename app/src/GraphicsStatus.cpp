#include "GraphicsStatus.h"

#include "StartupGuard.h"

namespace crater {

GraphicsStatus::GraphicsStatus(QObject* parent)
    : QObject(parent)
    , m_noticeVisible(startup::switchedToOpenGl())
{
}

QString GraphicsStatus::mode() const
{
    switch (startup::graphicsMode()) {
    case graphics::Mode::OpenGl:   return QStringLiteral("opengl");
    case graphics::Mode::Warp:     return QStringLiteral("warp");
    case graphics::Mode::Software: return QStringLiteral("software");
    case graphics::Mode::Direct3D: break;
    }
    return QStringLiteral("direct3d");
}

bool GraphicsStatus::chosenByHand() const
{
    return startup::graphicsChosenByHand();
}

QString GraphicsStatus::driverCrash() const
{
    return startup::openGlReason();
}

void GraphicsStatus::resetToDefault()
{
    if (m_resetPending) return;
    startup::resetGraphics();
    m_resetPending = true;
    m_noticeVisible = false;
    emit changed();
}

void GraphicsStatus::dismissNotice()
{
    if (!m_noticeVisible) return;
    m_noticeVisible = false;
    emit changed();
}

}  // namespace crater
