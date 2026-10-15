#include "StartupGuard.h"

#include "LogReportService.h"

#include <QByteArray>
#include <QFile>
#include <QSettings>
#include <QtGlobal>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <system_error>

#ifdef Q_OS_WIN
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  ifndef NOMINMAX
#    define NOMINMAX
#  endif
#  include <windows.h>
#endif

namespace fs = std::filesystem;

namespace crater::startup {

namespace {

// Where the trace lives: per-user and always writable, unlike the install
// folder. Kept out of AppData\Roaming on purpose: it is about this machine.
fs::path g_dir;
fs::path g_trace;          // this launch
fs::path g_prevTrace;      // the launch before
fs::path g_unsent;         // a failure report the endpoint has not accepted yet
fs::path g_levelFile;      // the graphics level that works on this PC

std::string g_prev;        // the previous launch's trace, read at begin()
bool g_prevFailed = false;
int  g_level = 0;
bool g_ready = false;
bool g_windowStage = false;   // past "qml loading": the window is coming up
// Graphics restarts already made in this chain, handed to the restarted
// process through the environment. The ladder normally comes from the trace
// file, but if that folder can't be written every launch would look like the
// first and a crash would restart at level 0 forever. This can't be lost.
int  g_retry = 0;
constexpr const char* kRetryEnv = "CRATER_STARTUP_RETRY";

// Software rendering (level 2) is the floor; there is nothing below it.
constexpr int kMaxLevel = 2;
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

// Every trace line is "[time] stage", so a stage is found by its prefix
// right after the time stamp.
bool hasLine(const std::string& text, const char* stage)
{
    return text.find(std::string("] ") + stage) != std::string::npos;
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

int levelUsedBy(const std::string& text)
{
    const std::string key = "] graphics level ";
    const size_t at = text.find(key);
    if (at == std::string::npos) return 0;
    return std::atoi(text.c_str() + at + key.size());
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
// Records an unhandled crash, then lets Windows carry on as it would have.
//
// A crash while the window is coming up is how a graphics driver Qt can't
// use usually shows itself (an access violation inside the driver, not
// Qt's sceneGraphError), so it also starts Crater again: the new process
// reads this trace and drops a rung down the graphics ladder. Nothing to
// click, and bounded by the ladder: no restart from the last rung.
LONG WINAPI crashFilter(EXCEPTION_POINTERS* info)
{
    char buf[96];
    const auto* rec = info ? info->ExceptionRecord : nullptr;
    std::snprintf(buf, sizeof buf, "crash: exception 0x%08lx at %p",
                  rec ? static_cast<unsigned long>(rec->ExceptionCode) : 0ul,
                  rec ? rec->ExceptionAddress : nullptr);
    append(buf);

    if (g_windowStage && !g_ready && g_level < kMaxLevel && g_retry < kMaxLevel) {
        append("exit: restarting with simpler graphics");
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
    g_trace     = g_dir / "crater-startup.log";
    g_prevTrace = g_dir / "crater-startup.prev.log";
    g_unsent    = g_dir / "crater-startup.unsent.log";
    g_levelFile = g_dir / "graphics-fallback";

    if (fs::exists(g_trace, ec)) {
        fs::remove(g_prevTrace, ec);
        fs::rename(g_trace, g_prevTrace, ec);
    }
    g_prev = readFile(g_prevTrace);
    // Not reaching the first frame is a failure, whatever the reason. A
    // deliberate early exit ("exit: ...") is reported too; it just isn't
    // blamed on the graphics.
    g_prevFailed = !g_prev.empty() && !hasLine(g_prev, "ready");

    // Graphics level: the one that worked before, one step lower when the
    // last launch died bringing the window up. A user closing Crater while
    // it starts records no fatal error or crash, so it never counts.
    g_level = std::atoi(readFile(g_levelFile).c_str());
    const bool diedOnWindow = g_prevFailed && hasLine(g_prev, "qml loading")
                              && (hasLine(g_prev, "fatal:") || hasLine(g_prev, "crash:"));
    if (diedOnWindow) {
        int next = levelUsedBy(g_prev) + 1;
#ifndef Q_OS_WIN
        // WARP is Direct3D only; elsewhere go straight to software.
        if (next == 1) next = 2;
#endif
        if (next > g_level) g_level = next;
    }
    // A restart after a graphics failure is at least one rung down per
    // restart, whatever the trace says. Cleared so nothing this process
    // starts later (a profile switch) inherits it.
    g_retry = qEnvironmentVariableIntValue(kRetryEnv);
    qunsetenv(kRetryEnv);
    if (g_retry > g_level) g_level = g_retry;
    if (g_level < 0) g_level = 0;
    if (g_level > kMaxLevel) g_level = kMaxLevel;
    if (diedOnWindow) std::ofstream(g_levelFile, std::ios::trunc) << g_level << "\n";

    // An operator or developer who picked a backend by hand keeps it.
    const bool chosenByHand = qEnvironmentVariableIsSet("QSG_RHI_BACKEND")
                              || qEnvironmentVariableIsSet("QT_QUICK_BACKEND");
    if (!chosenByHand) {
        if (g_level == 1) qputenv("QSG_RHI_PREFER_SOFTWARE_RENDERER", "1");
        if (g_level == 2) qputenv("QT_QUICK_BACKEND", "software");
    }
    // Puts the graphics adapter and backend Qt picked into crater.log, which
    // is the first thing to know about a PC whose window won't come up.
    if (!qEnvironmentVariableIsSet("QSG_INFO")) qputenv("QSG_INFO", "1");

    append("main entered (argc=" + std::to_string(argc) + ")");
    append("graphics level " + std::to_string(g_level)
           + (chosenByHand ? " (backend set by environment)" : ""));
    // Quoted without its time stamp, so a stage it names (a fatal error,
    // say) can't be read back next time as one this launch hit.
    if (g_prevFailed) append("previous launch stopped after -> " + lastStage(g_prev));

#ifdef Q_OS_WIN
    SetUnhandledExceptionFilter(crashFilter);
#endif
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

bool mayRestartForGraphics()
{
    return g_level < kMaxLevel && g_retry < kMaxLevel;
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
