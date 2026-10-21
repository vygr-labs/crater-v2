#pragma once

#include <QString>

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
// This decodes both streams with FFmpeg's built-in decoder and writes a
// PNG-in-MOV copy, a format Qt plays with its alpha intact. The copy lives
// in the cache folder, keyed by the source's path, size and modified time,
// so the media library and the schedules that point at the WebM never
// change. MediaPlaybackService plays the copy in its place.
//
// It calls the same FFmpeg libraries Qt Multimedia already loads, found at
// run time (no import libraries, no second copy of FFmpeg). When they are
// missing, or a different major version from the headers in
// src/third_party/ffmpeg, everything here reports "no copy" and the WebM
// plays as before.

// Cheap first check from the leading bytes: is this a Matroska / WebM file
// at all? Anything else can't carry the side stream.
bool mayCarryAlpha(const QString& path);

// The finished copy for `path`, or empty when there isn't one yet.
QString cachedCopy(const QString& path);

// The copy for `path`, making it first when the file carries an alpha
// stream. Empty when it doesn't, or when the conversion fails (logged).
// Slow (it decodes and re-encodes every frame), so call it off the GUI
// thread.
QString prepare(const QString& path);

}  // namespace crater::transparentvideo
