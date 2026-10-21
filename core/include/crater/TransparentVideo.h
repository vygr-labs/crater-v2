#pragma once

#include <QString>

#include <atomic>

namespace crater::transparentvideo {

// Transparent WebM support.
//
// A WebM made for overlays (an animated logo, a lower third) keeps its
// transparency in a second VP8/VP9 stream stored beside each frame. Only
// libvpx's decoder reads that stream. The FFmpeg that Qt Multimedia ships
// uses FFmpeg's own VP8/VP9 decoders, which skip it, so the video plays with
// whatever colour the encoder left under the transparent parts, usually
// white or black.
//
// This decodes both streams with FFmpeg's built-in decoder and writes a copy
// with PNG video in Matroska, a format Qt plays with its alpha intact. Audio
// is carried across unchanged. The copy lives in the cache folder, keyed by
// the source's path, size and modified time, so the media library and the
// schedules that point at the WebM never change: the player opens the copy
// in its place.
//
// Copies are lossless, so they are big. Videos longer than about 30 s of
// 1080p are left alone, a conversion stops when the disk gets close to full,
// and the folder is trimmed to 2 GB, oldest-used first.
//
// It calls the same FFmpeg libraries Qt Multimedia already loads, found at
// run time (no import libraries, no second copy of FFmpeg). When they are
// missing, or a different major version from the headers in
// src/third_party/ffmpeg, everything here reports "no copy" and the WebM
// plays as before.

// Cheap first check, from the name and the leading bytes: is this a
// Matroska / WebM file at all? Anything else can't carry the side stream.
bool mayCarryAlpha(const QString& path);

// Where the copy for `path` lives, made or not. Changes whenever the file
// does, so it also works as a key for "this version of this file".
QString copyPath(const QString& path);

// The finished copy for `path`, or empty when there isn't one yet. Marks
// the copy as recently used.
QString cachedCopy(const QString& path);

enum class Result {
    Copy,        // `copy` is ready to play
    NoAlpha,     // nothing to do, play the original
    TooLarge,    // too long or too big to copy, play the original
    Failed,      // the conversion failed (logged), play the original
    Cancelled,   // `cancel` was set
};

struct Prepared {
    Result  result = Result::NoAlpha;
    QString copy;
};

// The copy for `path`, making it first when the file carries an alpha
// stream. Slow (it decodes and re-encodes every frame), so call it off the
// GUI thread. Setting `cancel` stops a running conversion within a frame.
Prepared prepare(const QString& path, const std::atomic_bool* cancel = nullptr);

}  // namespace crater::transparentvideo
