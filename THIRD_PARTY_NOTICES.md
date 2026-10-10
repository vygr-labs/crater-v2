# Third-party notices

Crater is licensed under the GNU General Public License, version 3 or (at
your option) any later version. See `LICENSE`.

Crater includes or links the following third-party software. Each keeps its
own license, and the full license texts ship with the components themselves
(Qt installs its licenses in the `licenses/` folder of the deployment).

| Component | Used for | License |
|---|---|---|
| [Qt 6](https://www.qt.io/) (Core, Gui, Qml, Quick, Quick Controls 2, Quick Effects, Sql, Multimedia, PDF, WebSockets, Widgets, Concurrent) | the whole application, linked dynamically | LGPL-3.0-only |
| [Qt Shader Tools](https://doc.qt.io/qt-6/qtshadertools-index.html) | compiling one shader at build time; not shipped | GPL-3.0-only |
| [PDFium](https://pdfium.googlesource.com/pdfium/) (inside Qt PDF) | rendering PDF pages | BSD-3-Clause |
| [FFmpeg](https://ffmpeg.org/) (inside Qt Multimedia) | video and audio playback | LGPL-2.1-or-later |
| [SQLite](https://sqlite.org/) 3.50.4, vendored in `core/src/third_party/` | the database | Public domain |
| [Funnel Sans](https://fonts.google.com/specimen/Funnel+Sans) | the interface font | SIL Open Font License 1.1 |
| [Lucide](https://lucide.dev/) | interface icons | ISC |
| [Microsoft Visual C++ Redistributable](https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist) (Windows installer only) | the C++ runtime | Microsoft system library, redistributed under its own terms |

[NDI](https://ndi.video/) is not included. When the operator has installed
the NDI runtime, Crater loads it at run time. `app/src/NdiAbi.h` declares
the few types it needs so the NDI SDK is not required to build.

Scripture texts and Strong's data are distributed separately from the source
code and carry their own terms.
