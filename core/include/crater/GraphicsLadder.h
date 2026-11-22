// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2024-2026 Eyetu Kingsley. Part of Crater, see LICENSE and NOTICE.

#pragma once

#include <string>
#include <string_view>
#include <utility>
#include <vector>

// The graphics choice the startup guard (app/src/StartupGuard.h) makes
// before Qt starts. Pure text in, choice out, so it can be tested without a
// crash or a GPU. Standard library only: it runs before QApplication exists.
//
// Two stored values decide how Crater draws on a PC, each a small file in
// the startup trace folder:
//
//   graphics-fallback  the ladder level. 0 hardware Direct3D 11, 1 Direct3D's
//                      software rasterizer (WARP), 2 Qt Quick's software
//                      renderer. A launch that dies bringing its window up
//                      moves one level down. These numbers are on installed
//                      PCs already, so they never change meaning.
//   graphics-backend   "opengl" when a crash inside the GPU driver during a
//                      service moved this PC to OpenGL. Second line: where
//                      that crash was. Only level 0 uses it, so OpenGL is
//                      the step before WARP: an OpenGL launch that dies
//                      before its first frame still steps down to level 1.
//
// OpenGL is kept out of the level numbers on purpose. Making it a rung would
// renumber WARP and software under PCs that already stored 1 or 2, and the
// two move for different reasons: the ladder only ever goes down and only
// for a launch that never appeared, while OpenGL follows one driver crash in
// a session that worked, and Settings > Diagnostics can undo it.
namespace crater::graphics {

constexpr int kHardware = 0;
constexpr int kWarp     = 1;
constexpr int kSoftware = 2;
constexpr int kMaxLevel = kSoftware;

enum class Backend { Default, OpenGl };

// What a launch draws with, from its level and backend.
enum class Mode { Direct3D, OpenGl, Warp, Software };
Mode modeFor(int level, Backend backend);

// The stored files' contents. Anything unreadable is the default.
int parseLevel(std::string_view text);
Backend parseBackend(std::string_view text);
// The second line of graphics-backend: where the driver crash was.
std::string parseBackendReason(std::string_view text);
std::string backendFileText(Backend backend, std::string_view reason);

// True when `module` (a DLL file name, any case) is a GPU vendor's Direct3D
// user-mode driver: Intel igd10iumd64/32, NVIDIA nvwgf2umx, AMD atidxx64 and
// amdxx64.
bool isGpuDriverModule(std::string_view module);

// The place a trace's first crash line names, "igd10iumd64.dll+0x228d55"
// from "crash: exception 0xc0000005 in igd10iumd64.dll+0x228d55, read 0x0".
// Empty when there is no crash line or the address was in no module.
std::string crashLocation(std::string_view trace);
// Just the module part of a location: "igd10iumd64.dll".
std::string moduleOf(std::string_view location);

// The line a launch writes to its trace about its graphics, without the
// time stamp. Parsed back by decide(), so its shape is load-bearing:
// "graphics level N", then " (OpenGL)" or " (backend set by environment)".
std::string traceLine(int level, Backend backend, bool chosenByHand);

struct Decision {
    int level = kHardware;
    Backend backend = Backend::Default;
    // The previous launch never painted its first frame.
    bool previousFailed = false;
    // The level changed because the previous launch died bringing its
    // window up: write graphics-fallback.
    bool writeLevel = false;
    // The previous session crashed inside the GPU driver after it was up,
    // on hardware Direct3D: this launch moves to OpenGL. Write
    // graphics-backend and tell the operator.
    bool switchedToOpenGl = false;
    std::string driverCrash;   // where, when switchedToOpenGl
};

// Picks this launch's graphics from the previous launch's trace, what is
// stored, and how many graphics restarts this chain has made (`retry`).
// `hasWarp` is false off Windows, where the ladder skips level 1.
Decision decide(std::string_view previousTrace, int storedLevel, Backend storedBackend,
                int retry, bool hasWarp);

// Whether the person running Crater picked the backend through the
// environment. A variable Crater set itself and passed on to a process it
// started (a graphics restart, a profile switch) doesn't count, or a
// restart from OpenGL would keep OpenGL instead of stepping down.
bool chosenByHand(bool rhiBackendSet, bool quickBackendSet, bool setByCrater);

// The environment variables that put Qt on `level` and `backend`. None
// when the backend was chosen by hand.
std::vector<std::pair<const char*, const char*>> environmentFor(int level, Backend backend,
                                                                bool byHand);

}  // namespace crater::graphics
