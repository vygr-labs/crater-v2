#pragma once

class QWindow;

// One Crater per user. A second launch brings the running console to the
// front and quits instead of opening a second console on the same profile,
// databases and projection screen.
//
// It also keeps the startup guard honest. Every launch rotates the startup
// trace (StartupGuard.h), so a second launch made while the first was still
// loading used to move the first one's trace aside and report it as a
// launch that never reached the console. claim() runs before
// startup::begin(), so a launch that hands over never touches the trace.
//
// The lock is a QLockFile beside the startup trace. The running console
// listens on a local socket named after that folder, which is how a later
// launch reaches it.
namespace crater::instance {

// Call first thing in main(), before startup::begin(). True when this launch
// is the only Crater and should carry on. False when another Crater is
// running: it has been asked to show its console, and main() should return.
//
// A relaunch Crater makes itself (a profile switch, a graphics restart)
// starts while the old process is still closing, so it waits for the lock
// instead of handing over.
bool claim(int argc, char* argv[]);

// After QApplication exists: answer later launches by bringing the console
// window to the front. A launch that arrives before the console exists is
// ignored; the console is about to appear anyway.
void listen();

// The window listen() brings forward. Set once the console is realized.
void setConsole(QWindow* window);

}  // namespace crater::instance
