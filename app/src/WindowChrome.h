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

class QQuickWindow;

namespace crater {

// Call once, after the QML root window exists. Safe to call with nullptr.
void installNativeWindowChrome(QQuickWindow* window);

}  // namespace crater
