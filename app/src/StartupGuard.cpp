// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2024-2026 Eyetu Kingsley. Part of Crater, see LICENSE and NOTICE.

#include "StartupGuard.h"

#include "LogReportService.h"

#include <QByteArray>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QSettings>
#include <QtGlobal>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <system_error>
#include <vector>

#ifdef Q_OS_WIN
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  ifndef NOMINMAX
#    define NOMINMAX
#  endif
#  include <windows.h>
#  include <dbghelp.h>
#  include <psapi.h>
#endif

namespace fs = std::filesystem;
namespace gfx = crater::graphics;

namespace crater::startup {

namespace {

// Where the trace lives: per-user and always writable, unlike the install
// folder. Kept out of AppData\Roaming on purpose: it is about this machine.
fs::path g_dir;
fs::path g_trace;          // this launch
fs::path g_prevTrace;      // the launch before
fs::path g_unsent;         // a failure report the endpoint has not accepted yet
fs::path g_levelFile;      // the graphics level that works on this PC
fs::path g_backendFile;    // "opengl" after a GPU driver crash (GraphicsLadder.h)

std::string g_prev;        // the previous launch's trace, read at begin()
bool g_prevFailed = false;
int  g_level = 0;
gfx::Backend g_backend = gfx::Backend::Default;
bool g_byHand = false;          // backend picked through the environment
bool g_switchedNow = false;     // this launch moved to OpenGL
std::string g_driverCrash;      // the crash that moved this PC to OpenGL
bool g_ready = false;
bool g_windowStage = false;   // past "qml loading": the window is coming up
// Graphics restarts already made in this chain, handed to the restarted
// process through the environment. The ladder normally comes from the trace
// file, but if that folder can't be written every launch would look like the
// first and a crash would restart at level 0 forever. This can't be lost.
int  g_retry = 0;
constexpr const char* kRetryEnv = "CRATER_STARTUP_RETRY";
// Set beside the backend variables Crater sets itself. A process Crater
// starts (a graphics restart, a profile switch, the installer's relaunch)
// inherits them, and without this would read them as chosen by hand: a
// restart from OpenGL would then stay on OpenGL instead of stepping down.
constexpr const char* kSetByCraterEnv = "CRATER_GRAPHICS_ENV";
constexpr const char* kBackendEnvs[] = { "QSG_RHI_BACKEND", "QT_QUICK_BACKEND",
                                         "QSG_RHI_PREFER_SOFTWARE_RENDERER" };

// A report kept from earlier launches is cut to this before sending, so a
// PC failing offline for weeks doesn't build an upload the endpoint refuses.
constexpr qsizetype kUnsentCapBytes = 768 * 1024;
// crater.log is append-only across sessions; its tail is the relevant part.
constexpr qint64 kLogTailBytes = 512 * 1024;

fs::path baseDir()
{
#ifdef Q_OS_WIN
    if (const wchar_t* local = _wgetenv(L"LOCALAPPDATA"); local && *local)
        return fs::path(local) / L"Voyager Labs" / L"Crater";
    if (const wchar_t* tmp = _wgetenv(L"TEMP"); tmp && *tmp)
        return fs::path(tmp) / L"Crater";
    return fs::path(L"Crater");
#else
    const char* tmp = std::getenv("TMPDIR");
    return fs::path((tmp && *tmp) ? tmp : "/tmp") / "crater";
#endif
}

std::string readFile(const fs::path& p)
{
    std::ifstream in(p, std::ios::binary);
    if (!in) return {};
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

// The last line of a trace, without its time stamp.
std::string lastStage(const std::string& text)
{
    const size_t end = text.find_last_not_of("\r\n");
    if (end == std::string::npos) return {};
    size_t start = text.rfind('\n', end);
    start = (start == std::string::npos) ? 0 : start + 1;
    std::string line = text.substr(start, end - start + 1);
    const size_t cut = line.find("] ");
    if (cut != std::string::npos) line = line.substr(cut + 2);
    return line;
}

// The first line of a trace that starts with `stage`, without its time
// stamp. Empty when there is none.
std::string findStage(const std::string& text, const char* stage)
{
    const size_t at = text.find(std::string("] ") + stage);
    if (at == std::string::npos) return {};
    const size_t from = at + 2;
    const size_t end = text.find_first_of("\r\n", from);
    return text.substr(from, end == std::string::npos ? std::string::npos : end - from);
}

// Appends one time-stamped line. Opens and closes the file every time, so
// the line is on disk even if the process dies on the next instruction.
void append(const std::string& line)
{
    if (g_trace.empty()) return;
#ifdef Q_OS_WIN
    FILE* f = _wfopen(g_trace.c_str(), L"ab");
#else
    FILE* f = std::fopen(g_trace.c_str(), "ab");
#endif
    if (!f) return;
    char stamp[32] = {};
    const std::time_t now = std::time(nullptr);
    std::tm tm {};
#ifdef Q_OS_WIN
    localtime_s(&tm, &now);
#else
    localtime_r(&now, &tm);
#endif
    std::strftime(stamp, sizeof stamp, "%Y-%m-%d %H:%M:%S", &tm);
    std::fprintf(f, "[%s] %s\n", stamp, line.c_str());
    std::fflush(f);
    std::fclose(f);
}

#ifdef Q_OS_WIN
// The crash handler's append. A crash can leave the heap or the C runtime's
// locks in any state, so this allocates nothing and goes straight to Win32:
// stack buffers, a path fixed at begin(), CreateFileW and WriteFile.
void appendFromCrash(const char* line)
{
    if (g_trace.empty()) return;
    const HANDLE f = CreateFileW(g_trace.c_str(), FILE_APPEND_DATA,
                                 FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS,
                                 FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) return;
    SYSTEMTIME t;
    GetLocalTime(&t);
    char buf[1024];
    int n = std::snprintf(buf, sizeof buf, "[%04u-%02u-%02u %02u:%02u:%02u] %s\n", t.wYear,
                          t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond, line);
    if (n < 0) n = 0;
    if (n >= static_cast<int>(sizeof buf)) n = static_cast<int>(sizeof buf) - 1;
    DWORD written = 0;
    WriteFile(f, buf, static_cast<DWORD>(n), &written, nullptr);
    CloseHandle(f);
}

// Minidumps: a crash during a service leaves no trace a user can describe,
// so the stacks of every thread go to <trace folder>\crashes. dbghelp is
// loaded at begin(), not in the crash handler, where loading a DLL can
// deadlock.
using MiniDumpWriteDumpFn = BOOL(WINAPI*)(HANDLE, DWORD, HANDLE, MINIDUMP_TYPE,
                                          PMINIDUMP_EXCEPTION_INFORMATION,
                                          PMINIDUMP_USER_STREAM_INFORMATION,
                                          PMINIDUMP_CALLBACK_INFORMATION);
MiniDumpWriteDumpFn g_writeDump = nullptr;
fs::path g_dumpDir;
// Dumps kept, newest first. Each is a few hundred KB.
constexpr int kDumpsKept = 5;

void writeMinidump(EXCEPTION_POINTERS* info)
{
    if (!g_writeDump || g_dumpDir.empty()) return;
    CreateDirectoryW(g_dumpDir.c_str(), nullptr);   // made at begin(); this is a fallback
    SYSTEMTIME t;
    GetLocalTime(&t);
    // The process id keeps two crashes in one second (a graphics restart
    // that crashes again) from overwriting each other. The names still
    // sort by time.
    char name[64];
    std::snprintf(name, sizeof name, "crash-%04u%02u%02u-%02u%02u%02u-%lu.dmp", t.wYear,
                  t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond,
                  static_cast<unsigned long>(GetCurrentProcessId()));
    wchar_t path[MAX_PATH * 2];
    std::swprintf(path, MAX_PATH * 2, L"%ls\\%hs", g_dumpDir.c_str(), name);
    const HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                                    FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
    MINIDUMP_EXCEPTION_INFORMATION mei {};
    mei.ThreadId = GetCurrentThreadId();
    mei.ExceptionPointers = info;
    mei.ClientPointers = FALSE;
    const auto type = static_cast<MINIDUMP_TYPE>(MiniDumpWithThreadInfo
                                                 | MiniDumpWithUnloadedModules);
    const BOOL ok = g_writeDump(GetCurrentProcess(), GetCurrentProcessId(), file, type,
                                info ? &mei : nullptr, nullptr, nullptr);
    CloseHandle(file);
    if (ok) {
        char line[96];
        std::snprintf(line, sizeof line, "minidump: %s", name);
        appendFromCrash(line);
    } else {
        DeleteFileW(path);
    }
}

// Keeps the newest kDumpsKept - 1 dumps, so the next crash makes kDumpsKept.
void pruneMinidumps()
{
    std::error_code ec;
    std::vector<fs::path> dumps;
    for (const auto& e : fs::directory_iterator(g_dumpDir, ec))
        if (e.path().extension() == L".dmp") dumps.push_back(e.path());
    // The names sort by time.
    std::sort(dumps.begin(), dumps.end());
    for (size_t i = 0; i + (kDumpsKept - 1) < dumps.size(); ++i) fs::remove(dumps[i], ec);
}

// Names the module an address falls in and the offset into it, into `out`.
// A bare address means nothing once ASLR has moved the DLLs. VirtualQuery
// and the mapped file's name come from the kernel, so unlike
// GetModuleFileName this takes no loader lock another thread may hold.
void describeAddress(const void* address, char* out, size_t size)
{
    std::snprintf(out, size, "unknown module");
    MEMORY_BASIC_INFORMATION mbi {};
    if (!address || !VirtualQuery(address, &mbi, sizeof mbi) || mbi.Type != MEM_IMAGE
        || !mbi.AllocationBase)
        return;
    wchar_t path[MAX_PATH] = {};
    if (!GetMappedFileNameW(GetCurrentProcess(), mbi.AllocationBase, path, MAX_PATH)) return;
    const wchar_t* slash = std::wcsrchr(path, L'\\');
    char name[MAX_PATH] = {};
    WideCharToMultiByte(CP_UTF8, 0, slash ? slash + 1 : path, -1, name, sizeof name, nullptr,
                        nullptr);
    std::snprintf(out, size, "%s+0x%llx", name,
                  static_cast<unsigned long long>(static_cast<const char*>(address)
                                                  - static_cast<const char*>(mbi.AllocationBase)));
}

// Records an unhandled crash, then lets Windows carry on as it would have.
//
// The line names the module and offset ("igd10iumd64.dll+0x228d55"), which
// is what the next launch reads to tell a GPU driver crash from any other
// (GraphicsLadder.h), and a minidump goes beside the trace.
//
// A crash while the window is coming up is how a graphics driver Qt can't
// use usually shows itself (an access violation inside the driver, not
// Qt's sceneGraphError), so it also starts Crater again: the new process
// reads this trace and drops a rung down the graphics ladder. Nothing to
// click, and bounded by the ladder: no restart from the last rung.
LONG WINAPI crashFilter(EXCEPTION_POINTERS* info)
{
    const auto* rec = info ? info->ExceptionRecord : nullptr;
    char where[MAX_PATH + 32];
    describeAddress(rec ? rec->ExceptionAddress : nullptr, where, sizeof where);
    // An access violation also says what it touched: "read 0x0" is a null
    // pointer.
    char touched[48] = "";
    if (rec && rec->ExceptionCode == EXCEPTION_ACCESS_VIOLATION && rec->NumberParameters >= 2) {
        const ULONG_PTR op = rec->ExceptionInformation[0];
        std::snprintf(touched, sizeof touched, ", %s 0x%llx",
                      op == 0 ? "read" : op == 1 ? "write" : "execute",
                      static_cast<unsigned long long>(rec->ExceptionInformation[1]));
    }
    char line[MAX_PATH + 128];
    std::snprintf(line, sizeof line, "crash: exception 0x%08lx in %s%s",
                  rec ? static_cast<unsigned long>(rec->ExceptionCode) : 0ul, where, touched);
    appendFromCrash(line);
    writeMinidump(info);

    if (g_windowStage && !g_ready && g_level < gfx::kMaxLevel && g_retry < gfx::kMaxLevel) {
        appendFromCrash("exit: restarting with simpler graphics");
        char next[8];
        std::snprintf(next, sizeof next, "%d", g_retry + 1);
        SetEnvironmentVariableA(kRetryEnv, next);
        wchar_t exe[MAX_PATH] = {};
        // CreateProcessW may write to the command line, so pass a copy.
        static wchar_t cmd[8192];
        wcsncpy_s(cmd, GetCommandLineW(), _TRUNCATE);
        if (GetModuleFileNameW(nullptr, exe, MAX_PATH)) {
            STARTUPINFOW si {};
            si.cb = sizeof si;
            PROCESS_INFORMATION pi {};
            if (CreateProcessW(exe, cmd, nullptr, nullptr, FALSE, 0,
                               nullptr, nullptr, &si, &pi)) {
                CloseHandle(pi.hThread);
                CloseHandle(pi.hProcess);
            }
        }
    }
    return EXCEPTION_CONTINUE_SEARCH;
}
#endif

}  // namespace

QString stateDirectory()
{
#ifdef Q_OS_WIN
    return QString::fromStdWString(baseDir().wstring());
#else
    return QFile::decodeName(baseDir().string().c_str());
#endif
}

void begin(int argc)
{
    g_dir = baseDir();
    std::error_code ec;
    fs::create_directories(g_dir, ec);
    g_trace       = g_dir / "crater-startup.log";
    g_prevTrace   = g_dir / "crater-startup.prev.log";
    g_unsent      = g_dir / "crater-startup.unsent.log";
    g_levelFile   = g_dir / "graphics-fallback";
    g_backendFile = g_dir / "graphics-backend";

    if (fs::exists(g_trace, ec)) {
        fs::remove(g_prevTrace, ec);
        fs::rename(g_trace, g_prevTrace, ec);
    }
    g_prev = readFile(g_prevTrace);

    // A restart after a graphics failure is at least one rung down per
    // restart, whatever the trace says. Cleared so nothing this process
    // starts later (a profile switch) inherits it.
    g_retry = qEnvironmentVariableIntValue(kRetryEnv);
    qunsetenv(kRetryEnv);

    // An operator or developer who picked a backend by hand keeps it. What
    // Crater set for the process that started this one is cleared instead,
    // so this launch decides afresh.
    const bool setByCrater = qEnvironmentVariableIsSet(kSetByCraterEnv);
    g_byHand = gfx::chosenByHand(qEnvironmentVariableIsSet("QSG_RHI_BACKEND"),
                                 qEnvironmentVariableIsSet("QT_QUICK_BACKEND"), setByCrater);
    if (setByCrater) {
        for (const char* name : kBackendEnvs) qunsetenv(name);
        qunsetenv(kSetByCraterEnv);
    }

#ifdef Q_OS_WIN
    constexpr bool hasWarp = true;
#else
    constexpr bool hasWarp = false;
#endif
    const std::string storedBackend = readFile(g_backendFile);
    const gfx::Decision d = gfx::decide(g_prev, gfx::parseLevel(readFile(g_levelFile)),
                                        gfx::parseBackend(storedBackend), g_retry, hasWarp);
    g_prevFailed = d.previousFailed;
    g_level      = d.level;
    g_backend    = d.backend;
    if (d.writeLevel) std::ofstream(g_levelFile, std::ios::trunc) << g_level << "\n";
    if (d.switchedToOpenGl) {
        std::ofstream(g_backendFile, std::ios::binary | std::ios::trunc)
            << gfx::backendFileText(gfx::Backend::OpenGl, d.driverCrash);
        g_driverCrash = d.driverCrash;
    } else {
        g_driverCrash = gfx::parseBackendReason(storedBackend);
    }
    // Stored either way, like the level, but only announced when it is
    // what this launch actually uses.
    g_switchedNow = d.switchedToOpenGl && !g_byHand;

    const auto env = gfx::environmentFor(g_level, g_backend, g_byHand);
    for (const auto& [name, value] : env) qputenv(name, value);
    if (!env.empty()) qputenv(kSetByCraterEnv, "1");
    // Puts the graphics adapter and backend Qt picked into crater.log, which
    // is the first thing to know about a PC whose window won't come up.
    if (!qEnvironmentVariableIsSet("QSG_INFO")) qputenv("QSG_INFO", "1");

    append("main entered (argc=" + std::to_string(argc) + ")");
    append(gfx::traceLine(g_level, g_backend, g_byHand));
    if (d.switchedToOpenGl)
        append("graphics backend switched to OpenGL after a driver crash in " + d.driverCrash);
    // Quoted without its time stamp, so a stage it names (a fatal error,
    // say) can't be read back next time as one this launch hit.
    if (g_prevFailed) append("previous launch stopped after -> " + lastStage(g_prev));

#ifdef Q_OS_WIN
    g_dumpDir = g_dir / "crashes";
    fs::create_directories(g_dumpDir, ec);
    pruneMinidumps();
    // From System32 only, never a dbghelp.dll beside the exe or in the
    // working folder.
    if (const HMODULE dbghelp = LoadLibraryExW(L"dbghelp.dll", nullptr,
                                               LOAD_LIBRARY_SEARCH_SYSTEM32))
        g_writeDump = reinterpret_cast<MiniDumpWriteDumpFn>(
            GetProcAddress(dbghelp, "MiniDumpWriteDump"));
    SetUnhandledExceptionFilter(crashFilter);
#endif
}

void logPreviousCrash()
{
    // A crash before the first frame is reported by reportPreviousFailure.
    // One after it, mid-service, only ever reached the startup trace, which
    // the next two launches rotate away. crater.log is the file people send
    // in, so the crash goes there too.
    if (!g_prevFailed) {
        if (const std::string crash = findStage(g_prev, "crash:"); !crash.empty())
            qWarning().noquote() << "Previous session" << QString::fromStdString(crash);
        if (const std::string dump = findStage(g_prev, "minidump: "); !dump.empty()) {
            const QString name = QString::fromStdString(dump.substr(std::strlen("minidump: ")));
            qWarning().noquote() << "Previous session minidump:"
                                 << QDir::toNativeSeparators(
                                        QDir(stateDirectory()).filePath(QStringLiteral("crashes/") + name));
        }
    }
    if (g_switchedNow)
        qWarning().noquote()
            << QStringLiteral("Graphics: switched to OpenGL because the previous session crashed "
                              "in the graphics driver (%1). Settings > Diagnostics switches back.")
                   .arg(QString::fromStdString(g_driverCrash));
}

void mark(const char* stage)
{
    if (stage && std::strcmp(stage, "qml loading") == 0) g_windowStage = true;
    append(stage);
}

void markExit(const char* reason)
{
    append(std::string("exit: ") + reason);
}

void markFatal(const char* message)
{
    append(std::string("fatal: ") + (message ? message : ""));
}

void markReady()
{
    if (g_ready) return;
    g_ready = true;
    append("ready");
}

int graphicsLevel()
{
    return g_level;
}

graphics::Mode graphicsMode()
{
    return gfx::modeFor(g_level, g_backend);
}

bool graphicsChosenByHand()
{
    return g_byHand;
}

bool switchedToOpenGl()
{
    return g_switchedNow;
}

QString openGlReason()
{
    return QString::fromStdString(g_driverCrash);
}

void resetGraphics()
{
    std::error_code ec;
    fs::remove(g_levelFile, ec);
    fs::remove(g_backendFile, ec);
    append("graphics reset to the default from Settings");
    qInfo().noquote() << "Graphics: reset to the default from Settings. It applies the next time"
                      << "Crater opens.";
}

bool mayRestartForGraphics()
{
    return g_level < gfx::kMaxLevel && g_retry < gfx::kMaxLevel;
}

void prepareGraphicsRestart()
{
    qputenv(kRetryEnv, QByteArray::number(g_retry + 1));
}

void reportPreviousFailure(const QString& logPath)
{
    // Settings > Diagnostics can turn reporting off. Read straight from
    // QSettings: SettingsService doesn't exist yet. Same key it writes.
    const bool allowed = QSettings(QStringLiteral("Voyager Labs"), QStringLiteral("Crater"))
                             .value(QStringLiteral("Settings/reportStartupFailures"), true)
                             .toBool();
    std::error_code ec;
    if (!allowed) {
        if (g_prevFailed) append("previous failure not reported (turned off in Settings)");
        fs::remove(g_unsent, ec);
        return;
    }

    const QByteArray unsent = QByteArray::fromStdString(readFile(g_unsent));
    if (!g_prevFailed && unsent.isEmpty()) return;

    // A report an earlier launch could not get accepted goes first.
    QByteArray data = unsent.left(kUnsentCapBytes);
    if (g_prevFailed) {
        if (!data.isEmpty()) data += "\n\n";
        data += "Automatic report: a Crater launch on this PC stopped before the console appeared.\n";
        data += "Graphics level now: " + QByteArray::number(g_level) + "\n\n";
        data += "=== crater-startup.prev.log ===\n";
        data += QByteArray::fromStdString(g_prev) + "\n";
        QFile log(logPath);
        if (log.open(QIODevice::ReadOnly)) {
            const qint64 size = log.size();
            if (size > kLogTailBytes) {
                log.seek(size - kLogTailBytes);
                log.readLine();   // start on a whole line
            }
            data += "=== crater.log (tail) ===\n";
            data += log.readAll();
        }
    }

    // On disk until the endpoint accepts it, so it survives this launch
    // dying too, or the PC being offline, and the next launch sends it.
    {
        std::ofstream out(g_unsent, std::ios::binary | std::ios::trunc);
        out.write(data.constData(), data.size());
    }

    const QString note = QStringLiteral("automatic startup failure report; last stage: %1")
                             .arg(QString::fromStdString(lastStage(g_prev)));
    // In the background: the endpoint can take several seconds to answer,
    // and a PC that just failed to start shouldn't wait on it.
    LogReportService::sendInBackground(data, note, [](bool ok) {
        append(ok ? "reported previous failure" : "could not report previous failure");
        std::error_code ec;
        if (ok) fs::remove(g_unsent, ec);
    });
}

}  // namespace crater::startup
