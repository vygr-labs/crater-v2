# FFmpeg headers

Public headers from FFmpeg 7.1.3 (tag `n7.1.3`), the version Qt 6.11.1
Multimedia ships and loads. Only the headers `TransparentVideo.cpp` includes
are here, plus `libavutil/avconfig.h`, which FFmpeg's configure normally
generates. It is written by hand for little-endian targets.

Nothing links against FFmpeg. `TransparentVideo.cpp` finds Qt's FFmpeg
libraries at run time and checks that their major versions match these
headers before it calls anything, because it reads FFmpeg's structs using
the layouts declared here.

FFmpeg is LGPL 2.1 or later (`COPYING.LGPLv2.1`).

## Updating

When Qt moves to a new FFmpeg (the log's "Using Qt multimedia with FFmpeg
version" line says which), replace these files with the same set from that
release and rebuild. A major version bump also changes the library file
names, and `TransparentVideo.cpp` picks those up from the headers'
`LIB*_VERSION_MAJOR` values.
