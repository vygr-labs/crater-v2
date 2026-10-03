#include "ProjectionLayering.h"

#include <QCoreApplication>
#include <QTimer>
#include <QVariant>

#ifdef Q_OS_WIN
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  ifndef NOMINMAX
#    define NOMINMAX
#  endif
#  include <windows.h>
#endif

namespace crater {

#ifdef Q_OS_WIN
namespace {

// The HWND of a window that already has one. Never creates the native
// window: the filter runs for every message in the app, and forcing the
// projection's HWND into existence from in here would be a surprising side
// effect. Looked up each time rather than cached because Qt can recreate an
// HWND (some flag changes do), and a stale handle would silently disable
// every rule below.
HWND hwndOf(const QWindow* w)
{
    return (w && w->handle()) ? reinterpret_cast<HWND>(w->winId()) : nullptr;
}

}  // namespace
#endif

ProjectionLayering::ProjectionLayering(QObject* parent)
    : QObject(parent)
{
#ifdef Q_OS_WIN
    // ~QAbstractNativeEventFilter unregisters itself, so no matching remove.
    if (auto* app = QCoreApplication::instance())
        app->installNativeEventFilter(this);
#endif
}

void ProjectionLayering::attach(QWindow* projection, QWindow* console)
{
    m_projection = projection;
    m_console = console;
    applyShowWithoutActivating();
    if (m_on) scheduleRestack();
}

void ProjectionLayering::setBehindConsole(bool on)
{
    if (m_on == on) return;
    m_on = on;
    m_forward = false;
    m_skipNextRelease = false;
    applyShowWithoutActivating();
    // Turning it on while the projection is already up (the setting flipped
    // mid-service, or the console was dragged onto the output's display)
    // tucks it under the console straight away. Turning it off leaves
    // z-order to the Qt flags ProjectionWindow.qml switches to.
    if (on) scheduleRestack();
}

void ProjectionLayering::applyShowWithoutActivating()
{
    // Read by Qt's Windows backend at show time (it is how QWidget's
    // WA_ShowWithoutActivating reaches the platform), turning the ShowWindow
    // call into SW_SHOWNOACTIVATE. An invalid QVariant removes the dynamic
    // property, restoring the default activate-on-show behaviour that the
    // multi-display fullscreen output relies on.
    if (!m_projection) return;
    m_projection->setProperty("_q_showWithoutActivating",
                              m_on ? QVariant(true) : QVariant());
}

void ProjectionLayering::sendBehind()
{
    if (!m_on) return;
    m_forward = false;
    m_skipNextRelease = false;

#ifdef Q_OS_WIN
    // The console may have been minimised while the output was in front.
    // Activating a minimised window does not restore it, which would leave
    // the operator looking at the output with no console anywhere.
    // SW_RESTORE brings it back to its previous (maximised) placement.
    if (HWND con = hwndOf(m_console); con && IsIconic(con))
        ShowWindow(con, SW_RESTORE);
#endif

    restack();
    if (m_console) {
        m_console->raise();
        m_console->requestActivate();
    }
}

void ProjectionLayering::outputClicked()
{
    if (!m_on || !m_forward) return;
    if (m_skipNextRelease) {
        // The click that brought it forward. Consume it.
        m_skipNextRelease = false;
        return;
    }
    // Queued so the click finishes its delivery before activation moves.
    QTimer::singleShot(0, this, &ProjectionLayering::sendBehind);
}

void ProjectionLayering::scheduleRestack()
{
    // Deferred because the triggers arrive mid-way through a Windows
    // activation or show sequence, and re-stacking from inside one of those
    // messages fights the sequence still in progress. Coalesced so a burst
    // of messages does one SetWindowPos. restack() reads m_forward when it
    // RUNS, so whichever of a racing activate / deactivate pair lands last
    // decides the outcome.
    if (m_restackQueued) return;
    m_restackQueued = true;
    QTimer::singleShot(0, this, &ProjectionLayering::restack);
}

void ProjectionLayering::restack()
{
    m_restackQueued = false;
#ifdef Q_OS_WIN
    if (!m_on) return;
    HWND proj = hwndOf(m_projection);
    if (!proj || !IsWindowVisible(proj)) return;

    constexpr UINT kFlags = SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE
                          | SWP_NOOWNERZORDER;
    if (m_forward) {
        SetWindowPos(proj, HWND_TOP, 0, 0, 0, 0, kFlags);
        return;
    }
    HWND con = hwndOf(m_console);
    if (!con || !IsWindow(con)) return;
    // hWndInsertAfter = the console places the projection immediately below
    // it. Windows the console was already in front of stay where they were,
    // so a browser the operator had open behind Crater is not buried by a
    // full-screen output. Inserting after a non-topmost window also strips
    // WS_EX_TOPMOST if a previous mode left it on.
    SetWindowPos(proj, con, 0, 0, 0, 0, kFlags);
#endif
}

bool ProjectionLayering::nativeEventFilter(const QByteArray& eventType,
                                           void* message, qintptr* result)
{
#ifdef Q_OS_WIN
    if (!m_on) return false;
    if (eventType != QByteArrayLiteral("windows_generic_MSG")) return false;

    auto* msg = static_cast<MSG*>(message);
    if (!msg) return false;
    HWND proj = hwndOf(m_projection);
    if (!proj || msg->hwnd != proj) return false;

    switch (msg->message) {
    case WM_WINDOWPOSCHANGING: {
        // While behind, the only legal z position is directly under the
        // console. Rewriting the request here (rather than correcting after
        // the fact) means the window never paints a frame in front of the
        // console. Applied to every change, including Qt's setGeometry calls
        // that carry SWP_NOZORDER: a window parked offscreen for NDI keeps
        // whatever z position it had, and the move onscreen at go-live would
        // otherwise reveal it on top. Clearing SWP_NOZORDER and setting
        // hwndInsertAfter is the documented way to force an order from here.
        if (m_forward) return false;
        HWND con = hwndOf(m_console);
        if (!con || con == proj || !IsWindow(con)) return false;
        auto* wp = reinterpret_cast<WINDOWPOS*>(msg->lParam);
        if (!wp) return false;
        wp->flags &= ~UINT(SWP_NOZORDER);
        wp->hwndInsertAfter = con;
        return false;  // Qt still runs its own geometry handling
    }

    case WM_MOUSEACTIVATE:
        // A click on the visible part of the output while it is behind.
        // Flip to forward BEFORE Windows re-stacks for the activation, so
        // the WM_WINDOWPOSCHANGING above lets it rise. MA_ACTIVATE is
        // returned explicitly so keyboard focus always follows: an output
        // in front without focus would have no Escape exit, which is the
        // trap this whole class exists to rule out.
        if (!m_forward) {
            m_forward = true;
            m_skipNextRelease = (HIWORD(msg->lParam) == WM_LBUTTONDOWN);
        }
        if (result) *result = MA_ACTIVATE;
        return true;

    case WM_ACTIVATE:
        if (LOWORD(msg->wParam) == WA_INACTIVE) {
            // The operator went anywhere else: the console, another app,
            // the desktop. Back under the console.
            m_skipNextRelease = false;
            if (m_forward) {
                m_forward = false;
                scheduleRestack();
            }
        } else if (!m_forward) {
            // Activated without a mouse click reaching WM_MOUSEACTIVATE:
            // its taskbar button, Alt-Tab, or a touch / pen tap. All are a
            // request to see it, so bring it forward. The activation's own
            // re-stack was already pinned under the console by the guard
            // above, hence the explicit restack. A tap reports
            // WA_CLICKACTIVE and, like a mouse click, is followed by a
            // release that must not count as the click back.
            m_forward = true;
            m_skipNextRelease = (LOWORD(msg->wParam) == WA_CLICKACTIVE);
            scheduleRestack();
        }
        return false;  // Qt tracks focus off this message too

    case WM_SHOWWINDOW:
        // Every show starts behind. A go-live never opens in front of the
        // console, even if it was in front when it was last lowered.
        if (msg->wParam) {
            m_forward = false;
            m_skipNextRelease = false;
            scheduleRestack();
        }
        return false;

    default:
        return false;
    }
#else
    Q_UNUSED(eventType)
    Q_UNUSED(message)
    Q_UNUSED(result)
    return false;
#endif
}

}  // namespace crater
