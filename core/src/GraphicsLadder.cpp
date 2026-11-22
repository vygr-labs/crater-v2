// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2024-2026 Eyetu Kingsley. Part of Crater, see LICENSE and NOTICE.

#include "crater/GraphicsLadder.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>

namespace crater::graphics {

namespace {

// Every trace line is "[time] stage", so a stage is found by its prefix
// right after the time stamp. A quoted stage ("previous launch stopped
// after -> crash: ...") doesn't follow "] " and so isn't matched.
bool hasLine(std::string_view text, std::string_view stage)
{
    std::string key = "] ";
    key += stage;
    return text.find(key) != std::string_view::npos;
}

// The rest of the first line that starts with `stage`, after the stage.
// npos-safe: empty when there is no such line.
std::string_view restOfLine(std::string_view text, std::string_view stage, bool* found = nullptr)
{
    std::string key = "] ";
    key += stage;
    const size_t at = text.find(key);
    if (found) *found = at != std::string_view::npos;
    if (at == std::string_view::npos) return {};
    const size_t from = at + key.size();
    const size_t end = text.find_first_of("\r\n", from);
    return text.substr(from, end == std::string_view::npos ? std::string_view::npos : end - from);
}

int clampLevel(int level)
{
    return std::clamp(level, kHardware, kMaxLevel);
}

std::string_view trimmed(std::string_view s)
{
    while (!s.empty() && std::isspace(static_cast<unsigned char>(s.front()))) s.remove_prefix(1);
    while (!s.empty() && std::isspace(static_cast<unsigned char>(s.back()))) s.remove_suffix(1);
    return s;
}

std::string_view firstLine(std::string_view text)
{
    const size_t end = text.find_first_of("\r\n");
    return end == std::string_view::npos ? text : text.substr(0, end);
}

std::string lower(std::string_view s)
{
    std::string out(s);
    for (char& c : out) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return out;
}

constexpr std::string_view kLevelStage = "graphics level ";
constexpr std::string_view kOpenGlTag  = " (OpenGL)";
constexpr std::string_view kByHandTag  = " (backend set by environment)";

}  // namespace

Mode modeFor(int level, Backend backend)
{
    switch (clampLevel(level)) {
    case kWarp:     return Mode::Warp;
    case kSoftware: return Mode::Software;
    default:        return backend == Backend::OpenGl ? Mode::OpenGl : Mode::Direct3D;
    }
}

int parseLevel(std::string_view text)
{
    const std::string s(trimmed(firstLine(text)));
    return clampLevel(std::atoi(s.c_str()));
}

Backend parseBackend(std::string_view text)
{
    return lower(trimmed(firstLine(text))) == "opengl" ? Backend::OpenGl : Backend::Default;
}

std::string parseBackendReason(std::string_view text)
{
    const size_t end = text.find('\n');
    if (end == std::string_view::npos) return {};
    return std::string(trimmed(firstLine(text.substr(end + 1))));
}

std::string backendFileText(Backend backend, std::string_view reason)
{
    if (backend != Backend::OpenGl) return {};
    std::string out = "opengl\n";
    if (!reason.empty()) {
        out += reason;
        out += '\n';
    }
    return out;
}

bool isGpuDriverModule(std::string_view module)
{
    static constexpr std::string_view kDrivers[] = {
        "igd10iumd64.dll",   // Intel
        "igd10iumd32.dll",
        "nvwgf2umx.dll",     // NVIDIA
        "atidxx64.dll",      // AMD
        "amdxx64.dll",
    };
    const std::string name = lower(trimmed(module));
    return std::find(std::begin(kDrivers), std::end(kDrivers), name) != std::end(kDrivers);
}

std::string crashLocation(std::string_view trace)
{
    // "crash: exception 0xc0000005 in igd10iumd64.dll+0x228d55, read 0x0".
    // Crater before the crash trail wrote "... at 0x00007ff..." instead,
    // which names no module.
    const std::string_view line = restOfLine(trace, "crash: ");
    const size_t in = line.find(" in ");
    if (in == std::string_view::npos) return {};
    std::string_view where = line.substr(in + 4);
    const size_t comma = where.find(',');
    if (comma != std::string_view::npos) where = where.substr(0, comma);
    where = trimmed(where);
    if (where.find("+0x") == std::string_view::npos) return {};   // "unknown module"
    return std::string(where);
}

std::string moduleOf(std::string_view location)
{
    const size_t plus = location.rfind("+0x");
    return std::string(plus == std::string_view::npos ? location : location.substr(0, plus));
}

std::string traceLine(int level, Backend backend, bool chosenByHand)
{
    std::string line(kLevelStage);
    line += std::to_string(level);
    if (chosenByHand) line += kByHandTag;
    else if (modeFor(level, backend) == Mode::OpenGl) line += kOpenGlTag;
    return line;
}

Decision decide(std::string_view previousTrace, int storedLevel, Backend storedBackend,
                int retry, bool hasWarp)
{
    Decision d;
    // Not reaching the first frame is a failure, whatever the reason. A
    // deliberate early exit ("exit: ...") counts too; it just isn't blamed
    // on the graphics.
    d.previousFailed = !previousTrace.empty() && !hasLine(previousTrace, "ready");

    bool hadLevelLine = false;
    const std::string_view levelLine = restOfLine(previousTrace, kLevelStage, &hadLevelLine);
    const int previousLevel = hadLevelLine ? std::atoi(std::string(levelLine).c_str()) : 0;

    // The level: the one that worked before, one step lower when the last
    // launch died bringing the window up. A user closing Crater while it
    // starts records no fatal error or crash, so it never counts.
    d.level = clampLevel(storedLevel);
    const bool diedOnWindow = d.previousFailed && hasLine(previousTrace, "qml loading")
                              && (hasLine(previousTrace, "fatal:") || hasLine(previousTrace, "crash:"));
    if (diedOnWindow) {
        int next = previousLevel + 1;
        // WARP is Direct3D only; elsewhere go straight to software.
        if (!hasWarp && next == kWarp) next = kSoftware;
        if (next > d.level) d.level = next;
    }
    // A restart after a graphics failure is at least one rung down per
    // restart, whatever the trace says.
    if (retry > d.level) d.level = retry;
    d.level = clampLevel(d.level);
    d.writeLevel = diedOnWindow;

    // OpenGL: the previous session came up on hardware Direct3D (its level
    // line has no tag: not OpenGL, not chosen by hand), worked, and then
    // crashed inside the GPU driver. One such crash is enough: every crash
    // in the report that led here was mid-service, and the switch is
    // undone from Settings > Diagnostics.
    d.backend = storedBackend;
    const bool previousOnDirect3D = hadLevelLine && trimmed(levelLine) == "0";
    if (hasWarp && !d.previousFailed && previousOnDirect3D && d.level == kHardware
        && d.backend == Backend::Default) {
        const std::string where = crashLocation(previousTrace);
        if (isGpuDriverModule(moduleOf(where))) {
            d.backend = Backend::OpenGl;
            d.switchedToOpenGl = true;
            d.driverCrash = where;
        }
    }
    return d;
}

bool chosenByHand(bool rhiBackendSet, bool quickBackendSet, bool setByCrater)
{
    return (rhiBackendSet || quickBackendSet) && !setByCrater;
}

std::vector<std::pair<const char*, const char*>> environmentFor(int level, Backend backend,
                                                                bool byHand)
{
    if (byHand) return {};
    switch (modeFor(level, backend)) {
    case Mode::Warp:     return { { "QSG_RHI_PREFER_SOFTWARE_RENDERER", "1" } };
    case Mode::Software: return { { "QT_QUICK_BACKEND", "software" } };
    case Mode::OpenGl:   return { { "QSG_RHI_BACKEND", "opengl" } };
    case Mode::Direct3D: break;
    }
    return {};
}

}  // namespace crater::graphics
