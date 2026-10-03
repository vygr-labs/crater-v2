#pragma once

// Keeps the audience projection BEHIND the operator console when both are on
// the same display, the way EasyWorship 7 does it on a single screen.
//
// The arrangement: the projection is a borderless window the size of the
// screen, sitting directly under the console in z-order. Wherever the console
// does not cover the screen, the operator sees the live output. A click on
// that visible output brings it forward over the console. A second click on
// it, Escape, Alt-Tab, or activating anything else sends it back behind.
//
// The rule underneath is a single invariant: the projection is in front of
// the console only while it is the active window. Everything below exists to
// hold that invariant against every path Windows and Qt have for moving it.
//
// Why native code, when ProjectionWindow.qml used to do this with
// Qt::WindowStaysOnBottomHint plus Window.FullScreen:
//   - Window.FullScreen on Windows re-stacks the HWND to HWND_TOP as part of
//     entering the state, so the "behind" window started life in front.
//   - Windows has no persistent "stay below" state. The bottom hint is a
//     one-shot HWND_BOTTOM, and with Qt forcing it on every z-order change a
//     click could ACTIVATE the projection while leaving it buried, which
//     parks keyboard focus (and so the Escape exit) on a window nobody can
//     see.
//   - "Directly under the console" and "forward on click, back on Escape"
//     are not expressible as Qt window flags at all.
//
// So the window stays an ordinary non-topmost Qt window, and this filter
// watches its HWND:
//   WM_WINDOWPOSCHANGING  while behind, every z-order move (show, raise,
//                         activation, Qt's own setGeometry) is redirected to
//                         "immediately after the console HWND".
//   WM_MOUSEACTIVATE      a click while behind brings it forward and lets it
//                         activate, so keyboard focus lands on the visible
//                         window and Escape works.
//   WM_ACTIVATE           losing activation sends it back; gaining it any
//                         other way (taskbar button, Alt-Tab, a touch tap)
//                         brings it forward.
// A click on the forward output sends it back (outputClicked, from QML). The
// click that brought it forward is skipped.
// Show-without-activating is requested through Qt's own
// "_q_showWithoutActivating" window property, so going live never takes
// keyboard focus away from the console.
//
// No-op everywhere but Windows. Inert until ProjectionWindow.qml switches it
// on, and switching it off hands z-order back to the window's Qt flags, so
// the multi-display always-on-top path is untouched.

#include <QAbstractNativeEventFilter>
#include <QObject>
#include <QPointer>
#include <QWindow>

namespace crater {

class ProjectionLayering final : public QObject, public QAbstractNativeEventFilter
{
    Q_OBJECT

public:
    explicit ProjectionLayering(QObject* parent = nullptr);

    // Which two windows to keep in order. Called from ProjectionWindow.qml;
    // safe to call again if either changes, and with nulls.
    Q_INVOKABLE void attach(QWindow* projection, QWindow* console);

    // On while the projection shares the console's display and the operator
    // picked "behind the console". Off restores plain Qt behaviour.
    Q_INVOKABLE void setBehindConsole(bool on);

    // Put the projection back under the console and re-activate the console.
    // The Escape shortcut on the projection calls this in behind mode. No-op
    // when behind mode is off.
    Q_INVOKABLE void sendBehind();

    // A completed left click (or tap) on the projection. Sends a forward
    // output back behind, except for the click that brought it forward.
    // Wired from a MouseArea in ProjectionWindow.qml rather than read off
    // WM_LBUTTONUP so it works the same for mouse, touch and pen input.
    Q_INVOKABLE void outputClicked();

    bool nativeEventFilter(const QByteArray& eventType, void* message,
                           qintptr* result) override;

private:
    void applyShowWithoutActivating();
    void scheduleRestack();
    void restack();

    QPointer<QWindow> m_projection;
    QPointer<QWindow> m_console;
    bool m_on = false;
    // True only while the projection is the active window and in front.
    bool m_forward = false;
    // The click that brought the output forward also delivers a button
    // release. That release must not count as the "send it back" click.
    bool m_skipNextRelease = false;
    bool m_restackQueued = false;
};

}  // namespace crater
