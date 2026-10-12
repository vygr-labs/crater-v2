#pragma once

#include <QString>

// Startup guard: makes a launch that dies before the console appears leave a
// trail, report itself, and recover where it can.
//
// Until this existed, a failed launch was silent. The only early trace went
// to crater-bootstrap.log in the working directory, which for an installed
// copy is Program Files, so a normal user could not even write it. Crater
// just never appeared, with nothing in Task Manager and nothing on disk.
//
// Each launch writes crater-startup.log, one line per stage, in a per-user
// folder that is always writable (%LOCALAPPDATA%\Voyager Labs\Crater on
// Windows). The previous launch's copy is kept beside it. A launch that never
// reached its first painted frame, and did not exit on purpose, failed. The
// next launch then:
//
//   * uploads that trace and the tail of crater.log (reportPreviousFailure),
//     so a failure on someone else's PC reaches us without them doing
//     anything. A healthy PC never sends anything, and Settings >
//     Diagnostics turns it off (ARCHITECTURE.md §11).
//   * moves down the graphics ladder when the failure happened while the
//     window was coming up with a fatal error or crash recorded: first the
//     Direct3D software rasterizer (WARP), then Qt Quick's software
//     renderer. A GPU or driver Qt can't start on is the commonest way a
//     Qt Quick app dies before showing anything. The level that worked is
//     kept, so the PC doesn't fail once on every launch.
//
// The pre-Qt functions use only the C runtime, so they work before
// QApplication exists and from the fatal-message and crash handlers.
namespace crater::startup {

// Call first thing in main(). Rotates the previous trace, starts this one,
// picks the graphics level (setting the matching environment variables) and,
// on Windows, installs a handler that records a crash in the trace.
void begin(int argc);

// Appends one stage line ("qml loading", "migrations done"...).
void mark(const char* stage);

// Records why the launch is about to end on purpose ("exit: ..."), so the
// next launch reports it but doesn't treat it as a graphics failure.
void markExit(const char* reason);

// Records a fatal Qt message. Called by the message handler before abort().
void markFatal(const char* message);

// The console painted its first frame: this launch worked.
void markReady();

// After QApplication and logging exist: if the previous launch failed, send
// its trace and the tail of `logPath` in the background. The report stays
// on disk until the endpoint accepts it, so a launch that dies before then,
// or a PC that is offline, sends it next time.
void reportPreviousFailure(const QString& logPath);

// The graphics level this launch uses: 0 hardware, 1 WARP, 2 software.
int graphicsLevel();

}  // namespace crater::startup
