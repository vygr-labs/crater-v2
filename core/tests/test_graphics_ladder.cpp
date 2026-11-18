// Tests for crater::graphics — how the startup guard picks the graphics a
// launch uses from the previous launch's trace (issue #155).
//
// Run via CTest: `ctest --test-dir <build-dir> -R graphics_ladder --output-on-failure`
//
// The traces below are written the way StartupGuard writes them: one
// "[time] stage" line per stage, the crash line from its crash filter. The
// decision can't be watched on a real PC without a driver crash, so this is
// where it is pinned.

#include <QObject>
#include <QTest>

#include "crater/GraphicsLadder.h"

#include <string>

using namespace crater::graphics;

namespace {

// A session that came up on hardware Direct3D, ran for a while and then
// crashed inside Intel's Direct3D driver, like the reports in #155.
const std::string kDriverCrashAfterReady =
    "[2026-11-16 10:00:00] main entered (argc=1)\n"
    "[2026-11-16 10:00:00] graphics level 0\n"
    "[2026-11-16 10:00:01] QApplication constructed\n"
    "[2026-11-16 10:00:01] migrations done\n"
    "[2026-11-16 10:00:02] data import checked\n"
    "[2026-11-16 10:00:02] qml loading\n"
    "[2026-11-16 10:00:03] qml loaded\n"
    "[2026-11-16 10:00:03] event loop\n"
    "[2026-11-16 10:00:03] ready\n"
    "[2026-11-16 10:41:12] crash: exception 0xc0000005 in igd10iumd64.dll+0x228d55, read 0x18\n"
    "[2026-11-16 10:41:12] minidump: crash-20261116-104112-4242.dmp\n";

std::string withLevelLine(std::string trace, const std::string& levelLine)
{
    const std::string from = "] graphics level 0\n";
    trace.replace(trace.find(from), from.size(), "] " + levelLine + "\n");
    return trace;
}

std::string withCrashIn(std::string trace, const std::string& where)
{
    const std::string from = "igd10iumd64.dll+0x228d55";
    trace.replace(trace.find(from), from.size(), where);
    return trace;
}

// A launch that died bringing its window up, on the given level line.
std::string diedOnWindow(const std::string& levelLine)
{
    return "[2026-11-16 09:00:00] main entered (argc=1)\n"
           "[2026-11-16 09:00:00] " + levelLine + "\n"
           "[2026-11-16 09:00:01] QApplication constructed\n"
           "[2026-11-16 09:00:01] migrations done\n"
           "[2026-11-16 09:00:02] qml loading\n"
           "[2026-11-16 09:00:02] crash: exception 0xc0000005 in nvwgf2umx.dll+0x1234, read 0x0\n";
}

// A session on `levelLine` that worked and closed normally.
std::string cleanSession(const std::string& levelLine)
{
    return "[2026-11-17 09:00:00] main entered (argc=1)\n"
           "[2026-11-17 09:00:00] " + levelLine + "\n"
           "[2026-11-17 09:00:02] qml loading\n"
           "[2026-11-17 09:00:03] qml loaded\n"
           "[2026-11-17 09:00:03] event loop\n"
           "[2026-11-17 09:00:03] ready\n";
}

}  // namespace

class TestGraphicsLadder : public QObject
{
    Q_OBJECT

private slots:
    // ── Reading the crash line ──────────────────────────────────────────
    void crashLocation_namesModuleAndOffset()
    {
        QCOMPARE(crashLocation(kDriverCrashAfterReady), std::string("igd10iumd64.dll+0x228d55"));
        QCOMPARE(moduleOf("igd10iumd64.dll+0x228d55"), std::string("igd10iumd64.dll"));
    }

    void crashLocation_withoutAnAccessViolationDetail()
    {
        const std::string t = "[2026-11-16 10:41:12] crash: exception 0xc0000409 in ucrtbase.dll+0x7e5ee\n";
        QCOMPARE(crashLocation(t), std::string("ucrtbase.dll+0x7e5ee"));
    }

    void crashLocation_emptyWhenNothingToName()
    {
        QCOMPARE(crashLocation(cleanSession("graphics level 0")), std::string());
        // Outside any module (a jump through a bad pointer).
        QCOMPARE(crashLocation("[t] crash: exception 0xc0000005 in unknown module, execute 0x0\n"),
                 std::string());
        // The line Crater wrote before the crash trail: an address only.
        QCOMPARE(crashLocation("[t] crash: exception 0xc0000005 at 00007FFB12345678\n"),
                 std::string());
        // Quoted by a later launch, not a crash of the launch that wrote it.
        QCOMPARE(crashLocation("[t] previous launch stopped after -> crash: exception "
                               "0xc0000005 in igd10iumd64.dll+0x1, read 0x0\n"),
                 std::string());
    }

    void gpuDriverModules_anyCase()
    {
        for (const char* m : { "igd10iumd64.dll", "igd10iumd32.dll", "nvwgf2umx.dll",
                               "atidxx64.dll", "amdxx64.dll", "IGD10IUMD64.DLL", "NvWgf2Umx.dll" })
            QVERIFY2(isGpuDriverModule(m), m);
        // Qt, the Direct3D runtime itself, the Intel OpenGL driver and a
        // partial name are not.
        for (const char* m : { "Qt6Quick.dll", "d3d11.dll", "ig9icd64.dll", "igd10iumd64", "", "crater.exe" })
            QVERIFY2(!isGpuDriverModule(m), m);
    }

    // ── The #155 decision ───────────────────────────────────────────────
    void driverCrashAfterReady_movesToOpenGl()
    {
        const Decision d = decide(kDriverCrashAfterReady, 0, Backend::Default, 0, true);
        QVERIFY(!d.previousFailed);
        QVERIFY(d.switchedToOpenGl);
        QCOMPARE(d.backend, Backend::OpenGl);
        QCOMPARE(d.level, kHardware);
        QVERIFY(!d.writeLevel);
        QCOMPARE(d.driverCrash, std::string("igd10iumd64.dll+0x228d55"));
        QCOMPARE(modeFor(d.level, d.backend), Mode::OpenGl);
    }

    void everyListedDriverCounts()
    {
        for (const char* where : { "igd10iumd32.dll+0x10", "nvwgf2umx.dll+0x20",
                                   "atidxx64.dll+0x30", "AMDXX64.DLL+0x40" }) {
            const Decision d = decide(withCrashIn(kDriverCrashAfterReady, where), 0,
                                      Backend::Default, 0, true);
            QVERIFY2(d.switchedToOpenGl, where);
        }
    }

    void crashElsewhere_staysOnDirect3D()
    {
        const Decision d = decide(withCrashIn(kDriverCrashAfterReady, "Qt6Quick.dll+0x5521"), 0,
                                  Backend::Default, 0, true);
        QVERIFY(!d.switchedToOpenGl);
        QCOMPARE(d.backend, Backend::Default);
        QCOMPARE(modeFor(d.level, d.backend), Mode::Direct3D);
    }

    void cleanSession_changesNothing()
    {
        const Decision d = decide(cleanSession("graphics level 0"), 0, Backend::Default, 0, true);
        QVERIFY(!d.switchedToOpenGl);
        QVERIFY(!d.writeLevel);
        QCOMPARE(modeFor(d.level, d.backend), Mode::Direct3D);
    }

    // The launch after the switch reads the OpenGL session's trace: it keeps
    // OpenGL from the stored file and doesn't announce it again.
    void launchAfterTheSwitch_keepsOpenGlQuietly()
    {
        const std::string prev = cleanSession(traceLine(0, Backend::OpenGl, false));
        const Decision d = decide(prev, 0, Backend::OpenGl, 0, true);
        QVERIFY(!d.switchedToOpenGl);
        QCOMPARE(modeFor(d.level, d.backend), Mode::OpenGl);
    }

    // Even another crash in the Direct3D driver (video decoding still uses
    // Direct3D on OpenGL) doesn't announce a switch that already happened.
    void driverCrashOnOpenGl_isNotASecondSwitch()
    {
        const std::string prev = withLevelLine(kDriverCrashAfterReady,
                                               traceLine(0, Backend::OpenGl, false));
        const Decision d = decide(prev, 0, Backend::OpenGl, 0, true);
        QVERIFY(!d.switchedToOpenGl);
        QCOMPARE(d.backend, Backend::OpenGl);
    }

    // A backend picked by hand is left alone, as is a session that ran
    // lower down the ladder or off Windows.
    void onlyHardwareDirect3DByCrater_switches()
    {
        QVERIFY(!decide(withLevelLine(kDriverCrashAfterReady, traceLine(0, Backend::Default, true)),
                        0, Backend::Default, 0, true).switchedToOpenGl);
        QVERIFY(!decide(withLevelLine(kDriverCrashAfterReady, "graphics level 1"),
                        1, Backend::Default, 0, true).switchedToOpenGl);
        QVERIFY(!decide(kDriverCrashAfterReady, 0, Backend::Default, 0, false).switchedToOpenGl);
        // A trace with no level line says nothing about the backend.
        std::string noLevel = kDriverCrashAfterReady;
        noLevel.erase(noLevel.find("[2026-11-16 10:00:00] graphics level 0\n"),
                      std::string("[2026-11-16 10:00:00] graphics level 0\n").size());
        QVERIFY(!decide(noLevel, 0, Backend::Default, 0, true).switchedToOpenGl);
    }

    // A driver crash before the first frame is the old ladder's case: one
    // rung down to WARP, as before #155, and no OpenGL.
    void driverCrashBeforeReady_isTheLadder()
    {
        const Decision d = decide(diedOnWindow("graphics level 0"), 0, Backend::Default, 0, true);
        QVERIFY(d.previousFailed);
        QVERIFY(!d.switchedToOpenGl);
        QVERIFY(d.writeLevel);
        QCOMPARE(modeFor(d.level, d.backend), Mode::Warp);
    }

    // ── The ladder below OpenGL ─────────────────────────────────────────
    // An OpenGL launch that dies bringing its window up goes to WARP, then
    // software, then stays: it never comes back to OpenGL.
    void openGlFailingAtStartup_stepsDownWithoutLooping()
    {
        Decision d = decide(diedOnWindow(traceLine(0, Backend::OpenGl, false)), 0,
                            Backend::OpenGl, 0, true);
        QCOMPARE(d.level, kWarp);
        QVERIFY(d.writeLevel);
        QCOMPARE(modeFor(d.level, d.backend), Mode::Warp);

        d = decide(diedOnWindow(traceLine(d.level, d.backend, false)), d.level, d.backend, 0, true);
        QCOMPARE(modeFor(d.level, d.backend), Mode::Software);

        d = decide(diedOnWindow(traceLine(d.level, d.backend, false)), d.level, d.backend, 0, true);
        QCOMPARE(modeFor(d.level, d.backend), Mode::Software);
    }

    // The crash filter's and sceneGraphError's restart count, used when the
    // trace folder can't be written, steps down from OpenGL the same way.
    void restartChainFromOpenGl_stepsDown()
    {
        QCOMPARE(modeFor(decide({}, 0, Backend::OpenGl, 1, true).level, Backend::OpenGl), Mode::Warp);
        QCOMPARE(modeFor(decide({}, 0, Backend::OpenGl, 2, true).level, Backend::OpenGl), Mode::Software);
        QCOMPARE(decide({}, 0, Backend::OpenGl, 9, true).level, kMaxLevel);
    }

    // ── Environment ─────────────────────────────────────────────────────
    void environment_perMode()
    {
        using Env = std::vector<std::pair<const char*, const char*>>;
        const auto same = [](const Env& a, const Env& b) {
            if (a.size() != b.size()) return false;
            for (size_t i = 0; i < a.size(); ++i)
                if (std::string(a[i].first) != b[i].first || std::string(a[i].second) != b[i].second)
                    return false;
            return true;
        };
        QVERIFY(environmentFor(0, Backend::Default, false).empty());
        QVERIFY(same(environmentFor(0, Backend::OpenGl, false), { { "QSG_RHI_BACKEND", "opengl" } }));
        // Below level 0 the stored OpenGL choice is not used.
        QVERIFY(same(environmentFor(1, Backend::OpenGl, false),
                     { { "QSG_RHI_PREFER_SOFTWARE_RENDERER", "1" } }));
        QVERIFY(same(environmentFor(2, Backend::OpenGl, false), { { "QT_QUICK_BACKEND", "software" } }));
        // Chosen by hand: Crater sets nothing.
        QVERIFY(environmentFor(0, Backend::OpenGl, true).empty());
        QVERIFY(environmentFor(2, Backend::Default, true).empty());
    }

    void chosenByHand_notWhenCraterPassedItOn()
    {
        QVERIFY(chosenByHand(true, false, false));
        QVERIFY(chosenByHand(false, true, false));
        QVERIFY(!chosenByHand(false, false, false));
        // A graphics restart or profile switch inherits what Crater set.
        QVERIFY(!chosenByHand(true, false, true));
        QVERIFY(!chosenByHand(false, true, true));
    }

    // ── Stored values ───────────────────────────────────────────────────
    // graphics-fallback files written before #155 keep their meaning.
    void storedLevel_meaningUnchanged()
    {
        QCOMPARE(parseLevel("0\n"), kHardware);
        QCOMPARE(parseLevel("1\n"), kWarp);
        QCOMPARE(parseLevel("2\n"), kSoftware);
        QCOMPARE(parseLevel(""), kHardware);
        QCOMPARE(parseLevel("junk"), kHardware);
        QCOMPARE(parseLevel("7"), kMaxLevel);
        QCOMPARE(modeFor(parseLevel("1\n"), Backend::Default), Mode::Warp);
        QCOMPARE(modeFor(parseLevel("2\n"), Backend::Default), Mode::Software);
    }

    void storedBackend_roundTrip()
    {
        const std::string text = backendFileText(Backend::OpenGl, "igd10iumd64.dll+0x228d55");
        QCOMPARE(parseBackend(text), Backend::OpenGl);
        QCOMPARE(parseBackendReason(text), std::string("igd10iumd64.dll+0x228d55"));
        QCOMPARE(parseBackend("OpenGL\r\n"), Backend::OpenGl);
        QCOMPARE(parseBackend(""), Backend::Default);
        QCOMPARE(parseBackend("vulkan\n"), Backend::Default);
        QVERIFY(backendFileText(Backend::Default, "x").empty());
    }

    void traceLine_shapes()
    {
        QCOMPARE(traceLine(0, Backend::Default, false), std::string("graphics level 0"));
        QCOMPARE(traceLine(0, Backend::OpenGl, false), std::string("graphics level 0 (OpenGL)"));
        QCOMPARE(traceLine(1, Backend::OpenGl, false), std::string("graphics level 1"));
        QCOMPARE(traceLine(0, Backend::OpenGl, true),
                 std::string("graphics level 0 (backend set by environment)"));
    }
};

QTEST_GUILESS_MAIN(TestGraphicsLadder)
#include "test_graphics_ladder.moc"
