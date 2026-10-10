#pragma once

// Native window-management chrome for the frameless operator console.
//
// The console draws its own title bar (panels/TitleBar.qml) and asks Qt for
// Qt::FramelessWindowHint to get rid of the OS one. On Windows that hint does
// more than hide the caption: the HWND is created as a bare WS_POPUP with the
// frame styles stripped, and the shell reads exactly those styles to decide
// whether a window can be arranged. Result: Win+Left / Win+Right / Win+Up /
// Win+Down, Win+Shift+Arrow, Aero Shake, the taskbar right-click window menu
// and the Windows 11 snap-layouts flyout are all silently inert — the shell
// never treats the console as a snap candidate, so the keystroke is not
// refused, it simply goes nowhere.
//
// Dragging the window to a screen edge kept working because that path runs
// through Window.startSystemMove, which hands the drag to the window manager.
// Keyboard snapping never touches that code, which is why the two behaved
// differently.
//
// The fix is the one Chrome, VS Code and Windows Terminal use: put the real
// frame styles back so the shell sees an ordinary resizable window, and remove
// the frame *visually* by telling Windows the client area covers the whole
// window rect (WM_NCCALCSIZE). The console looks identical; the shell now
// recognises it.
//
// No-op on every other platform — X11 and macOS window managers key off the
// window type, not a frame style, and both already arrange frameless windows.

#include <QObject>

class QQuickWindow;
class QWindow;

namespace crater {

// Call once, after the QML root window exists. Safe to call with nullptr.
void installNativeWindowChrome(QQuickWindow* window);

// Restore-down size and position for the console. Crater opens maximized,
// and Qt's restore size was the 1440x900 that Main.qml declared, which on
// a laptop at 125% scaling is the whole screen: the restore button looked
// like it did nothing. This gives Windows a restore rectangle of its own:
// the one the operator last left the window at, if a connected screen
// still holds it, otherwise 80% of the console's screen, centred. The
// window also reopens the way it was left (maximized or not), and every
// later move, resize or snap is saved under Window/ in QSettings.
//
// Call once, after installNativeWindowChrome. No-op off Windows: macOS and
// Linux window managers keep their own restore size for a maximized window.
void restoreWindowPlacement(QQuickWindow* window);

// The title bar's maximize / restore button, as the QML singleton
// WindowControls. On Windows, Qt maximizes a frameless window by stretching
// it over the work area itself and restores it to a size it noted when it
// first did that. That bypasses the restore rectangle above (restore went
// back to almost full screen) and, mixed with a real Windows maximize from
// Win+Up or from restoreWindowPlacement, made the window flash on the first
// click. This asks Windows instead, the same path Win+Up and a double-click
// on a native caption take. Qt follows along through WM_SIZE, so
// Window.visibility in QML stays right. Elsewhere it is plain
// showMaximized() / showNormal().
class WindowControls : public QObject
{
    Q_OBJECT
public:
    using QObject::QObject;
    Q_INVOKABLE void toggleMaximized(QWindow* window);
    // How far, in logical pixels, a maximized console hangs past each screen
    // edge (see installNativeWindowChrome). 0 off Windows.
    Q_INVOKABLE qreal maximizedInset(QWindow* window) const;
};

}  // namespace crater
