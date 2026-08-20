#include "WindowChrome.h"

#include <QQuickWindow>

#ifdef Q_OS_WIN

#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  ifndef NOMINMAX
#    define NOMINMAX
#  endif
#  include <windows.h>

#  include <QAbstractNativeEventFilter>
#  include <QCoreApplication>

namespace {

// Watches one HWND and answers the two messages that decide whether Windows
// draws a frame and how large "maximized" is. Every other message falls
// through to Qt untouched, and messages for any other window (the projection
// window, popups, the NDI offscreen surface) are ignored outright.
class ChromeFilter final : public QAbstractNativeEventFilter
{
public:
    void watch(HWND hwnd) { m_hwnd = hwnd; }

    bool nativeEventFilter(const QByteArray& type, void* message, qintptr* result) override
    {
        if (type != QByteArrayLiteral("windows_generic_MSG")) return false;

        auto* msg = static_cast<MSG*>(message);
        if (!msg || msg->hwnd != m_hwnd) return false;

        switch (msg->message) {
        case WM_NCCALCSIZE:
            // wParam TRUE means "given this window rect, tell me the client
            // rect". Returning 0 leaves the proposed rectangle exactly as it
            // came in, so the client area IS the whole window: Windows
            // reserves no caption and no sizing border, and therefore paints
            // neither. The frame styles stay on the HWND, which is the whole
            // point — the shell reads them, the operator never sees them.
            //
            // Losing the non-client area also means WM_NCHITTEST can only
            // ever return HTCLIENT, so there are no native resize edges. That
            // costs nothing here: TitleBar.qml already drives resizing and
            // dragging through Window.startSystemResize / startSystemMove.
            if (msg->wParam == TRUE) {
                *result = 0;
                return true;
            }
            return false;

        case WM_GETMINMAXINFO: {
            // With WS_THICKFRAME on, Windows maximizes to the work area
            // INFLATED by the resize border it expects to draw. We just told
            // it there is no border, so that inflation would push the console
            // a few pixels off every screen edge and under the taskbar.
            //
            // Pinning the maximized rect to the monitor work area keeps the
            // geometry byte-identical to what it was before the frame styles
            // went on (measured: window rect == work area, zero overshoot),
            // so this change is invisible in the maximized state it spends
            // nearly all its time in.
            //
            // ptMaxTrackSize is deliberately left alone. Clamping it would
            // cap the window at the CURRENT monitor's work area, which breaks
            // Win+Shift+Arrow onto a larger display.
            HMONITOR mon = MonitorFromWindow(msg->hwnd, MONITOR_DEFAULTTONEAREST);
            if (!mon) return false;

            MONITORINFO mi {};
            mi.cbSize = sizeof(mi);
            if (!GetMonitorInfoW(mon, &mi)) return false;

            auto* mmi = reinterpret_cast<MINMAXINFO*>(msg->lParam);
            mmi->ptMaxPosition.x = mi.rcWork.left - mi.rcMonitor.left;
            mmi->ptMaxPosition.y = mi.rcWork.top - mi.rcMonitor.top;
            mmi->ptMaxSize.x     = mi.rcWork.right - mi.rcWork.left;
            mmi->ptMaxSize.y     = mi.rcWork.bottom - mi.rcWork.top;
            *result = 0;
            return true;
        }

        default:
            return false;
        }
    }

private:
    HWND m_hwnd = nullptr;
};

}  // namespace

#endif  // Q_OS_WIN

void crater::installNativeWindowChrome(QQuickWindow* window)
{
#ifdef Q_OS_WIN
    if (!window) return;

    auto hwnd = reinterpret_cast<HWND>(window->winId());
    if (!hwnd) return;

    // One filter for the app's lifetime. QCoreApplication does not take
    // ownership of a native event filter, so this deliberately leaks a single
    // small object rather than risk a dangling filter during teardown.
    static ChromeFilter* filter = nullptr;
    if (!filter) {
        filter = new ChromeFilter;
        QCoreApplication::instance()->installNativeEventFilter(filter);
    }
    filter->watch(hwnd);

    // Put the frame styles back:
    //   WS_THICKFRAME  — marks the window resizable. Gates Win+Left/Right.
    //   WS_MAXIMIZEBOX — gates Win+Up and the Win11 snap-layouts flyout.
    //   WS_MINIMIZEBOX — gates Win+Down.
    //   WS_SYSMENU     — restores the taskbar right-click window menu
    //                    (Move / Size / Minimize / Maximize / Close).
    // WS_CAPTION is intentionally NOT added. Snapping does not need it, and
    // on a window whose non-client area has been zeroed it can leave a 1px
    // light line along the top edge in the restored state.
    const LONG_PTR style = GetWindowLongPtr(hwnd, GWL_STYLE);
    SetWindowLongPtr(hwnd, GWL_STYLE,
                     style | WS_THICKFRAME | WS_MAXIMIZEBOX | WS_MINIMIZEBOX
                         | WS_SYSMENU);

    // A style change does not take effect until the frame is recalculated.
    // SWP_FRAMECHANGED is what re-sends WM_NCCALCSIZE, letting the filter
    // above strip the border Windows would otherwise begin drawing now that
    // WS_THICKFRAME is set. Without this call the console would grow an
    // 8px native frame.
    SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE
                     | SWP_FRAMECHANGED);
#else
    Q_UNUSED(window)
#endif
}
