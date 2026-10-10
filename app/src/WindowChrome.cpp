#include "WindowChrome.h"

#include <QGuiApplication>
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
#  include <QRect>
#  include <QSettings>
#  include <QTimer>

namespace {

// Watches one HWND: answers WM_NCCALCSIZE, which decides whether Windows
// draws a frame, and notes moves and sizes for restoreWindowPlacement.
// Every other message falls through to Qt untouched, and messages for any
// other window (the projection window, popups, the NDI offscreen surface)
// are ignored outright.
class ChromeFilter final : public QAbstractNativeEventFilter
{
public:
    void watch(HWND hwnd) { m_hwnd = hwnd; }
    // Restarted on every move and size so the placement is saved once the
    // window settles (see restoreWindowPlacement). Null until then.
    void setSaveTimer(QTimer* timer) { m_saveTimer = timer; }

    bool nativeEventFilter(const QByteArray& type, void* message, qintptr* result) override
    {
        if (type != QByteArrayLiteral("windows_generic_MSG")) return false;

        auto* msg = static_cast<MSG*>(message);
        if (!msg || msg->hwnd != m_hwnd) return false;

        switch (msg->message) {
        case WM_SIZE:
        case WM_MOVE:
            if (m_saveTimer) m_saveTimer->start();
            return false;

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

        default:
            return false;
        }
    }

private:
    HWND    m_hwnd = nullptr;
    QTimer* m_saveTimer = nullptr;
};

ChromeFilter* g_filter = nullptr;

constexpr const char* kNormalRect = "Window/normalRect";
constexpr const char* kMaximized  = "Window/maximized";

// GetWindowPlacement / SetWindowPlacement speak workspace coordinates,
// which start below or right of a taskbar docked to the top or left of the
// monitor. This is the shift between those and plain screen coordinates.
QPoint workspaceOffset(const RECT& r)
{
    HMONITOR mon = MonitorFromRect(&r, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi {};
    mi.cbSize = sizeof(mi);
    if (!mon || !GetMonitorInfoW(mon, &mi)) return {};
    return { int(mi.rcWork.left - mi.rcMonitor.left), int(mi.rcWork.top - mi.rcMonitor.top) };
}

void savePlacement(HWND hwnd)
{
    // Minimized or hidden (closing) says nothing about where the operator
    // wants the window, so the last good placement stands.
    if (!IsWindowVisible(hwnd) || IsIconic(hwnd)) return;
    WINDOWPLACEMENT wp {};
    wp.length = sizeof(wp);
    if (!GetWindowPlacement(hwnd, &wp)) return;

    const RECT& r = wp.rcNormalPosition;
    const QPoint off = workspaceOffset(r);
    const QRect rect(r.left + off.x(), r.top + off.y(), r.right - r.left, r.bottom - r.top);
    if (rect.width() <= 0 || rect.height() <= 0) return;

    QSettings s;
    s.setValue(QString::fromLatin1(kNormalRect), rect);
    s.setValue(QString::fromLatin1(kMaximized), wp.showCmd == SW_SHOWMAXIMIZED);
}

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
    if (!g_filter) {
        g_filter = new ChromeFilter;
        QCoreApplication::instance()->installNativeEventFilter(g_filter);
    }
    g_filter->watch(hwnd);

    // Put the frame styles back:
    //   WS_CAPTION     — what Windows checks before it animates minimize,
    //                    maximize and restore. Without it the window jumps.
    //   WS_THICKFRAME  — marks the window resizable. Gates Win+Left/Right.
    //   WS_MAXIMIZEBOX — gates Win+Up and the Win11 snap-layouts flyout.
    //   WS_MINIMIZEBOX — gates Win+Down.
    //   WS_SYSMENU     — restores the taskbar right-click window menu
    //                    (Move / Size / Minimize / Maximize / Close).
    // With WS_CAPTION, a maximized window hangs past every screen edge by
    // the resize border Windows expects to draw (9 px at 125%), the usual
    // behaviour for captioned windows. Main.qml insets its content by
    // WindowControls.maximizedInset() to match.
    const LONG_PTR style = GetWindowLongPtr(hwnd, GWL_STYLE);
    SetWindowLongPtr(hwnd, GWL_STYLE,
                     style | WS_CAPTION | WS_THICKFRAME | WS_MAXIMIZEBOX | WS_MINIMIZEBOX
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

void crater::restoreWindowPlacement(QQuickWindow* window)
{
#ifdef Q_OS_WIN
    // Under the offscreen test platform winId() is not an HWND.
    if (!window || QGuiApplication::platformName() != QLatin1String("windows")) return;
    auto hwnd = reinterpret_cast<HWND>(window->winId());
    if (!hwnd || !g_filter) return;

    QSettings s;
    const QRect saved = s.value(QString::fromLatin1(kNormalRect)).toRect();
    const bool maximized = s.value(QString::fromLatin1(kMaximized), true).toBool();

    // The saved rectangle counts only while a connected screen still holds
    // part of it. Everything here is in physical pixels, the same unit
    // GetWindowPlacement handed out when it was saved.
    QRect target;
    RECT work {};
    if (saved.isValid()) {
        const RECT r { saved.left(), saved.top(), saved.right() + 1, saved.bottom() + 1 };
        if (HMONITOR mon = MonitorFromRect(&r, MONITOR_DEFAULTTONULL)) {
            MONITORINFO mi {};
            mi.cbSize = sizeof(mi);
            if (GetMonitorInfoW(mon, &mi)) {
                work = mi.rcWork;
                target = saved;
            }
        }
    }
    if (target.isNull()) {
        // First run, or its screen is gone: 80% of the work area of the
        // screen the console opened on, centred, and never smaller than the
        // console's minimum size.
        HMONITOR mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        MONITORINFO mi {};
        mi.cbSize = sizeof(mi);
        if (!mon || !GetMonitorInfoW(mon, &mi)) return;
        work = mi.rcWork;
        const qreal dpr = window->devicePixelRatio();
        const int ww = work.right - work.left, wh = work.bottom - work.top;
        const int w = qMax(int(ww * 0.8), int(window->minimumWidth() * dpr));
        const int h = qMax(int(wh * 0.8), int(window->minimumHeight() * dpr));
        target = QRect(work.left + (ww - w) / 2, work.top + (wh - h) / 2, w, h);
    }

    // Keep it inside that screen's work area: shrink it if the screen got
    // smaller since, then slide it fully on screen.
    const QRect area(work.left, work.top, work.right - work.left, work.bottom - work.top);
    target.setWidth(qMin(target.width(), area.width()));
    target.setHeight(qMin(target.height(), area.height()));
    target.moveLeft(qBound(area.left(), target.left(), area.right() + 1 - target.width()));
    target.moveTop(qBound(area.top(), target.top(), area.bottom() + 1 - target.height()));

    WINDOWPLACEMENT wp {};
    wp.length = sizeof(wp);
    if (!GetWindowPlacement(hwnd, &wp)) return;
    RECT r { target.left(), target.top(), target.right() + 1, target.bottom() + 1 };
    const QPoint off = workspaceOffset(r);
    OffsetRect(&r, -off.x(), -off.y());
    wp.rcNormalPosition = r;
    wp.showCmd = maximized ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL;
    wp.flags = 0;
    SetWindowPlacement(hwnd, &wp);

    // Save from here on, half a second after the last move or size, so a
    // drag writes once rather than on every step.
    auto* timer = new QTimer(window);
    timer->setSingleShot(true);
    timer->setInterval(500);
    QObject::connect(timer, &QTimer::timeout, window, [hwnd] { savePlacement(hwnd); });
    g_filter->setSaveTimer(timer);
#else
    Q_UNUSED(window)
#endif
}

void crater::WindowControls::toggleMaximized(QWindow* window)
{
    if (!window) return;
    const bool qtMaximized = window->visibility() == QWindow::Maximized;
#ifdef Q_OS_WIN
    if (QGuiApplication::platformName() == QLatin1String("windows")) {
        auto hwnd = reinterpret_cast<HWND>(window->winId());
        if (IsZoomed(hwnd)) {
            ShowWindow(hwnd, SW_RESTORE);
            return;
        }
        if (!qtMaximized) {
            ShowWindow(hwnd, SW_MAXIMIZE);
            return;
        }
        // Maximized by Qt's own stretch, because restoreWindowPlacement did
        // not get to swap it for a real maximize. Only Qt can undo that.
    }
#endif
    if (qtMaximized) window->showNormal();
    else             window->showMaximized();
}

qreal crater::WindowControls::maximizedInset(QWindow* window) const
{
#ifdef Q_OS_WIN
    if (window && QGuiApplication::platformName() == QLatin1String("windows")) {
        auto hwnd = reinterpret_cast<HWND>(window->winId());
        const UINT dpi = GetDpiForWindow(hwnd);
        const int px = GetSystemMetricsForDpi(SM_CXFRAME, dpi)
                     + GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
        return px / window->devicePixelRatio();
    }
#else
    Q_UNUSED(window)
#endif
    return 0;
}
